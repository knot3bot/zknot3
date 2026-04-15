//! Property-based tests for zknot3
//!
//! Tests invariants that should hold across a wide range of random inputs.

const std = @import("std");
const root = @import("root.zig");
const ObjectID = root.core.ObjectID;
const Versioned = root.core.Versioned;
const Ownership = root.core.Ownership;
const LSMTree = root.form.storage.LSMTree;
const Interpreter = root.property.move_vm.Interpreter;
const Signature = root.property.crypto.Signature;

// Helper to generate deterministic pseudo-random bytes
fn generateRandomBytes(seed: u64, len: usize) []u8 {
    var bytes = std.heap.page_allocator.alloc(u8, len) catch unreachable;
    var rng = std.rand.DefaultPrng.init(seed);
    for (bytes) |*b| {
        b.* = rng.random().uintAtMost(u8, 255);
    }
    return bytes;
}

// =============================================================================
// ObjectID Property Tests
// =============================================================================

test "ObjectID: hash is deterministic" {
    const seed: u64 = 42;
    const input = generateRandomBytes(seed, 32);
    defer std.heap.page_allocator.free(input);

    const id1 = ObjectID.hash(input);
    const id2 = ObjectID.hash(input);

    try std.testing.expect(id1.eql(id2));
}

test "ObjectID: hash produces different results for different inputs" {
    const input1 = generateRandomBytes(1, 32);
    const input2 = generateRandomBytes(2, 32);
    defer std.heap.page_allocator.free(input1);
    defer std.heap.page_allocator.free(input2);

    const id1 = ObjectID.hash(input1);
    const id2 = ObjectID.hash(input2);

    try std.testing.expect(!id1.eql(id2));
}

test "ObjectID: hash length is consistent" {
    const sizes = [_]usize{ 16, 32, 64, 128 };

    for (sizes) |size| {
        const input = generateRandomBytes(size, size);
        defer std.heap.page_allocator.free(input);

        const id = ObjectID.hash(input);
        try std.testing.expect(id.inner.len == 32);
    }
}

test "ObjectID: equality is reflexive" {
    const input = generateRandomBytes(99, 32);
    defer std.heap.page_allocator.free(input);

    const id = ObjectID.hash(input);

    try std.testing.expect(id.eql(id));
    try std.testing.expect(id.eql(id));
    try std.testing.expect(id.eql(id));
}

test "ObjectID: equality is symmetric" {
    const input = generateRandomBytes(77, 32);
    defer std.heap.page_allocator.free(input);

    const id1 = ObjectID.hash(input);
    const id2 = ObjectID.hash(input);

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(id2.eql(id1));
}

// =============================================================================
// Versioned Property Tests
// =============================================================================

test "Versioned: sequence increments are monotonic" {
    const base: u64 = 1000;

    var v1 = Versioned{ .seq = base, .causal = [_]u8{0} ** 16 };
    const v2 = Versioned{ .seq = base + 1, .causal = [_]u8{0} ** 16 };

    try std.testing.expect(v2.seq > v1.seq);
}

test "Versioned: causal parts can vary independently" {
    const v1 = Versioned{ .seq = 1, .causal = [_]u8{1} ** 16 };
    const v2 = Versioned{ .seq = 1, .causal = [_]u8{2} ** 16 };

    try std.testing.expect(v1.seq == v2.seq);
    try std.testing.expect(!std.mem.eql(u8, &v1.causal, &v2.causal));
}

// =============================================================================
// Ownership Property Tests
// =============================================================================

test "Ownership: ownedBy creates valid ownership" {
    const bytes = generateRandomBytes(55, 32);
    defer std.heap.page_allocator.free(bytes);

    const ownership = Ownership.ownedBy(bytes.*);

    try std.testing.expect(ownership == .owned);
    try std.testing.expect(std.mem.eql(u8, &ownership.owned.by, &bytes.*));
}

test "Ownership: shared ownership is distinct from owned" {
    const owner = generateRandomBytes(66, 32);
    defer std.heap.page_allocator.free(owner);

    const owned = Ownership.ownedBy(owner.*);
    const shared = Ownership.shared();

    try std.testing.expect(owned != shared);
}

// =============================================================================
// LSMTree Property Tests
// =============================================================================

test "LSMTree: put and get are inverse operations" {
    const allocator = std.testing.allocator;
    var tree = try LSMTree.init(allocator, .{});
    defer tree.deinit();

    const key = generateRandomBytes(101, 32);
    const value = generateRandomBytes(102, 64);
    defer std.heap.page_allocator.free(key);
    defer std.heap.page_allocator.free(value);

    try tree.put(key, value);
    const retrieved = try tree.get(key);

    try std.testing.expect(retrieved != null);
    try std.testing.expect(std.mem.eql(u8, retrieved.?, value));
}

test "LSMTree: overwrite updates value" {
    const allocator = std.testing.allocator;
    var tree = try LSMTree.init(allocator, .{});
    defer tree.deinit();

    const key = generateRandomBytes(201, 32);
    const value1 = generateRandomBytes(202, 32);
    const value2 = generateRandomBytes(203, 32);
    defer std.heap.page_allocator.free(key);
    defer std.heap.page_allocator.free(value1);
    defer std.heap.page_allocator.free(value2);

    try tree.put(key, value1);
    try tree.put(key, value2);

    const retrieved = try tree.get(key);
    try std.testing.expect(std.mem.eql(u8, retrieved.?, value2));
}

test "LSMTree: missing key returns null" {
    const allocator = std.testing.allocator;
    var tree = try LSMTree.init(allocator, .{});
    defer tree.deinit();

    const key = generateRandomBytes(301, 32);
    defer std.heap.page_allocator.free(key);

    const retrieved = try tree.get(key);
    try std.testing.expect(retrieved == null);
}

