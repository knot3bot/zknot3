//! ObjectStoreCoordinator - object store access helpers for Node

const std = @import("std");
const core = @import("../core.zig");
const ObjectStore = @import("../form/storage/ObjectStore.zig").ObjectStore;

pub const CoordinatorError = error{
    ObjectStoreNotAvailable,
};

pub fn getObject(store: ?*ObjectStore, id: core.ObjectID) (CoordinatorError || anyerror)!?ObjectStore.Object {
    if (store) |s| {
        return try s.get(id);
    }
    return error.ObjectStoreNotAvailable;
}

pub fn putObject(store: ?*ObjectStore, object: ObjectStore.Object) (CoordinatorError || anyerror)!void {
    if (store) |s| {
        try s.put(object);
        return;
    }
    return error.ObjectStoreNotAvailable;
}

pub fn deleteObject(store: ?*ObjectStore, id: core.ObjectID) (CoordinatorError || anyerror)!void {
    if (store) |s| {
        s.delete(id);
        return;
    }
    return error.ObjectStoreNotAvailable;
}

test "ObjectStoreCoordinator returns ObjectStoreNotAvailable when store is null" {
    const id = core.ObjectID.hash("missing-store");
    try std.testing.expectError(error.ObjectStoreNotAvailable, getObject(null, id));
    try std.testing.expectError(error.ObjectStoreNotAvailable, putObject(null, undefined));
    try std.testing.expectError(error.ObjectStoreNotAvailable, deleteObject(null, id));
}

test "ObjectStoreCoordinator put/get/delete roundtrip" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/object_store_coordinator_test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};

    var store = try ObjectStore.init(allocator, .{}, test_dir);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    var object = ObjectStore.Object{
        .id = core.ObjectID.hash("coordinator-object"),
        .version = core.Version{ .seq = 1, .causal = [_]u8{0} ** 16 },
        .ownership = core.Ownership.immutable(),
        .data = try allocator.dupe(u8, "payload"),
        .type_tag = 1,
    };
    defer object.deinit(allocator);

    try putObject(store, object);

    const maybe_fetched = try getObject(store, object.id);
    try std.testing.expect(maybe_fetched != null);
    var fetched = maybe_fetched.?;
    defer fetched.deinit(allocator);
    try std.testing.expectEqualStrings("payload", fetched.data);

    try deleteObject(store, object.id);
}

