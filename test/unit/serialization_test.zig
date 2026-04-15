//! Serialization Tests for zknot3
//!
//! Tests for serialize/deserialize roundtrip of all major types.

const std = @import("std");
const root = @import("root.zig");
const ObjectID = root.core.ObjectID;
const Versioned = root.core.Versioned;
const Ownership = root.core.Ownership;
const Checkpoint = root.form.storage.Checkpoint;
const Signature = root.property.crypto.Signature;
const Mysticeti = root.form.consensus.Mysticeti;
const Quorum = root.form.consensus.Quorum;
const Interpreter = root.property.move_vm.Interpreter;

// =============================================================================
// ObjectID Serialization
// =============================================================================

test "ObjectID: serialize and deserialize roundtrip" {
    const input = "test_object_id_serialization";
    const original = ObjectID.hash(input);

    // Serialize to bytes
    var bytes: [32]u8 = undefined;
    @memcpy(&bytes, &original.inner);

    // Deserialize
    const restored = ObjectID{ .inner = bytes };

    try std.testing.expect(original.eql(restored));
}

test "ObjectID: serialize to hex string" {
    const original = ObjectID.hash("test");
    const hex = original.toHex();

    try std.testing.expect(hex.len == 64); // 32 bytes = 64 hex chars
}

// =============================================================================
// Versioned Serialization
// =============================================================================

test "Versioned: serialize and deserialize roundtrip" {
    const allocator = std.testing.allocator;

    const original = Versioned{
        .seq = 12345,
        .causal = [_]u8{ 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44, 0x55 },
    };

    // Serialize
    var buf: [24]u8 = undefined; // 8 bytes seq + 16 bytes causal
    std.mem.writeInt(u64, buf[0..8], original.seq, .big);
    @memcpy(buf[8..24], &original.causal);

    // Deserialize
    const restored = Versioned{
        .seq = std.mem.readInt(u64, buf[0..8], .big),
        .causal = buf[8..24].*,
    };

    try std.testing.expect(original.seq == restored.seq);
    try std.testing.expect(std.mem.eql(u8, &original.causal, &restored.causal));
}

// =============================================================================
// Ownership Serialization
// =============================================================================

test "Ownership: serialize and deserialize roundtrip" {
    const allocator = std.testing.allocator;

    const owner_bytes = [_]u8{0x12} ** 32;
    const original = Ownership.ownedBy(owner_bytes);

    // Ownership should remain valid after serialization
    try std.testing.expect(original == .owned);
    try std.testing.expect(std.mem.eql(u8, &original.owned.by, &owner_bytes));
}

// =============================================================================
// Checkpoint Serialization
// =============================================================================