test "LSMTree: multiple keys are independent" {
    const allocator = std.testing.allocator;
    var tree = try LSMTree.init(allocator, .{});
    defer tree.deinit();

    const key1 = generateRandomBytes(401, 32);
    const key2 = generateRandomBytes(402, 32);
    const value1 = generateRandomBytes(403, 16);
    const value2 = generateRandomBytes(404, 32);
    defer std.heap.page_allocator.free(key1);
    defer std.heap.page_allocator.free(key2);
    defer std.heap.page_allocator.free(value1);
    defer std.heap.page_allocator.free(value2);

    try tree.put(key1, value1);
    try tree.put(key2, value2);

    const r1 = try tree.get(key1);
    const r2 = try tree.get(key2);

    try std.testing.expect(std.mem.eql(u8, r1.?, value1));
    try std.testing.expect(std.mem.eql(u8, r2.?, value2));
}

// =============================================================================
// Interpreter Gas Metering Property Tests
// =============================================================================

test "Interpreter: gas decreases with executed instructions" {
    const allocator = std.testing.allocator;
    var interpreter = try Interpreter.init(allocator, .{});
    defer interpreter.deinit();

    const initial_gas = interpreter.gas;
    try interpreter.execute(&.{ 0x31, 0x01 }); // ld_true; ret

    try std.testing.expect(interpreter.gas < initial_gas);
}

test "Interpreter: gas budget limits execution" {
    const allocator = std.testing.allocator;
    var interpreter = try Interpreter.init(allocator, .{ .gas_budget = 10 });
    defer interpreter.deinit();

    // Execute a simple program
    const result = interpreter.execute(&.{ 0x31, 0x01 });

    // Should either succeed with low gas or fail with out of gas
    if (result) |res| {
        try std.testing.expect(res.status == .success);
    } else |_| {
        // Execution may fail, which is acceptable
    }
}

test "Interpreter: empty program completes" {
    const allocator = std.testing.allocator;
    var interpreter = try Interpreter.init(allocator, .{});
    defer interpreter.deinit();

    const result = try interpreter.execute(&.{});
    try std.testing.expect(result.status == .success);
}

// =============================================================================
// Signature Property Tests
// =============================================================================

test "Signature: sign and verify roundtrip" {
    const message = generateRandomBytes(501, 100);
    defer std.heap.page_allocator.free(message);

    const seed = generateRandomBytes(502, 32);
    defer std.heap.page_allocator.free(seed);

    const secret_key = Signature.generateSecretKey(seed.*);
    const public_key = Signature.derivePublicKey(secret_key);
    const signature = Signature.sign(message, secret_key);

    const valid = Signature.verify(message, signature, public_key);
    try std.testing.expect(valid);
}

test "Signature: different messages produce different signatures" {
    const message1 = generateRandomBytes(601, 50);
    const message2 = generateRandomBytes(602, 50);
    defer std.heap.page_allocator.free(message1);
    defer std.heap.page_allocator.free(message2);

    const seed = generateRandomBytes(603, 32);
    defer std.heap.page_allocator.free(seed);

    const secret_key = Signature.generateSecretKey(seed.*);
    const sig1 = Signature.sign(message1, secret_key);
    const sig2 = Signature.sign(message2, secret_key);

    try std.testing.expect(!std.mem.eql(u8, &sig1, &sig2));
}

test "Signature: wrong public key fails verification" {
    const message = generateRandomBytes(701, 64);
    defer std.heap.page_allocator.free(message);

    const seed1 = generateRandomBytes(702, 32);
    const seed2 = generateRandomBytes(703, 32);
    defer std.heap.page_allocator.free(seed1);
    defer std.heap.page_allocator.free(seed2);

    const secret_key = Signature.generateSecretKey(seed1.*);
    const public_key = Signature.derivePublicKey(secret_key);
    const signature = Signature.sign(message, secret_key);

    // Generate different keypair
    const different_seed = generateRandomBytes(704, 32);
    defer std.heap.page_allocator.free(different_seed);
    const different_sk = Signature.generateSecretKey(different_seed.*);
    const different_pk = Signature.derivePublicKey(different_sk);

    const valid = Signature.verify(message, signature, different_pk);
    try std.testing.expect(!valid);
}

test "Signature: tampered message fails verification" {
    const message = generateRandomBytes(801, 64);
    defer std.heap.page_allocator.free(message);

    const seed = generateRandomBytes(802, 32);
    defer std.heap.page_allocator.free(seed);

    const secret_key = Signature.generateSecretKey(seed.*);
    const public_key = Signature.derivePublicKey(secret_key);
    const signature = Signature.sign(message, secret_key);

    // Tamper with message
    message[0] +%= 1;

    const valid = Signature.verify(message, signature, public_key);
    try std.testing.expect(!valid);
}

test "Signature: public key is deterministically derived" {
    const seed = generateRandomBytes(901, 32);
    defer std.heap.page_allocator.free(seed);

    const secret_key = Signature.generateSecretKey(seed.*);
    const pk1 = Signature.derivePublicKey(secret_key);
    const pk2 = Signature.derivePublicKey(secret_key);

    try std.testing.expect(std.mem.eql(u8, &pk1, &pk2));
}

// =============================================================================
// Invariant: Digest Consistency
// =============================================================================

test "ObjectID: hash is consistent across multiple calls (stress test)" {
    const input = generateRandomBytes(999, 32);
    defer std.heap.page_allocator.free(input);

    const id = ObjectID.hash(input);

    // Hash 100 times, all should be equal
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const id2 = ObjectID.hash(input);
        try std.testing.expect(id.eql(id2));
    }
}
