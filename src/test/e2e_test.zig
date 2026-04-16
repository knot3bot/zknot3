//! End-to-End Integration Tests
//!
//! Tests the complete flow from user transaction to committed object state:
//! 1. User submits transaction via Node
//! 2. Transaction enters Pipeline (Ingress -> Executor -> Egress)
//! 3. Transaction result is stored in ObjectStore
//! 4. Committed state is verifiable from ObjectStore

const std = @import("std");
const core = @import("../core.zig");
const Node = @import("../app/Node.zig").Node;
const CheckpointSequence = @import("../form/storage/Checkpoint.zig").CheckpointSequence;
const ObjectStore = @import("../form/storage/ObjectStore.zig").ObjectStore;
const Ingress = @import("Ingress.zig");
const Executor = @import("Executor.zig");
const Egress = @import("Egress.zig");
const pipeline = @import("../pipeline.zig");

test "E2E: Node with ObjectStore - object lifecycle" {
    const allocator = std.testing.allocator;
    ("root").io_instance = std.testing.io;
    const test_dir = "/tmp/e2e_object_test";

    // Clean up
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};

    // Initialize components
    const config = try allocator.create(@import("../app/Config.zig").Config);
    config.* = @import("../app/Config.zig").Config.default();

    const deps = Node.NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    // Start node
    try node.start();
    defer node.stop();

    // Create an object and store it
    const object_id = core.ObjectID{ .bytes = [_]u8{0xAB} ** 32 };
    const object = ObjectStore.Object{
        .id = object_id,
        .owner = core.Address{ .bytes = [_]u8{0x42} ** 32 },
        .data = try allocator.dupe(u8, "test object data"),
        .version = 1,
        .type = core.ObjectType{ .module = "test", .name = "TestObject" },
    };
    defer allocator.free(object.data);

    try node.putObject(object);

    // Retrieve object
    const retrieved = try node.getObject(object_id);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u64, 1), retrieved.?.version);
}

test "E2E: Transaction execution and receipt retrieval" {
    const allocator = std.testing.allocator;
    ("root").io_instance = std.testing.io;

    const config = try allocator.create(@import("../app/Config.zig").Config);
    config.* = @import("../app/Config.zig").Config.default();

    const deps = Node.NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    try node.start();
    defer node.stop();

    // Create and submit a transaction
    const tx = pipeline.Transaction{
        .sender = [_]u8{0x42} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "transfer"),
        .gas_budget = 1000,
        .sequence = 1,
    };
    defer allocator.free(tx.program);

    // Execute transaction
    const result = try node.executeTransaction(tx);
    try std.testing.expect(result.status == .success);
    try std.testing.expect(result.gas_used > 0);

    // Get receipt
    const receipt = node.getTransactionReceipt(result.digest);
    try std.testing.expect(receipt != null);
    try std.testing.expect(receipt.?.status == .success);
}

test "E2E: Block commit workflow" {
    const allocator = std.testing.allocator;
    ("root").io_instance = std.testing.io;

    const config = try allocator.create(@import("../app/Config.zig").Config);
    config.* = @import("../app/Config.zig").Config.default();

    const deps = Node.NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    try node.start();
    defer node.stop();

    // Propose a block
    const payload = "block_data_123";
    const block = try node.proposeBlock(payload);
    try std.testing.expect(block != null);

    // Verify block is in pending blocks
    const pending = node.pending_blocks.count();
    try std.testing.expect(pending >= 1);
}

test "E2E: Pipeline components integration" {
    const allocator = std.testing.allocator;
    ("root").io_instance = std.testing.io;

    // Initialize pipeline
    var ingress = try Ingress.init(allocator, .{ .max_pending = 100 });
    defer ingress.deinit(allocator);

    var executor = try Executor.init(allocator, .{ .parallelism = 2 });
    defer executor.deinit();

    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit(allocator);

    // Submit transaction
    const tx = pipeline.Transaction{
        .sender = [_]u8{0x01} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "nop"),
        .gas_budget = 1000,
        .sequence = 1,
    };
    defer allocator.free(tx.program);

    try ingress.submit(tx);
    try ingress.verify();

    const verified = ingress.getVerified();
    try std.testing.expect(verified != null);

    // Execute
    const execution = try executor.execute(verified.?);
    try std.testing.expect(execution.status == .success);

    // Create certificate
    const signatures = &[_]Egress.SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{0xAA} ** 64, .stake = 1500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{0xBB} ** 64, .stake = 1500 },
    };

    const cert = try egress.aggregate(execution, signatures);
    try std.testing.expect(cert.stake_total == 3000);

    // Commit
    const commit = try egress.commit(cert);
    try std.testing.expect(commit.checkpoint_sequence >= 1);
}

test "E2E: Node with checkpoint sequence" {
    const allocator = std.testing.allocator;
    ("root").io_instance = std.testing.io;

    const config = try allocator.create(@import("../app/Config.zig").Config);
    config.* = @import("../app/Config.zig").Config.default();

    const deps = Node.NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    try node.start();
    defer node.stop();

    // Get initial node info
    const info = node.getNodeInfo();
    try std.testing.expect(info.checkpoint_sequence == 0);

    // Verify node stats are accessible
    const stats = node.getExecutorStats();
    try std.testing.expect(stats.transactions_executed == 0);
}

test "E2E: Node state transitions" {
    const allocator = std.testing.allocator;
    ("root").io_instance = std.testing.io;

    const config = try allocator.create(@import("../app/Config.zig").Config);
    config.* = @import("../app/Config.zig").Config.default();

    const deps = Node.NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    // Initial state
    try std.testing.expect(node.state == .initializing);
    try std.testing.expect(node.isRunning() == false);

    // Start
    try node.start();
    try std.testing.expect(node.state == .running);
    try std.testing.expect(node.isRunning() == true);

    // Stop
    node.stop();
    try std.testing.expect(node.state == .stopped);
    try std.testing.expect(node.isRunning() == false);
}

test "E2E: Batch transaction execution" {
    const allocator = std.testing.allocator;
    ("root").io_instance = std.testing.io;

    const config = try allocator.create(@import("../app/Config.zig").Config);
    config.* = @import("../app/Config.zig").Config.default();

    const deps = Node.NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    try node.start();
    defer node.stop();

    // Execute multiple transactions
    const num_txs = 3;
    var txs: [num_txs]pipeline.Transaction = undefined;

    for (0..num_txs) |i| {
        txs[i] = pipeline.Transaction{
            .sender = [_]u8{@intCast(i)} ** 32,
            .inputs = &.{},
            .program = try allocator.dupe(u8, "batch_test"),
            .gas_budget = 1000,
            .sequence = @intCast(i),
        };
    }
    defer for (0..num_txs) |i| allocator.free(txs[i].program);

    const results = try node.executeTransactionBatch(&txs);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, num_txs), results.len);

    for (results) |result| {
        try std.testing.expect(result.status == .success);
    }
}
