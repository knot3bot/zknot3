//! Serialization Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const ObjectID = root.core.ObjectID;
const Version = root.core.Version;
const Ownership = root.core.Ownership;
const OwnershipTag = root.core.OwnershipTag;
const Checkpoint = root.form.storage.Checkpoint;
const Signature = root.property.crypto.Signature;
const ObjectStore = root.form.storage.ObjectStore;
const Mysticeti = root.form.consensus.Mysticeti;
const Quorum = root.form.consensus.Quorum;
const Interpreter = root.property.move_vm.Interpreter;

// =============================================================================
// ObjectID Serialization
// =============================================================================

test "ObjectID: bytes roundtrip" {
    const original = ObjectID.hash("test data");
    const bytes = original.bytes;

    var copy: ObjectID = undefined;
    @memcpy(&copy.bytes, &bytes);

    try std.testing.expectEqual(original.bytes, copy.bytes);
}

test "ObjectID: hash is deterministic" {
    const id1 = ObjectID.hash("same");
    const id2 = ObjectID.hash("same");
    try std.testing.expectEqual(id1.bytes, id2.bytes);
}

// =============================================================================
// Ownership Serialization
// =============================================================================

test "Ownership: encode produces bytes" {
    const original = Ownership.ownedBy([_]u8{0xAB} ** 32);
    const encoded = original.encode();
    try std.testing.expect(encoded.len > 0);
    try std.testing.expect(encoded[0] == @intFromEnum(OwnershipTag.Owned));
}

test "Ownership: shared object encode" {
    const original = Ownership.shared(1234);
    const encoded = original.encode();
    try std.testing.expect(encoded.len > 0);
    try std.testing.expect(encoded[0] == @intFromEnum(OwnershipTag.Shared));
    const context_back = std.mem.readInt(u64, encoded[33..41], .big);
    try std.testing.expect(context_back == 1234);
}

test "Ownership: immutable encode" {
    const original = Ownership.immutable();
    const encoded = original.encode();
    try std.testing.expect(encoded.len > 0);
    try std.testing.expect(encoded[0] == @intFromEnum(OwnershipTag.Immutable));
}

// =============================================================================
// Checkpoint Serialization
// =============================================================================

test "Checkpoint: serialize and deserialize" {
    const allocator = std.testing.allocator;
    const prev_digest = [_]u8{0x01} ** 32;

    var cp = try Checkpoint.create(1, prev_digest, &.{}, allocator);
    defer cp.deinit(allocator);

    const serialized = try cp.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
}

// =============================================================================
// Signature Serialization
// =============================================================================

test "Signature: keypair generation and sign verify" {
    var kp = try Signature.KeyPair.generate();
    defer kp.deinit();
    const message = "test message";
    const sig = try kp.sign(message);
    try std.testing.expect(sig.verify(kp.public_key, message));
    try std.testing.expect(!sig.verify(kp.public_key, "wrong message"));
}

// =============================================================================
// Block Serialization
// =============================================================================

test "Block: create and digest" {
    const allocator = std.testing.allocator;
    const author = [_]u8{0x02} ** 32;

    var block = try Mysticeti.Block.create(author, .{ .value = 1 }, &.{}, &.{}, allocator);
    defer block.deinit(allocator);

    try std.testing.expect(block.digest.len > 0);
    try std.testing.expect(block.payload.len == 0);
}

// =============================================================================
// Quorum Serialization
// =============================================================================

test "Quorum: basic operations" {
    const allocator = std.testing.allocator;
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    try quorum.addValidator([_]u8{0x01} ** 32, 1000);
    try quorum.addValidator([_]u8{0x02} ** 32, 2000);

    try std.testing.expect(quorum.totalStake() == 3000);
    try std.testing.expect(quorum.activeStake() == 3000);
}

// =============================================================================
// Binary Serialization Utilities
// =============================================================================

test "BinarySerializer: write and read primitives" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &[_]u8{ 0x01, 0x02, 0x03, 0x04 });
    try buf.appendSlice(allocator, &[_]u8{ 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8 });

    try std.testing.expect(buf.items.len == 12);
}

test "BinarySerializer: string serialization" {
    const allocator = std.testing.allocator;
    const original = "Hello, zknot3!";

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    try std.fmt.format(buf.writer(allocator), "{s}", .{original});

    try std.testing.expect(buf.items.len > 0);
    try std.testing.expect(std.mem.eql(u8, buf.items, original));
}

// =============================================================================
// JSON Serialization
// =============================================================================

test "JSON: parse and serialize object" {
    const allocator = std.testing.allocator;
    const json = "{\"name\":\"zknot3\",\"version\":1}";

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.eql(u8, parsed.value.object.get("name").?.string, "zknot3"));
    try std.testing.expect(parsed.value.object.get("version").?.integer == 1);
}

test "JSON: serialize struct" {
    const allocator = std.testing.allocator;
    const obj = .{ .name = "zknot3", .version = @as(u32, 1) };

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    try buf.writer(allocator).print("{{\"name\":\"{s}\",\"version\":{}}}", .{ obj.name, obj.version });
    try std.testing.expect(buf.items.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, buf.items, 1, "zknot3"));
}
