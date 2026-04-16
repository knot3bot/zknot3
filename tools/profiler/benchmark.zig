//! Benchmark suite for zknot3 core operations
//!
//! Measures performance of:
//! - ObjectID hashing
//! - LSMTree operations
//! - Signature operations
//! - Consensus operations
//! - Serialization

const std = @import("std");
const core = @import("../../src/core.zig");
const ObjectID = core.ObjectID;
const Versioned = core.Version;
const LSMTree = @import("../../src/form/storage/LSMTree.zig");
const Signature = @import("../../src/property/crypto/Signature.zig");
const Mysticeti = @import("../../src/form/consensus/Mysticeti.zig");
const Quorum = @import("../../src/form/consensus/Quorum.zig");
const Interpreter = @import("../../src/property/move_vm/Interpreter.zig");

/// Benchmark result
pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    avg_ns: u64,
    ops_per_sec: f64,
};

/// Simple benchmark runner
pub const Benchmark = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    results: std.ArrayList(BenchmarkResult),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .results = std.ArrayList(BenchmarkResult).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.results.deinit();
    }

    /// Run a benchmark
    pub fn run(self: *Self, name: []const u8, iterations: u64, func: *const fn () void) !void {
        const start = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };

        var i: u64 = 0;
        while (i < iterations) : (i += 1) {
            func();
        }

        const end = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };
        const total_ns = @as(u64, @intCast(end - start));
        const avg_ns = total_ns / iterations;
        const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(total_ns));

        try self.results.append(.{
            .name = name,
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops_per_sec,
        });
    }

    /// Print all results
    pub fn printResults(self: Self) void {
        std.debug.print("\n=== Benchmark Results ===\n", .{});
        for (self.results.items) |result| {
            std.debug.print("{s}: {d} iterations, avg {d} ns/op, {d:.2} ops/sec\n", .{
                result.name,
                result.iterations,
                result.avg_ns,
                result.ops_per_sec,
            });
        }
    }
};

// =============================================================================
// Benchmarks
// =============================================================================

pub fn benchObjectIDHash(iterations: u64) !BenchmarkResult {
    const allocator = std.testing.allocator;
    const input = "benchmark_test_input_data_for_object_id_hash";

    const start = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const id = ObjectID.hash(input);
        _ = id;
    }
    const end = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };

    const total_ns = @as(u64, @intCast(end - start));
    const avg_ns = total_ns / iterations;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(total_ns));

    return .{
        .name = "ObjectID.hash",
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
    };
}

pub fn benchLSMTreePutGet(iterations: u64) !BenchmarkResult {
    const allocator = std.testing.allocator;
    var tree = try LSMTree.init(allocator, .{});
    defer tree.deinit();


    const key: []const u8 = "benchmark_key_for_lsm_tree_testing_12345678";
    const value: []const u8 = "benchmark_value_for_lsm_tree_operations_test";
    // Warm up
    try tree.put(&key, &value);

    const start = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        try tree.put(&key, &value);
        _ = try tree.get(&key);
    }
    const end = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };

    const total_ns = @as(u64, @intCast(end - start));
    const avg_ns = total_ns / iterations;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(total_ns));

    return .{
        .name = "LSMTree.put+get",
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
    };
}

pub fn benchSignatureSignVerify(iterations: u64) !BenchmarkResult {
    const message: []const u8 = "benchmark_message_for_signature_testing";
    const seed = [_]u8{0xAB} ** 32;

    const secret_key = Signature.generateSecretKey(seed);
    const public_key = Signature.derivePublicKey(secret_key);

    const start = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const signature = Signature.sign(&message, secret_key);
        _ = Signature.verify(&message, signature, public_key);
    }
    const end = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };

    const total_ns = @as(u64, @intCast(end - start));
    const avg_ns = total_ns / iterations;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(total_ns));

    return .{
        .name = "Signature.sign+verify",
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
    };
}

pub fn benchInterpreterExecute(iterations: u64) !BenchmarkResult {
    const allocator = std.testing.allocator;
    var interpreter = try Interpreter.init(allocator, .{});
    defer interpreter.deinit();

    const bytecode = &.{ 0x31, 0x01 }; // ld_true; ret

    const start = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        _ = try interpreter.execute(bytecode);
    }
    const end = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };

    const total_ns = @as(u64, @intCast(end - start));
    const avg_ns = total_ns / iterations;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(total_ns));

    return .{
        .name = "Interpreter.execute",
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
    };
}

pub fn benchVersionCompare(iterations: u64) !BenchmarkResult {
    const v1 = Versioned{ .seq = 100, .causal = [_]u8{1} ** 16 };
    const v2 = Versioned{ .seq = 200, .causal = [_]u8{2} ** 16 };

    const start = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        _ = v1.lessThan(v2);
        _ = v1.compare(v2);
    }
    const end = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.tv_sec * std.time.ns_per_s + ts.tv_nsec); };

    const total_ns = @as(u64, @intCast(end - start));
    const avg_ns = total_ns / iterations;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(total_ns));

    return .{
        .name = "Version.compare",
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
    };
}

/// Run all benchmarks
pub fn runAllBenchmarks() !void {
    const allocator = std.testing.allocator;
    var bench = try Benchmark.init(allocator);
    defer bench.deinit();

    const iterations: u64 = 10000;

    std.debug.print("\nRunning benchmarks ({d} iterations each)...\n", .{iterations});

    try bench.run("ObjectID.hash", iterations, struct {
        fn f() void {
            const id = ObjectID.hash("test");
            _ = id;
        }
    }.f);

    std.debug.print("  ObjectID.hash: done\n", .{});

    const result = try benchObjectIDHash(iterations);
    std.debug.print("  ObjectID.hash: {d} ns/op, {d:.2} ops/sec\n", .{
        result.avg_ns, result.ops_per_sec
    });

    const lsm_result = try benchLSMTreePutGet(iterations);
    std.debug.print("  LSMTree.put+get: {d} ns/op, {d:.2} ops/sec\n", .{
        lsm_result.avg_ns, lsm_result.ops_per_sec
    });

    const sig_result = try benchSignatureSignVerify(iterations);
    std.debug.print("  Signature.sign+verify: {d} ns/op, {d:.2} ops/sec\n", .{
        sig_result.avg_ns, sig_result.ops_per_sec
    });

    const interp_result = try benchInterpreterExecute(iterations);
    std.debug.print("  Interpreter.execute: {d} ns/op, {d:.2} ops/sec\n", .{
        interp_result.avg_ns, interp_result.ops_per_sec
    });

    const ver_result = try benchVersionCompare(iterations);
    std.debug.print("  Version.compare: {d} ns/op, {d:.2} ops/sec\n", .{
        ver_result.avg_ns, ver_result.ops_per_sec
    });

    std.debug.print("\nBenchmarks complete!\n", .{});
}

test "Benchmark module initialization" {
    const allocator = std.testing.allocator;
    var bench = try Benchmark.init(allocator);
    defer bench.deinit();

    try std.testing.expect(bench.results.items.len == 0);
}

test "Benchmark result creation" {
    const result = BenchmarkResult{
        .name = "test",
        .iterations = 1000,
        .total_ns = 1000000,
        .avg_ns = 1000,
        .ops_per_sec = 1000000.0,
    };

    try std.testing.expect(result.iterations == 1000);
    try std.testing.expect(result.avg_ns == 1000);
}
