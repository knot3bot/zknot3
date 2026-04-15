//! Integration tests for Node transaction execution
//!
//! Tests the full flow through Node: consensus → executor → transaction execution

const std = @import("std");
const root = @import("root.zig");
const Node = root.app.Node;
const Executor = root.pipeline.Executor;
const Ingress = root.pipeline.Ingress;
const Mysticeti = root.form.consensus.Mysticeti;
const Quorum = root.form.consensus.Quorum;

test "Node.executeTransaction returns valid result" {
    const allocator = std.testing.allocator;
    const config = try allocator.create(root.app.Config);
    config.* = root.app.Config.default();

    var node = try Node.init(allocator, config);
    defer node.deinit();

    const tx = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 1,
    };

    const result = try node.executeTransaction(tx);
    try std.testing.expect(result.status == .success);
    try std.testing.expect(result.gas_used > 0);
}

test "Node.executeTransactionBatch handles multiple transactions" {
    const allocator = std.testing.allocator;
    const config = try allocator.create(root.app.Config);
    config.* = root.app.Config.default();

    var node = try Node.init(allocator, config);
    defer node.deinit();

    const tx1 = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 1,
    };

    const tx2 = Ingress.Transaction{
        .sender = [_]u8{2} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 2,
    };

    const txs = &[_]Ingress.Transaction{ tx1, tx2 };
    const results = try node.executeTransactionBatch(txs);

    try std.testing.expect(results.len == 2);
    try std.testing.expect(results[0].status == .success);
    try std.testing.expect(results[1].status == .success);
}

test "Node.getExecutorStats returns correct parallelism" {
    const allocator = std.testing.allocator;
    const config = try allocator.create(root.app.Config);
    config.* = root.app.Config.default();

    var node = try Node.init(allocator, config);
    defer node.deinit();

    const stats = node.getExecutorStats();
    try std.testing.expect(stats.parallelism == 4); // Default parallelism from config
}

test "Node.ExecutorStats struct initialization" {
    const stats = Node.ExecutorStats{
        .transactions_executed = 100,
        .total_gas_used = 50000,
        .parallelism = 8,
    };

    try std.testing.expect(stats.transactions_executed == 100);
    try std.testing.expect(stats.total_gas_used == 50000);
    try std.testing.expect(stats.parallelism == 8);
}

test "Executor batch execution produces valid results" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 2 });
    defer executor.deinit();

    const tx1 = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 1,
    };

    const tx2 = Ingress.Transaction{
        .sender = [_]u8{2} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 2,
    };

    const txs = &[_]Ingress.Transaction{ tx1, tx2 };
    const results = try executor.executeBatch(txs);

    try std.testing.expect(results.len == 2);
    try std.testing.expect(results[0].status == .success);
    try std.testing.expect(results[1].status == .success);
}

test "Executor single transaction execution" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 2 });
    defer executor.deinit();

    const tx = Ingress.Transaction{
        .sender = [_]u8{0x42} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 2000,
        .sequence = 42,
    };

    const result = try executor.execute(tx);
    try std.testing.expect(result.status == .success);
    try std.testing.expect(result.gas_used > 0);
    // Digest should be computed
    try std.testing.expect(result.digest.len == 32);
}
