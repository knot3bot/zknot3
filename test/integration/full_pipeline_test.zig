//! Full Pipeline Integration Tests for zknot3
//!
//! Tests the complete flow from transaction submission through
//! consensus and checkpoint finalization.

const std = @import("std");
const root = @import("root.zig");
const ObjectID = root.core.ObjectID;
const Versioned = root.core.Versioned;
const Ownership = root.core.Ownership;
const Ingress = root.pipeline.Ingress;
const Executor = root.pipeline.Executor;
const Egress = root.pipeline.Egress;
const ObjectStore = root.form.storage.ObjectStore;
const Checkpoint = root.form.storage.Checkpoint;
const Signature = root.property.crypto.Signature;
const Mysticeti = root.form.consensus.Mysticeti;
const Quorum = root.form.consensus.Quorum;
const MetricsCollector = root.metric.Metrics.MetricsCollector;
const EpochManager = root.metric.Epoch.EpochManager;

// =============================================================================
// Test Types
// =============================================================================

const Transaction = Ingress.Transaction;

fn createTestTransaction(sender: u8, sequence: u64) Transaction {
    return Transaction{
        .sender = [_]u8{sender} ** 32,
        .inputs = &.{},
        .program = try std.testing.allocator.dupe(u8, &.{ 0x31, 0x01 }), // ld_true; ret
        .gas_budget = 1000,
        .sequence = sequence,
    };
}

// =============================================================================
// Pipeline Integration Tests
// =============================================================================

test "Full pipeline: transaction from ingress to execution" {
    const allocator = std.testing.allocator;

    // Initialize components
    var ingress = try Ingress.init(allocator, .{});
    defer ingress.deinit();

    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    // Create and submit transaction
    const tx = createTestTransaction(1, 1);
    try ingress.submit(tx);

    // Verify it entered pending
    try std.testing.expect(ingress.pendingCount() == 1);

    // Verify transaction
    try ingress.verify();
    try std.testing.expect(ingress.verifiedCount() == 1);

    // Execute
    const result = try executor.execute(tx);
    try std.testing.expect(result.status == .success);
}

test "Full pipeline: multiple transactions ordering" {
    const allocator = std.testing.allocator;

    var ingress = try Ingress.init(allocator, .{ .max_pending = 100 });
    defer ingress.deinit();

    // Submit multiple transactions from same sender
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        const tx = Transaction{
            .sender = [_]u8{1} ** 32,
            .inputs = &.{},
            .program = &.{ 0x31, 0x01 },
            .gas_budget = 1000,
            .sequence = i + 1,
        };
        try ingress.submit(tx);
    }

    try std.testing.expect(ingress.pendingCount() == 5);

    // Verify all
    try ingress.verify();
    try std.testing.expect(ingress.verifiedCount() == 5);
}

test "Full pipeline: egress certificate aggregation" {
    const allocator = std.testing.allocator;

    var egress = try Egress.init(allocator, 3000); // Need 2/3 = 2000
    defer egress.deinit();

    const execution = Executor.ExecutionResult{
        .digest = [_]u8{1} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
    };

    // Collect signatures from validators with sufficient stake
    const signatures = &[_]Egress.SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 1500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{2} ** 64, .stake = 600 },
    };

    const cert = try egress.aggregate(execution, signatures);
    try std.testing.expect(cert.stake_total == 2100); // > 2000 threshold
}

test "Full pipeline: egress rejects insufficient stake" {
    const allocator = std.testing.allocator;

    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit();

    const execution = Executor.ExecutionResult{
        .digest = [_]u8{1} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
    };

    // Only 1000 stake, need 2000
    const signatures = &[_]Egress.SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{2} ** 64, .stake = 500 },
    };

    try std.testing.expectError(error.InsufficientStake, egress.aggregate(execution, signatures));
}

// =============================================================================
// Consensus Integration Tests
// =============================================================================

