//! Full Pipeline Integration Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const Quorum = root.form.consensus.Quorum;
const Mysticeti = root.form.consensus.Mysticeti;
const Ingress = root.pipeline.Ingress;
const Egress = root.pipeline.Egress;
const Executor = root.pipeline.Executor;
const ObjectStore = root.form.storage.ObjectStore;
const Object = root.form.storage.Object;
const Checkpoint = root.form.storage.Checkpoint;

fn makeId(i: u8) [32]u8 {
    return [_]u8{i} ** 32;
}

test "Pipeline: ingress to egress" {
    const allocator = std.testing.allocator;

    var ingress = try Ingress.init(allocator, .{});
    defer ingress.deinit();

    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit();

    try std.testing.expect(ingress.pendingCount() == 0);
    try std.testing.expect(egress.getPending() == null);
}

test "Pipeline: executor with quorum" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    try quorum.addValidator(makeId(1), 1000);
    try quorum.addValidator(makeId(2), 1000);
    try quorum.addValidator(makeId(3), 1000);

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
    try std.testing.expect(std.mem.eql(u8, got.?.data, "hello"));
}

test "Pipeline: checkpoint creation" {
    const allocator = std.testing.allocator;

    var cp = try Checkpoint.create(1, makeId(1), &.{}, allocator);
    defer cp.deinit(allocator);

    try std.testing.expect(cp.sequence == 1);
}

test "Pipeline: Mysticeti block creation" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    try quorum.addValidator(makeId(1), 1000);

    var block = try Mysticeti.Block.create(makeId(1), .{ .value = 1 }, &.{}, &.{}, allocator);
    defer block.deinit(allocator);

    try std.testing.expect(block.round.value == 1);
    try std.testing.expect(block.hasQuorum(0, quorum.quorumStakeThreshold()));
}
