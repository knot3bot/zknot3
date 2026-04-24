//! Indexing End-to-End Test
//!
//! Validates: execute transaction -> index event -> query event consistency.

const std = @import("std");
const Node = @import("../../src/app/Node.zig").Node;
const NodeDependencies = @import("../../src/app/Node.zig").NodeDependencies;
const Config = @import("../../src/app/Config.zig").Config;
const pipeline = @import("../../src/pipeline.zig");
const io_mod = @import("io_instance");

fn allocDataDir(allocator: std.mem.Allocator) ![]const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const salt: u64 = @as(u64, @intCast(ts.sec)) ^ (@as(u64, @intCast(ts.nsec)) << 1);
    return try std.fmt.allocPrint(allocator, "test_tmp/idx_e2e_{x}", .{salt});
}

fn cleanupDataDir(data_dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io_mod.io, data_dir) catch {};
}

test "E2E: transaction execution produces indexable events" {
    const allocator = std.testing.allocator;

    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = data_dir;

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();
    defer allocator.destroy(config);

    try node.start();
    defer node.stop();

    // Execute a transaction
    const tx = pipeline.Transaction{
        .sender = [_]u8{0x42} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "transfer"),
        .gas_budget = 1000,
        .sequence = 0,
    };
    defer allocator.free(tx.program);

    const result = try node.executeTransaction(tx);
    try std.testing.expect(result.status == .success);

    // Verify indexer has captured the event
    const indexer = node.indexer orelse {
        try std.testing.expect(false); // indexer must be initialized
        return;
    };
    const stats = indexer.stats();
    try std.testing.expect(stats.event_count >= 1);

    const events = indexer.getEventsForTransaction(result.digest);
    try std.testing.expect(events != null);
    try std.testing.expect(events.?.len >= 1);
    try std.testing.expectEqualStrings("success", events.?[0].event_type);
}

test "E2E: batch execution produces multiple indexed events" {
    const allocator = std.testing.allocator;

    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = data_dir;

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();
    defer allocator.destroy(config);

    try node.start();
    defer node.stop();

    var txs: [3]pipeline.Transaction = undefined;
    for (0..3) |i| {
        txs[i] = .{
            .sender = [_]u8{@intCast(i)} ** 32,
            .inputs = &.{},
            .program = try allocator.dupe(u8, "batch"),
            .gas_budget = 1000,
            .sequence = 0,
        };
    }
    defer for (0..3) |i| allocator.free(txs[i].program);

    const results = try node.executeTransactionBatch(&txs);
    defer allocator.free(results);

    const indexer = node.indexer orelse {
        try std.testing.expect(false);
        return;
    };
    const stats = indexer.stats();
    try std.testing.expect(stats.event_count >= 3);
}
