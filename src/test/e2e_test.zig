//! End-to-End Integration Tests
//!
//! Tests the complete flow from user transaction to committed state:
//! 1. Node lifecycle (init → start → stop → deinit)
//! 2. Transaction execution and receipt retrieval
//! 3. Block proposal and commitment
//! 4. Pipeline components integration (Ingress → Executor → Egress)

const std = @import("std");
const core = @import("../core.zig");
const NodeMod = @import("../app/Node.zig");
const Node = NodeMod.Node;
const NodeDependencies = NodeMod.NodeDependencies;
const CheckpointSequence = @import("../form/storage/Checkpoint.zig").CheckpointSequence;
const ConfigMod = @import("../app/Config.zig");
const IngressMod = @import("../pipeline/Ingress.zig");
const Ingress = IngressMod.Ingress;
const Transaction = IngressMod.Transaction;
const Executor = @import("../pipeline/Executor.zig").Executor;
const EgressMod = @import("../pipeline/Egress.zig");
const Egress = EgressMod.Egress;
const SignaturePair = EgressMod.SignaturePair;

test "E2E: Node lifecycle — init, start, stop, deinit" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const config = try allocator.create(ConfigMod.Config);
    config.* = ConfigMod.Config.default();
    defer allocator.destroy(config);

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    try node.start();
    node.stop();
}

test "E2E: Node info and stats" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const config = try allocator.create(ConfigMod.Config);
    config.* = ConfigMod.Config.default();
    defer allocator.destroy(config);

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    const info = node.getNodeInfo();
    try std.testing.expect(info.checkpoint_sequence >= 0);

    const stats = node.getExecutorStats();
    try std.testing.expect(stats.transactions_executed == 0);
}

test "E2E: Block proposal" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const config = try allocator.create(ConfigMod.Config);
    config.* = ConfigMod.Config.default();
    defer allocator.destroy(config);

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    try node.start();
    defer node.stop();

    const block = try node.proposeBlock("block_data_123");
    try std.testing.expect(block != null);
}

test "E2E: Transaction execution via Node" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const config = try allocator.create(ConfigMod.Config);
    config.* = ConfigMod.Config.default();
    defer allocator.destroy(config);

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    try node.start();
    defer node.stop();

    const program = try allocator.dupe(u8, "transfer");
    defer allocator.free(program);

    const tx = Transaction{
        .sender = [_]u8{0x42} ** 32,
        .inputs = &.{},
        .program = program,
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null,
        .public_key = null,
    };

    const result = try node.executeTransaction(tx);
    try std.testing.expect(result.status == .success);
    try std.testing.expect(result.gas_used > 0);
}

test "E2E: Pipeline integration — Ingress → Executor → Egress" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    var ingress = try Ingress.init(allocator, .{});
    defer ingress.deinit();

    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit();

    const program = try allocator.dupe(u8, "nop");
    defer allocator.free(program);

    const tx = Transaction{
        .sender = [_]u8{0x01} ** 32,
        .inputs = &.{},
        .program = program,
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null,
        .public_key = null,
    };

    try ingress.submit(tx);
    try ingress.verify();

    const verified = ingress.getVerified();
    try std.testing.expect(verified != null);

    const execution = try executor.execute(verified.?);
    try std.testing.expect(execution.status == .success);

    const signatures = &[_]SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{0xAA} ** 64, .stake = 1500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{0xBB} ** 64, .stake = 1500 },
    };

    const cert = try egress.aggregate(execution, signatures);
    try std.testing.expect(cert.stake_total == 3000);

    const commit = try egress.commit(cert);
    try std.testing.expect(commit.checkpoint_sequence >= 1);
}

test "E2E: Batch transaction execution via Node" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const config = try allocator.create(ConfigMod.Config);
    config.* = ConfigMod.Config.default();
    defer allocator.destroy(config);

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    try node.start();
    defer node.stop();

    const num_txs = 3;
    var programs: [3][]const u8 = undefined;
    var txs: [3]Transaction = undefined;

    for (0..num_txs) |i| {
        programs[i] = try allocator.dupe(u8, "batch_test");
        txs[i] = Transaction{
            .sender = [_]u8{@intCast(i)} ** 32,
            .inputs = &.{},
            .program = programs[i],
            .gas_budget = 1000,
            .sequence = @intCast(i),
            .signature = null,
            .public_key = null,
        };
    }
    defer for (0..num_txs) |i| allocator.free(programs[i]);

    const results = try node.executeTransactionBatch(&txs);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, num_txs), results.len);
    for (results) |result| {
        try std.testing.expect(result.status == .success);
    }
}
