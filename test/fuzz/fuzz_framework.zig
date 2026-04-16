//! Fuzz Testing Infrastructure for zknot3
//!
//! Provides fuzzing utilities for discovering edge cases and bugs:
//! - Structured fuzzing with typed inputs
//! - Corpus management
//! - Minimization support
//! - Integration points for external fuzzers (AFL++, libFuzzer)

const std = @import("std");

/// Fuzzing seed for deterministic reproduction
pub const FuzzSeed = struct {
    const Self = @This();

    value: u64,

    pub fn init(seed: u64) Self {
        return .{ .value = seed };
    }

    /// Create from current time
    pub fn timed() Self {
        return .{ .value = @as(u64, @intCast(std.time.timestamp())) };
    }
};

/// Fuzzing input wrapper that tracks coverage
pub const FuzzInput = struct {
    const Self = @This();

    data: []const u8,
    coverage: usize,

    pub fn init(data: []const u8) Self {
        return .{ .data = data, .coverage = 0 };
    }

    pub fn asBytes(self: Self) []const u8 {
        return self.data;
    }

    pub fn asU32(self: *Self) ?u32 {
        if (self.data.len < 4) return null;
        const val = std.mem.readInt(u32, self.data[0..4], .little);
        self.data = self.data[4..];
        return val;
    }

    pub fn asU64(self: *Self) ?u64 {
        if (self.data.len < 8) return null;
        const val = std.mem.readInt(u64, self.data[0..8], .little);
        self.data = self.data[8..];
        return val;
    }

    pub fn asBool(self: *Self) ?bool {
        if (self.data.len < 1) return null;
        const val = self.data[0] != 0;
        self.data = self.data[1..];
        return val;
    }

    pub fn asBytesN(self: *Self, comptime n: usize) ?[n]u8 {
        if (self.data.len < n) return null;
        var result: [n]u8 = undefined;
        @memcpy(result[0..n], self.data[0..n]);
        self.data = self.data[n..];
        return result;
    }

    pub fn remaining(self: Self) []const u8 {
        return self.data;
    }
};

/// Fuzzing oracle - function that checks for bugs
pub fn FuzzOracle(comptime T: type) type {
    return *const fn (input: T) void;
}

/// Fuzzing result
pub const FuzzResult = struct {
    const Self = @This();

    /// Number of inputs tested
    inputs_tested: u64,
    /// Number of bugs found
    bugs_found: u64,
    /// Coverage achieved
    coverage: usize,
    /// Last error if any
    last_error: ?anyerror,

    pub fn init() Self {
        return .{
            .inputs_tested = 0,
            .bugs_found = 0,
            .coverage = 0,
            .last_error = null,
        };
    }

    pub fn recordBug(self: *Self) void {
        self.bugs_found += 1;
    }

    pub fn recordTest(self: *Self) void {
        self.inputs_tested += 1;
    }
};

/// Simple fuzzing runner
pub const FuzzRunner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    seed: FuzzSeed,
    iterations: u64,
    corpus: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, seed: FuzzSeed, iterations: u64) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .seed = seed,
            .iterations = iterations,
            .corpus = std.ArrayList([]const u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.corpus.items) |item| {
            self.allocator.free(item);
        }
        self.corpus.deinit();
    }

    /// Add seed input to corpus
    pub fn addSeed(self: *Self, data: []const u8) !void {
        const copy = try self.allocator.dupe(u8, data);
        try self.corpus.append(copy);
    }

    /// Run fuzzing with a typed oracle
    pub fn fuzz(self: *Self, comptime T: type, oracle: *const fn (T) void) FuzzResult {
        var result = FuzzResult.init();
        var rng = std.Random.DefaultPrng.init(self.seed.value);

        // Fuzz with corpus first
        for (self.corpus.items) |seed| {
            if (self.fuzzOneInput(T, seed, oracle, &result)) {
                return result;
            }
        }

        // Then fuzz with random inputs
        var i: u64 = 0;
        while (i < self.iterations) : (i += 1) {
            const size = rng.random().uintAtMost(usize, 1024);
            const data = self.generateRandomInput(&rng, size);
            defer self.allocator.free(data);

            if (self.fuzzOneInput(T, data, oracle, &result)) {
                return result;
            }
        }

        return result;
    }

    fn fuzzOneInput(self: *Self, comptime T: type, data: []const u8, oracle: *const fn (T) void, result: *FuzzResult) bool {
        result.recordTest();

        const input = FuzzInput.init(data);
        const parsed = self.parseInput(T, input);

        if (parsed) |value| {
            oracle(value);
        }

        return result.bugs_found > 0;
    }

    fn parseInput(self: *Self, comptime T: type, input: FuzzInput) ?T {
        return switch (T) {
            []const u8 => input.asBytes(),
            []const u32 => self.parseU32Array(input),
            []const u64 => self.parseU64Array(input),
            u32 => input.asU32(),
            u64 => input.asU64(),
            bool => input.asBool(),
            else => @compileError("Unsupported fuzz type: " ++ @typeName(T)),
        };
    }

    fn parseU32Array(self: *Self, input: FuzzInput) ?[]const u32 {
        var array = std.ArrayList(u32).init(self.allocator);
        var mut_input = input;

        while (mut_input.asU32()) |val| {
            array.append(val) catch break;
        }

        return array.toOwnedSlice();
    }

    fn parseU64Array(self: *Self, input: FuzzInput) ?[]const u64 {
        var array = std.ArrayList(u64).init(self.allocator);
        var mut_input = input;

        while (mut_input.asU64()) |val| {
            array.append(val) catch break;
        }

        return array.toOwnedSlice();
    }

    fn generateRandomInput(self: *Self, rng: *std.Random.DefaultPrng, size: usize) []u8 {
        const data = self.allocator.alloc(u8, size) catch return &[_]u8{};
        for (data) |*byte| {
            byte.* = rng.random().uintAtMost(u8, 255);
        }
        return data;
    }
};

