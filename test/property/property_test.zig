//! Property-based tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const ObjectID = root.core.ObjectID;
const Ownership = root.core.Ownership;
const LSMTree = root.form.storage.LSMTree;
const Signature = root.property.crypto.Signature;
const Resource = root.property.move_vm.Resource;
const ResourceTracker = root.property.move_vm.ResourceTracker;
const Gas = root.property.move_vm.Gas;

fn generateRandomBytes(seed: u64, len: usize) []u8 {
    const bytes = std.heap.page_allocator.alloc(u8, len) catch unreachable;
    var rng = std.Random.DefaultPrng.init(seed);
    for (bytes) |*b| {
        b.* = rng.random().uintAtMost(u8, 255);
    }
    return bytes;
}

test "Property: ObjectID hash is deterministic" {
    const id1 = ObjectID.hash("hello");
    const id2 = ObjectID.hash("hello");
    try std.testing.expectEqual(id1.bytes, id2.bytes);
}

test "Property: ObjectID hash differs for different inputs" {
    const id1 = ObjectID.hash("hello");
    const id2 = ObjectID.hash("world");
    try std.testing.expect(!std.mem.eql(u8, &id1.bytes, &id2.bytes));
}

test "Property: Ownership ownedBy roundtrip" {
    const owner = [_]u8{0xAB} ** 32;
    const ownership = Ownership.ownedBy(owner);
    try std.testing.expect(ownership.tag == .Owned);
    try std.testing.expectEqual(ownership.owner.?, owner);
}

test "Property: LSMTree put and get" {
    const allocator = std.testing.allocator;

    var tree = try LSMTree.init(allocator, .{ .sst_dir = "." });
    defer tree.deinit();

    try tree.put("key1", "value1");
    const value = try tree.get("key1");
    try std.testing.expect(std.mem.eql(u8, value.?, "value1"));
}

test "Property: Signature roundtrip" {
    const kp = try Signature.KeyPair.generate();
    const msg = "test message";
    const sig = try kp.sign(msg);
    try std.testing.expect(Signature.verify(kp.public_key.bytes, msg, sig.bytes));
}

test "Property: Interpreter gas tracking" {
    var gas = Gas.GasMeter.init(.{ .initial_budget = 5000, .max_gas = 5000 });
    try gas.consume(1000);
    try std.testing.expect(gas.getRemaining() == 4000);
    try std.testing.expect(gas.getConsumed() == 1000);
}

test "Property: Resource lifecycle" {
    const allocator = std.testing.allocator;

    const id = ObjectID.hash("resource");
    var res = try Resource.init(id, .Coin, &.{1, 2, 3}, null, allocator);
    defer {
        res.deinit(allocator);
        allocator.destroy(res);
    }

    try std.testing.expect(res.isValid());
    try std.testing.expect(!res.isMoved());
}