test "Full pipeline: consensus block creation and voting" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.Quorum.init(allocator);
    defer quorum.deinit();

    // Setup validators
    try quorum.addValidator([_]u8{1} ** 32, 1000);
    try quorum.addValidator([_]u8{2} ** 32, 1000);
    try quorum.addValidator([_]u8{3} ** 32, 1000);
    try quorum.addValidator([_]u8{4} ** 32, 1000);

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    // Create a block
    const parents = &[_]Mysticeti.Round{.{ .value = 0 }};
    var block = try Mysticeti.Block.create(
        [_]u8{1} ** 32,
        .{ .value = 1 },
        "test block payload",
        parents,
        allocator,
    );
    defer block.deinit();

    // Add block to consensus
    try consensus.addBlock(block);
    try std.testing.expect(consensus.dag.contains(.{ .value = 1 }));

    // Process votes from validators
    var vote = Mysticeti.Vote{
        .voter = [_]u8{2} ** 32,
        .stake = 1000,
        .round = .{ .value = 1 },
        .block_digest = block.digest,
        .signature = [_]u8{2} ** 64,
    };

    try consensus.processVote(vote);
}

test "Full pipeline: consensus quorum detection" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.Quorum.init(allocator);
    defer quorum.deinit();

    // 4 validators with 1000 stake each = 4000 total
    try quorum.addValidator([_]u8{1} ** 32, 1000);
    try quorum.addValidator([_]u8{2} ** 32, 1000);
    try quorum.addValidator([_]u8{3} ** 32, 1000);
    try quorum.addValidator([_]u8{4} ** 32, 1000);

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    // Create block
    const parents = &[_]Mysticeti.Round{ .{ .value = 0 }, .{ .value = 1 } };
    var block = try Mysticeti.Block.create(
        [_]u8{1} ** 32,
        .{ .value = 2 },
        "payload",
        parents,
        allocator,
    );
    defer block.deinit();

    try consensus.addBlock(block);

    // Check quorum threshold
    const threshold = (consensus.total_stake * 2) / 3;
    try std.testing.expect(threshold == 2666); // 2/3 of 4000
}

// =============================================================================
// Object Store Integration Tests
// =============================================================================

test "Full pipeline: object storage and retrieval" {
    const allocator = std.testing.allocator;

    var store = try ObjectStore.init(allocator, .{});
    defer store.deinit();

    // Create object
    const obj = ObjectStore.Object{
        .id = ObjectID.hash("test_key"),
        .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
        .ownership = Ownership.ownedBy([_]u8{0xAB} ** 32),
        .type_tag = 1,
        .data = try allocator.dupe(u8, "test data"),
    };

    try store.put(obj);

    // Retrieve
    const retrieved = try store.getLatest(obj.id);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.id.eql(obj.id));
}

test "Full pipeline: object version tracking" {
    const allocator = std.testing.allocator;

    var store = try ObjectStore.init(allocator, .{});
    defer store.deinit();

    const id = ObjectID.hash("versioned_key");

    // Create initial version
    const obj1 = ObjectStore.Object{
        .id = id,
        .version = .{ .seq = 1, .causal = [_]u8{1} ** 16 },
        .ownership = Ownership.ownedBy([_]u8{0xAB} ** 32),
        .type_tag = 1,
        .data = try allocator.dupe(u8, "version 1"),
    };

    try store.put(obj1);

    // Create next version
    const obj2 = ObjectStore.Object{
        .id = id,
        .version = .{ .seq = 2, .causal = [_]u8{2} ** 16 },
        .ownership = Ownership.ownedBy([_]u8{0xAB} ** 32),
        .type_tag = 1,
        .data = try allocator.dupe(u8, "version 2"),
    };

    try store.put(obj2);

    // Latest should be version 2
    const latest = try store.getLatest(id);
    try std.testing.expect(latest != null);
    try std.testing.expect(latest.?.version.seq == 2);
}

// =============================================================================
// Checkpoint Integration Tests
// =============================================================================