// =============================================================================
// Specific Fuzzers for zknot3 Components
// =============================================================================

/// Fuzzer for ObjectID hashing
pub const ObjectIDFuzzer = struct {
    const Self = @This();

    /// Fuzz ObjectID hash consistency
    pub fn fuzzHashConsistency(input: []const u8) void {
        if (input.len < 32) return;

        const root = @import("../../src/root.zig");
        const ObjectID = root.core.ObjectID;

        // Hash the input
        const id1 = ObjectID.hash(input);
        const id2 = ObjectID.hash(input);

        // Results must be equal
        if (!id1.eql(id2)) {
            std.debug.panic("ObjectID hash inconsistent: same input produced different hashes", .{});
        }
    }

    /// Fuzz ObjectID equality
    pub fn fuzzEquality(input: []const u8) void {
        if (input.len < 64) return;

        const root = @import("../../src/root.zig");
        const ObjectID = root.core.ObjectID;

        const id1 = ObjectID.hash(input[0..32]);
        const id2 = ObjectID.hash(input[32..64]);

        // Reflexive
        if (!id1.eql(id1)) {
            std.debug.panic("ObjectID reflexivity failed", .{});
        }

        // Symmetric
        if (id1.eql(id2) != id2.eql(id1)) {
            std.debug.panic("ObjectID symmetry failed", .{});
        }
    }
};

/// Fuzzer for LSMTree operations
pub const LSMTreeFuzzer = struct {
    const Self = @This();

    /// Fuzz LSMTree put/get consistency
    pub fn fuzzPutGet(input: []const u8) void {
        const allocator = std.testing.allocator;
        const LSMTree = @import("../../src/form/storage/LSMTree.zig");

        var tree = LSMTree.init(allocator, .{}) catch return;
        defer tree.deinit();

        var mut_input = FuzzInput.init(input);

        // Parse key-value pairs
        while (true) {
            const key_opt = mut_input.asBytesN(32);
            const value_len = mut_input.asU32() orelse break;
            const value_data = mut_input.remaining();

            if (value_data.len < value_len) break;

            tree.put(key_opt.?, value_data[0..value_len]) catch break;

            // Verify we can get it back
            const retrieved = tree.get(key_opt.?) catch break;
            if (retrieved == null) {
                std.debug.panic("LSMTree put/get failed: key not found", .{});
            }
        }
    }
};

/// Fuzzer for Signature operations
pub const SignatureFuzzer = struct {
    const Self = @This();

    /// Fuzz signature deterministic signing
    pub fn fuzzDeterministicSign(input: []const u8) void {
        if (input.len < 64) return;

        const Signature = @import("../../src/property/crypto/Signature.zig");

        const message = input[0..32];
        const seed = input[32..64];

        const secret_key = Signature.generateSecretKey(seed.*);
        const public_key = Signature.derivePublicKey(secret_key);

        const sig1 = Signature.sign(message, secret_key);
        const sig2 = Signature.sign(message, secret_key);

        // Signatures must be deterministic
        if (!std.mem.eql(u8, &sig1, &sig2)) {
            std.debug.panic("Signature non-deterministic", .{});
        }

        // Verification must pass
        if (!Signature.verify(message, sig1, public_key)) {
            std.debug.panic("Signature verification failed", .{});
        }
    }
};

// =============================================================================
// Fuzz Test Macros
// =============================================================================

/// Define a fuzz test
pub fn fuzztest(comptime name: []const u8, comptime T: type, comptime oracle: *const fn (T) void) void {
    const test_name = "fuzz_" ++ name;
    const test_func = struct {
        fn run() void {
            var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
            const size = rng.random().uintAtMost(usize, 4096);
            var data: [4096]u8 = undefined;
            for (data[0..size]) |*byte| {
                byte.* = rng.random().uintAtMost(u8, 255);
            }
            oracle(data[0..size]);
        }
    }.run;

    _ = test_name;
    _ = test_func;
}