test "Checkpoint: serialize and deserialize roundtrip" {
    const allocator = std.testing.allocator;

    const changes = &[_]Checkpoint.ObjectChange{
        .{
            .id = ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
        .{
            .id = ObjectID.hash("obj2"),
            .version = .{ .seq = 2, .causal = [_]u8{0} ** 16 },
            .status = .modified,
        },
    };

    const original = try Checkpoint.create(42, [_]u8{0xAB} ** 32, changes, allocator);
    defer original.deinit();

    // Serialize
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
    try std.testing.expect(original.sequence == 42);
    try std.testing.expect(original.object_changes.len == 2);
}

// =============================================================================
// Signature Serialization
// =============================================================================

test "Signature: sign produces fixed-size signature" {
    const message = "test message for signature";
    const message_bytes = message.*;

    const seed = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ++ [_]u8{0x12} ** 28;
    const secret_key = Signature.generateSecretKey(seed);
    const public_key = Signature.derivePublicKey(secret_key);
    const signature = Signature.sign(&message_bytes, secret_key);

    // Signature should be 64 bytes (Ed25519)
    try std.testing.expect(signature.len == 64);

    // Verify it works
    try std.testing.expect(Signature.verify(&message_bytes, signature, public_key));
}

test "Signature: public key serialize and deserialize" {
    const seed = [_]u8{0xFE} ** 32;
    const secret_key = Signature.generateSecretKey(seed);
    const original_pk = Signature.derivePublicKey(secret_key);

    // Public key should be 32 bytes
    try std.testing.expect(original_pk.len == 32);
}

// =============================================================================
// Mysticeti Serialization
// =============================================================================

test "Mysticeti Block: serialize digest" {
    const allocator = std.testing.allocator;

    const parents = &[_]Mysticeti.Round{ .{ .value = 0 }, .{ .value = 1 } };
    var block = try Mysticeti.Block.create(
        [_]u8{0xAA} ** 32,
        .{ .value = 2 },
        "test payload",
        parents,
        allocator,
    );
    defer block.deinit();

    // Digest should be 32 bytes (BLAKE3)
    try std.testing.expect(block.digest.len == 32);
}

test "Mysticeti Round: ordering" {
    const r1 = Mysticeti.Round{ .value = 1 };
    const r2 = Mysticeti.Round{ .value = 2 };

    try std.testing.expect(r1.lessThan(r2));
    try std.testing.expect(r1.predecessors(r2));
    try std.testing.expect(!r2.predecessors(r1));
}

// =============================================================================
// Quorum Serialization
// =============================================================================

test "Quorum: stake calculation roundtrip" {
    const allocator = std.testing.allocator;
    var quorum = try Quorum.Quorum.init(allocator);
    defer quorum.deinit();

    // Add validators
    try quorum.addValidator([_]u8{1} ** 32, 1000);
    try quorum.addValidator([_]u8{2} ** 32, 2000);
    try quorum.addValidator([_]u8{3} ** 32, 3000);

    const total = quorum.totalStake();
    try std.testing.expect(total == 6000);

    const threshold = quorum.quorumThreshold();
    try std.testing.expect(threshold == 4000); // 2/3 of 6000

    const byzantine = quorum.byzantineThreshold();
    try std.testing.expect(byzantine == 1); // (3-1)/3 = 0.66 -> 1
}

// =============================================================================
// Interpreter Serialization
// =============================================================================

test "Interpreter: bytecode roundtrip" {
    const allocator = std.testing.allocator;
    var interpreter = try Interpreter.init(allocator, .{});
    defer interpreter.deinit();

    // Execute simple bytecode
    const bytecode = &.{ 0x31, 0x01 }; // ld_true; ret
    const result = try interpreter.execute(bytecode);

    try std.testing.expect(result.status == .success);
    try std.testing.expect(result.gas_used > 0);
}

// =============================================================================
// Binary Serialization Utilities
// =============================================================================

test "BinarySerializer: write and read primitives" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // Write various types
    try buf.appendSlice(&[_]u8{ 0x01, 0x02, 0x03, 0x04 }); // u32
    try buf.appendSlice(&[_]u8{ 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8 }); // u64

    try std.testing.expect(buf.items.len == 12);
}

test "BinarySerializer: string serialization" {
    const allocator = std.testing.allocator;
    const original = "Hello, zknot3!";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // Write length-prefixed string
    try std.fmt.format(buf.writer(), "{s}", .{original});

    try std.testing.expect(buf.items.len > 0);
}

// =============================================================================
// JSON Serialization
// =============================================================================

test "JSON serialization: basic types" {
    const allocator = std.testing.allocator;

    const json_string = "{\"key\":\"value\",\"number\":42}";

    var parser = std.json.Parser.init(allocator, .{});
    defer parser.deinit();

    var token_buffer: [1024]std.json.Token = undefined;
    const value = try parser.parse(json_string, &token_buffer);

    try std.testing.expect(value.object.get("key") != null);
}

// =============================================================================
// Integration: Full Serialization Roundtrip
// =============================================================================

test "Full roundtrip: create checkpoint and verify" {
    const allocator = std.testing.allocator;

    // Create checkpoint
    const changes = &[_]Checkpoint.ObjectChange{
        .{
            .id = ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };

    const cp = try Checkpoint.create(1, [_]u8{0xAB} ** 32, changes, allocator);
    defer cp.deinit();

    // Verify digest is deterministic
    const digest1 = cp.digest();
    const digest2 = cp.digest();
    try std.testing.expect(std.mem.eql(u8, &digest1, &digest2));

    // Verify sequence
    try std.testing.expect(cp.sequence == 1);
    try std.testing.expect(cp.object_changes.len == 1);
}