test "Full pipeline: checkpoint creation with changes" {
    const allocator = std.testing.allocator;

    const changes = &[_]Checkpoint.ObjectChange{
        .{
            .id = ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
        .{
            .id = ObjectID.hash("obj2"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .modified,
        },
        .{
            .id = ObjectID.hash("obj3"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .deleted,
        },
    };

    const cp = try Checkpoint.create(1, [_]u8{0xAB} ** 32, changes, allocator);
    defer cp.deinit();

    try std.testing.expect(cp.sequence == 1);
    try std.testing.expect(cp.object_changes.len == 3);

    // Digest should be deterministic
    const digest1 = cp.digest();
    const digest2 = cp.digest();
    try std.testing.expect(std.mem.eql(u8, &digest1, &digest2));
}

// =============================================================================
// Metrics Integration Tests
// =============================================================================

test "Full pipeline: metrics collection" {
    const allocator = std.testing.allocator;

    var collector = try MetricsCollector.init(allocator, 100);
    defer collector.deinit();

    // Record metrics
    try collector.record(.{ .wu_feng = 0.8, .xiang_da = 0.7, .zi_zai = 0.9 });
    try collector.record(.{ .wu_feng = 0.9, .xiang_da = 0.8, .zi_zai = 0.85 });

    // Check rolling average
    const avg = collector.average();
    try std.testing.expect(avg.wu_feng > 0.84);
    try std.testing.expect(avg.wu_feng < 0.86);
}

test "Full pipeline: epoch management" {
    const allocator = std.testing.allocator;

    var manager = try EpochManager.init(allocator, .{}, 1000);
    defer manager.deinit();

    const epoch = manager.getCurrentEpoch();
    try std.testing.expect(epoch.number == 0);
    try std.testing.expect(!epoch.finalized);

    // Advance epoch
    try manager.advanceEpoch(5000, 4);
    const new_epoch = manager.getCurrentEpoch();
    try std.testing.expect(new_epoch.number == 1);
    try std.testing.expect(!new_epoch.finalized);
}

// =============================================================================
// Signature Integration Tests
// =============================================================================

test "Full pipeline: sign and verify transaction" {
    const message = "test transaction data";
    const message_bytes = message.*;

    const seed = [_]u8{0xAB} ** 32;
    const secret_key = Signature.generateSecretKey(seed);
    const public_key = Signature.derivePublicKey(secret_key);

    // Sign
    const signature = Signature.sign(&message_bytes, secret_key);

    // Verify
    const valid = Signature.verify(&message_bytes, signature, public_key);
    try std.testing.expect(valid);
}

test "Full pipeline: signature fails with wrong key" {
    const message = "test transaction";
    const message_bytes = message.*;

    const seed1 = [_]u8{0xAB} ** 32;
    const seed2 = [_]u8{0xCD} ** 32;

    const secret_key1 = Signature.generateSecretKey(seed1);
    const public_key1 = Signature.derivePublicKey(secret_key1);
    const public_key2 = Signature.derivePublicKey(Signature.generateSecretKey(seed2));

    const signature = Signature.sign(&message_bytes, secret_key1);

    // Should fail with different public key
    const valid = Signature.verify(&message_bytes, signature, public_key2);
    try std.testing.expect(!valid);
}

// =============================================================================
// End-to-End Scenarios
// =============================================================================

test "E2E: transaction lifecycle" {
    const allocator = std.testing.allocator;

    // 1. Create components
    var ingress = try Ingress.init(allocator, .{ .max_pending = 10 });
    defer ingress.deinit();

    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit();

    // 2. Create and submit transaction
    const tx = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 },
        .gas_budget = 1000,
        .sequence = 1,
    };

    try ingress.submit(tx);
    try ingress.verify();

    // 3. Execute
    const result = try executor.execute(tx);
    try std.testing.expect(result.status == .success);

    // 4. Create certificate
    const execution_result = Executor.ExecutionResult{
        .digest = tx.digest(),
        .status = result.status,
        .gas_used = result.gas_used,
        .output_objects = &.{},
    };

    const signatures = &[_]Egress.SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 2000 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{2} ** 64, .stake = 1500 },
    };

    const cert = try egress.aggregate(execution_result, signatures);
    try std.testing.expect(cert.stake_total > 2000);
}
