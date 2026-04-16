//! Pipeline Integration Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const Ingress = root.pipeline.Ingress;
const Egress = root.pipeline.Egress;
const Executor = root.pipeline.Executor;
const ObjectStore = root.form.storage.ObjectStore;
const Object = root.form.storage.Object;

test "Pipeline: ingress init" {
    const allocator = std.testing.allocator;

    var ingress = try Ingress.init(allocator, .{ .max_pending = 100 });
    defer ingress.deinit();

    try std.testing.expect(ingress.pendingCount() == 0);
}

test "Pipeline: egress init" {
    const allocator = std.testing.allocator;

    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit();

    try std.testing.expect(egress.getPending() == null);
}

test "Pipeline: executor init" {
    const allocator = std.testing.allocator;

    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    try std.testing.expect(executor.getParallelism() == 4);
}

test "Pipeline: object store put and get" {
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
    const got = try store.get(id);
    try std.testing.expect(got != null);
}

test "Pipeline: signature verification" {
    const root_crypto = root.property.crypto;
    const Signature = root_crypto.Signature;

    const msg = "hello";
    const kp = try Signature.KeyPair.generate();
    const sig = try kp.sign(msg);
    try std.testing.expect(Signature.verify(kp.public_key.bytes, msg, sig.bytes));
}
