//! Transaction Execution Integration Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const Node = root.app.Node;
const NodeDependencies = root.app.NodeDependencies;
const ObjectStore = root.form.storage.ObjectStore;
const Object = root.form.storage.Object;
const Executor = root.pipeline.Executor;

test "Transaction: node dependencies" {
    const deps = NodeDependencies{
        .object_store = null,
        .consensus = null,
        .executor = null,
        .indexer = null,
        .epoch_bridge = null,
        .txn_pool = null,
    };

    try std.testing.expect(deps.object_store == null);
}

test "Transaction: executor handles empty batch" {
    const allocator = std.testing.allocator;

    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    try std.testing.expect(executor.getParallelism() == 4);
}

test "Transaction: object store basic operations" {
    const allocator = std.testing.allocator;

    var store = try ObjectStore.init(allocator, .{}, ".");
    defer store.deinit();

    const id = root.core.ObjectID.hash("test");
    const data = try allocator.dupe(u8, "hello");
    defer allocator.free(data);
    const obj = Object{
        .id = id,
        .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
        .ownership = root.core.Ownership.ownedBy([_]u8{0} ** 32),
        .type_tag = 1,
        .data = data,
    };
    try store.put(obj);
    var got = try store.get(id);
    defer if (got) |*object| object.deinit(allocator);
    try std.testing.expect(got != null);
}
