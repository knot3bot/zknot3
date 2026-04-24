//! Transaction Golden Test Vectors — Protocol v1 Freeze
//!
//! Covers:
//! - Positive: canonical digest / serialization / deserialization round-trip
//! - Negative: signature fails after tampering with any signed field
//! - Boundary: empty inputs, empty program, max gas, nonce edge values

const std = @import("std");
const pipeline = @import("../../src/pipeline.zig");
const Transaction = pipeline.Transaction;
const Signature = @import("../../src/property/crypto/Signature.zig");

// ---------------------------------------------------------------------------
// Positive vectors
// ---------------------------------------------------------------------------

fn makePositiveTx(allocator: std.mem.Allocator) !Transaction {
    return .{
        .sender = [_]u8{0xAA} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "transfer"),
        .gas_budget = 1000,
        .sequence = 42,
        .signature = null,
        .public_key = null,
    };
}

test "golden-positive: digest stability" {
    const allocator = std.testing.allocator;
    var tx = try makePositiveTx(allocator);
    defer tx.deinit(allocator);

    const d1 = tx.digest();
    const d2 = tx.digest();
    try std.testing.expect(std.mem.eql(u8, &d1, &d2));
}

test "golden-positive: serialization round-trip" {
    const allocator = std.testing.allocator;
    var tx = try makePositiveTx(allocator);
    defer tx.deinit(allocator);

    // Sign the tx so signature/public_key are populated in the wire format
    var kp = try Signature.KeyPair.generate();
    defer kp.deinit();
    const digest = tx.digest();
    const sig = try Signature.sign(&digest, kp.secret_key, .ed25519);
    tx.signature = sig.bytes;
    tx.public_key = kp.public_key.bytes;

    const wire = try tx.serialize(allocator);
    defer allocator.free(wire);
    try std.testing.expect(wire.len > 0);

    var tx2 = try Transaction.deserialize(allocator, wire);
    defer tx2.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, &tx.sender, &tx2.sender));
    try std.testing.expectEqual(tx.gas_budget, tx2.gas_budget);
    try std.testing.expectEqual(tx.sequence, tx2.sequence);
    try std.testing.expect(std.mem.eql(u8, tx.program, tx2.program));
    try std.testing.expect(std.mem.eql(u8, &tx.signature.?, &tx2.signature.?));
    try std.testing.expect(std.mem.eql(u8, &tx.public_key.?, &tx2.public_key.?));
}

test "golden-positive: signed transaction verifies" {
    const allocator = std.testing.allocator;
    var tx = try makePositiveTx(allocator);
    defer tx.deinit(allocator);

    var kp = try Signature.KeyPair.generate();
    defer kp.deinit();
    const digest = tx.digest();
    const sig = try Signature.sign(&digest, kp.secret_key, .ed25519);
    tx.signature = sig.bytes;
    tx.public_key = kp.public_key.bytes;

    try std.testing.expect(tx.verifySignature());
}

// ---------------------------------------------------------------------------
// Negative vectors
// ---------------------------------------------------------------------------

test "golden-negative: tampered gas_budget invalidates signature" {
    const allocator = std.testing.allocator;
    var tx = try makePositiveTx(allocator);
    defer tx.deinit(allocator);

    var kp = try Signature.KeyPair.generate();
    defer kp.deinit();
    const digest = tx.digest();
    const sig = try Signature.sign(&digest, kp.secret_key, .ed25519);
    tx.signature = sig.bytes;
    tx.public_key = kp.public_key.bytes;

    try std.testing.expect(tx.verifySignature());
    tx.gas_budget += 1;
    try std.testing.expect(!tx.verifySignature());
}

test "golden-negative: tampered sequence invalidates signature" {
    const allocator = std.testing.allocator;
    var tx = try makePositiveTx(allocator);
    defer tx.deinit(allocator);

    var kp = try Signature.KeyPair.generate();
    defer kp.deinit();
    const digest = tx.digest();
    const sig = try Signature.sign(&digest, kp.secret_key, .ed25519);
    tx.signature = sig.bytes;
    tx.public_key = kp.public_key.bytes;

    try std.testing.expect(tx.verifySignature());
    tx.sequence += 1;
    try std.testing.expect(!tx.verifySignature());
}

test "golden-negative: tampered program invalidates signature" {
    const allocator = std.testing.allocator;
    var tx = try makePositiveTx(allocator);
    defer tx.deinit(allocator);

    var kp = try Signature.KeyPair.generate();
    defer kp.deinit();
    const digest = tx.digest();
    const sig = try Signature.sign(&digest, kp.secret_key, .ed25519);
    tx.signature = sig.bytes;
    tx.public_key = kp.public_key.bytes;

    try std.testing.expect(tx.verifySignature());
    allocator.free(tx.program);
    tx.program = try allocator.dupe(u8, "tampered");
    try std.testing.expect(!tx.verifySignature());
}

test "golden-negative: unsigned transaction fails verification" {
    const tx = Transaction{
        .sender = [_]u8{0xBB} ** 32,
        .inputs = &.{},
        .program = "test",
        .gas_budget = 100,
        .sequence = 0,
        .signature = null,
        .public_key = null,
    };
    try std.testing.expect(!tx.verifySignature());
}

// ---------------------------------------------------------------------------
// Boundary vectors
// ---------------------------------------------------------------------------

test "golden-boundary: empty program digest and serialization" {
    const allocator = std.testing.allocator;
    var tx = Transaction{
        .sender = [_]u8{0xCC} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, ""),
        .gas_budget = 1,
        .sequence = 0,
        .signature = null,
        .public_key = null,
    };
    defer tx.deinit(allocator);

    const d = tx.digest();
    try std.testing.expect(d[0] != 0 or d[31] != 0); // non-trivial hash

    const wire = try tx.serialize(allocator);
    defer allocator.free(wire);
    var tx2 = try Transaction.deserialize(allocator, wire);
    defer tx2.deinit(allocator);
    try std.testing.expectEqualStrings("", tx2.program);
}

test "golden-boundary: max gas and sequence" {
    const allocator = std.testing.allocator;
    var tx = Transaction{
        .sender = [_]u8{0xDD} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "noop"),
        .gas_budget = std.math.maxInt(u64),
        .sequence = std.math.maxInt(u64),
        .signature = null,
        .public_key = null,
    };
    defer tx.deinit(allocator);

    const wire = try tx.serialize(allocator);
    defer allocator.free(wire);
    var tx2 = try Transaction.deserialize(allocator, wire);
    defer tx2.deinit(allocator);
    try std.testing.expectEqual(std.math.maxInt(u64), tx2.gas_budget);
    try std.testing.expectEqual(std.math.maxInt(u64), tx2.sequence);
}

test "golden-boundary: deserialize rejects truncated payload" {
    const allocator = std.testing.allocator;
    // Too short to be a valid v1 transaction
    const bad = &[_]u8{0} ** 10;
    try std.testing.expectError(error.MalformedTransaction, Transaction.deserialize(allocator, bad));
}

test "golden-boundary: deserialize rejects oversized inputs_len" {
    const allocator = std.testing.allocator;
    var buf = [_]u8{0} ** 256;
    @memset(&buf, 0);
    // inputs_len = 0xFFFFFFFF (way too large)
    std.mem.writeInt(u32, buf[32..36], 0xFFFFFFFF, .big);
    try std.testing.expectError(error.MalformedTransaction, Transaction.deserialize(allocator, &buf));
}
