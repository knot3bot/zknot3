//! 4-Node Cluster Integration Tests for zknot3
//!
//! Tests consensus and coordination across a 4-validator cluster (2f+1 BFT).
//! With f=1, we need 3-of-4 validators for quorum.

const std = @import("std");
const root = @import("root.zig");

const Mysticeti = root.form.consensus.Mysticeti;
const Quorum = root.form.consensus.Quorum;
const Block = root.form.consensus.Mysticeti.Block;
const Vote = root.form.consensus.Mysticeti.Vote;
const Round = root.form.consensus.Mysticeti.Round;
const CommitCertificate = root.form.consensus.Mysticeti.CommitCertificate;
const CheckpointSequence = root.form.storage.CheckpointSequence;
const Checkpoint = root.form.storage.Checkpoint;
const Executor = root.pipeline.Executor;
const Egress = root.pipeline.Egress;
const Ingress = root.pipeline.Ingress;

// =============================================================================
// Test Configuration
// =============================================================================

const TEST_VALIDATOR_COUNT = 4;
const STAKE_PER_VALIDATOR = 1000; // 1000 MIST each = 4000 total
const BYZANTINE_F = 1; // f = (n-1)/3 = 1
const QUORUM_SIZE = 3; // 2f+1 = 3
const QUORUM_STAKE_THRESHOLD = 2667; // 2/3 of 4000 + 1

fn makeValidatorId(i: u8) [32]u8 {
    return [_]u8{i} ** 32;
}

// =============================================================================
// Cluster Setup Helpers
// =============================================================================

/// Create a quorum with 4 validators
fn createTestQuorum(allocator: std.mem.Allocator) !Quorum {
    var quorum = try Quorum.init(allocator);
    errdefer quorum.deinit();

    try quorum.addValidator(makeValidatorId(1), STAKE_PER_VALIDATOR);
    try quorum.addValidator(makeValidatorId(2), STAKE_PER_VALIDATOR);
    try quorum.addValidator(makeValidatorId(3), STAKE_PER_VALIDATOR);
    try quorum.addValidator(makeValidatorId(4), STAKE_PER_VALIDATOR);

    return quorum;
}

/// Simulates a vote from a specific validator
fn simulateVote(
    consensus: *Mysticeti,
    voter_id: [32]u8,
    block: Block,
    stake: u64,
) !Vote {
    return try consensus.createVote(voter_id, voter_id, stake, block);
}

// =============================================================================
// 4-Node Cluster Consensus Tests
// =============================================================================

test "Cluster: 4-validator quorum formation" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    // Verify quorum properties
    try std.testing.expect(quorum.totalStake() == 4000);
    try std.testing.expect(quorum.byzantineThreshold() == BYZANTINE_F);
    try std.testing.expect(quorum.quorumSize() == QUORUM_SIZE);
    try std.testing.expect(quorum.quorumStakeThreshold() == QUORUM_STAKE_THRESHOLD);

    // 3 validators (3000 stake) should reach quorum
    const votes_3_validators = &[_]Quorum.Vote{
        .{ .id = makeValidatorId(1), .stake = STAKE_PER_VALIDATOR },
        .{ .id = makeValidatorId(2), .stake = STAKE_PER_VALIDATOR },
        .{ .id = makeValidatorId(3), .stake = STAKE_PER_VALIDATOR },
    };
    try std.testing.expect(quorum.hasQuorum(votes_3_validators));

    // 2 validators (2000 stake) should NOT reach quorum
    const votes_2_validators = &[_]Quorum.Vote{
        .{ .id = makeValidatorId(1), .stake = STAKE_PER_VALIDATOR },
        .{ .id = makeValidatorId(2), .stake = STAKE_PER_VALIDATOR },
    };
    try std.testing.expect(!quorum.hasQuorum(votes_2_validators));
}

test "Cluster: multi-round consensus progression" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    // Round 0: Block proposed by validator 1
    const block0 = try consensus.proposeBlock(makeValidatorId(1), "genesis block");
    defer block0.deinit(allocator);

    // Cast votes for round 0 (but we need to build on it)
    // Round 1: Propose new block referencing round 0
    consensus.advanceRound();
    const block1 = try consensus.proposeBlock(makeValidatorId(2), "round 1 block");
    defer block1.deinit(allocator);

    // Round 2: Propose block referencing round 1
    consensus.advanceRound();
    const block2 = try consensus.proposeBlock(makeValidatorId(3), "round 2 block");
    defer block2.deinit(allocator);

    // Verify DAG structure
    try std.testing.expect(consensus.dag.contains(.{ .value = 0 }));
    try std.testing.expect(consensus.dag.contains(.{ .value = 1 }));
    try std.testing.expect(consensus.dag.contains(.{ .value = 2 }));
}

test "Cluster: vote collection and stake aggregation" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    // Propose block at round 1
    const block = try consensus.proposeBlock(makeValidatorId(1), "test payload");
    defer block.deinit(allocator);

    // Collect votes from 3 validators (3000 stake > 2667 threshold)
    const vote1 = try simulateVote(consensus, makeValidatorId(1), block, STAKE_PER_VALIDATOR);
    const vote2 = try simulateVote(consensus, makeValidatorId(2), block, STAKE_PER_VALIDATOR);
    const vote3 = try simulateVote(consensus, makeValidatorId(3), block, STAKE_PER_VALIDATOR);

    try consensus.receiveVote(vote1);
    try consensus.receiveVote(vote2);
    try consensus.receiveVote(vote3);

    // Verify quorum achieved
    const threshold = quorum.quorumStakeThreshold();
    try std.testing.expect(block.hasQuorum(0, threshold));
}

test "Cluster: 3-round commit rule with stake weighting" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    // Round 0: Propose genesis block
    const block0 = try consensus.proposeBlock(makeValidatorId(1), "round 0");
    defer block0.deinit(allocator);

    // Round 1: Propose block referencing round 0
    consensus.advanceRound();
    const block1 = try consensus.proposeBlock(makeValidatorId(2), "round 1");
    defer block1.deinit(allocator);

    // Round 2: Propose block referencing round 1
    consensus.advanceRound();
    const block2 = try consensus.proposeBlock(makeValidatorId(3), "round 2");
    defer block2.deinit(allocator);

    // Collect QC for block1 (3 validators = 3000 stake)
    const vote1a = try simulateVote(consensus, makeValidatorId(1), block1, STAKE_PER_VALIDATOR);
    const vote1b = try simulateVote(consensus, makeValidatorId(2), block1, STAKE_PER_VALIDATOR);
    const vote1c = try simulateVote(consensus, makeValidatorId(3), block1, STAKE_PER_VALIDATOR);

    try consensus.receiveVote(vote1a);
    try consensus.receiveVote(vote1b);
    try consensus.receiveVote(vote1c);

    // With QC in round 1, round 0 should be committable
    const cert = try consensus.tryCommit(.{ .value = 0 }, block0.digest);
    try std.testing.expect(cert != null);
    try std.testing.expect(cert.?.round.value == 0);
}

test "Cluster: byzantine failure tolerance" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    // Propose block
    const block = try consensus.proposeBlock(makeValidatorId(1), "test");
    defer block.deinit(allocator);

    // With f=1 Byzantine, we can tolerate 1 malicious validator
    // 3 honest validators should still reach quorum

    // 2 honest + 1 Byzantine = 3 votes = quorum
    const vote1 = try simulateVote(consensus, makeValidatorId(1), block, STAKE_PER_VALIDATOR);
    const vote2 = try simulateVote(consensus, makeValidatorId(2), block, STAKE_PER_VALIDATOR);
    const vote3 = try simulateVote(consensus, makeValidatorId(3), block, STAKE_PER_VALIDATOR); // Byzantine might be validator 3

    try consensus.receiveVote(vote1);
    try consensus.receiveVote(vote2);
    try consensus.receiveVote(vote3);

    const threshold = quorum.quorumStakeThreshold();
    try std.testing.expect(block.hasQuorum(0, threshold));
}

test "Cluster: insufficient quorum detection" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    // Propose two blocks
    const block0 = try consensus.proposeBlock(makeValidatorId(1), "block 0");
    defer block0.deinit(allocator);

    consensus.advanceRound();
    const block1 = try consensus.proposeBlock(makeValidatorId(2), "block 1");
    defer block1.deinit(allocator);

    // Only 2 votes (2000 stake < 2667 threshold)
    const vote1 = try simulateVote(consensus, makeValidatorId(1), block1, STAKE_PER_VALIDATOR);
    const vote2 = try simulateVote(consensus, makeValidatorId(2), block1, STAKE_PER_VALIDATOR);

    try consensus.receiveVote(vote1);
    try consensus.receiveVote(vote2);

    // Should NOT be able to commit block0
    const cert = try consensus.tryCommit(.{ .value = 0 }, block0.digest);
    try std.testing.expect(cert == null);
}

test "Cluster: checkpoint sequence after commits" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    var checkpoints = CheckpointSequence.init();
    defer checkpoints.deinit();

    // Simulate committing rounds 0, 1, 2
    const commits = &[_]CommitCertificate{
        .{
            .block_digest = [_]u8{0} ** 32,
            .round = .{ .value = 0 },
            .quorum_stake = 3000,
            .confidence = 0.99,
        },
        .{
            .block_digest = [_]u8{1} ** 32,
            .round = .{ .value = 1 },
            .quorum_stake = 3000,
            .confidence = 0.99,
        },
        .{
            .block_digest = [_]u8{2} ** 32,
            .round = .{ .value = 2 },
            .quorum_stake = 3000,
            .confidence = 0.99,
        },
    };

    // Create checkpoints for committed rounds
    inline for (commits, 0..) |commit, i| {
        const changes: []const Checkpoint.ObjectChange = &.{};
        const cp = try Checkpoint.create(@intCast(i), commit.block_digest, changes, allocator);
        checkpoints.next(cp);
    }

    try std.testing.expect(checkpoints.getLatestSequence() == 3);
    try std.testing.expect(checkpoints.getCheckpoint(0) != null);
    try std.testing.expect(checkpoints.getCheckpoint(1) != null);
    try std.testing.expect(checkpoints.getCheckpoint(2) != null);
}

test "Cluster: egress certificate with 4-validator aggregate" {
    const allocator = std.testing.allocator;

    var egress = try Egress.init(allocator, 4000); // Total stake
    defer egress.deinit();

    const execution_result = Executor.ExecutionResult{
        .digest = [_]u8{1} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
    };

    // Aggregate signatures from 3 validators (3000 stake > 2667 threshold)
    const signatures = &[_]Egress.SignaturePair{
        .{ .validator = makeValidatorId(1), .signature = [_]u8{1} ** 64, .stake = 1000 },
        .{ .validator = makeValidatorId(2), .signature = [_]u8{2} ** 64, .stake = 1000 },
        .{ .validator = makeValidatorId(3), .signature = [_]u8{3} ** 64, .stake = 1000 },
    };

    const cert = try egress.aggregate(execution_result, signatures);
    try std.testing.expect(cert.stake_total == 3000);
}

test "Cluster: egress rejects with insufficient stake" {
    const allocator = std.testing.allocator;

    var egress = try Egress.init(allocator, 4000);
    defer egress.deinit();

    const execution_result = Executor.ExecutionResult{
        .digest = [_]u8{1} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
    };

    // Only 2 validators (2000 stake < 2667 threshold)
    const signatures = &[_]Egress.SignaturePair{
        .{ .validator = makeValidatorId(1), .signature = [_]u8{1} ** 64, .stake = 1000 },
        .{ .validator = makeValidatorId(2), .signature = [_]u8{2} ** 64, .stake = 1000 },
    };

    try std.testing.expectError(error.InsufficientStake, egress.aggregate(execution_result, signatures));
}

test "Cluster: unequal stake distribution" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    // Validator 1: 50% stake (2000)
    // Validator 2: 30% stake (1200)
    // Validator 3: 12.5% stake (500)
    // Validator 4: 7.5% stake (300)
    // Total: 4000, threshold: 2667
    try quorum.addValidator(makeValidatorId(1), 2000);
    try quorum.addValidator(makeValidatorId(2), 1200);
    try quorum.addValidator(makeValidatorId(3), 500);
    try quorum.addValidator(makeValidatorId(4), 300);

    try std.testing.expect(quorum.totalStake() == 4000);
    try std.testing.expect(quorum.quorumStakeThreshold() == 2667);

    // Validator 1 alone (50%) should NOT reach quorum
    const votes_1 = &[_]Quorum.Vote{.{ .id = makeValidatorId(1), .stake = 2000 }};
    try std.testing.expect(!quorum.hasQuorum(votes_1));

    // Validators 1+2 (3200) should reach quorum
    const votes_2 = &[_]Quorum.Vote{
        .{ .id = makeValidatorId(1), .stake = 2000 },
        .{ .id = makeValidatorId(2), .stake = 1200 },
    };
    try std.testing.expect(quorum.hasQuorum(votes_2));

    // Validators 1+2+3 (3700) should also reach quorum
    const votes_3 = &[_]Quorum.Vote{
        .{ .id = makeValidatorId(1), .stake = 2000 },
        .{ .id = makeValidatorId(2), .stake = 1200 },
        .{ .id = makeValidatorId(3), .stake = 500 },
    };
    try std.testing.expect(quorum.hasQuorum(votes_3));
}

test "Cluster: validator connectivity simulation" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    // Simulate a scenario where one validator is down
    // With f=1, we should still be able to make progress with 3 validators

    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();

    const block = try consensus.proposeBlock(makeValidatorId(1), "test");
    defer block.deinit(allocator);

    // Validator 4 is "down" - only 3 validators vote
    const vote1 = try simulateVote(consensus, makeValidatorId(1), block, STAKE_PER_VALIDATOR);
    const vote2 = try simulateVote(consensus, makeValidatorId(2), block, STAKE_PER_VALIDATOR);
    const vote3 = try simulateVote(consensus, makeValidatorId(3), block, STAKE_PER_VALIDATOR);

    try consensus.receiveVote(vote1);
    try consensus.receiveVote(vote2);
    try consensus.receiveVote(vote3);

    // Should still achieve quorum (3 validators = 3000 > 2667)
    const threshold = quorum.quorumStakeThreshold();
    try std.testing.expect(block.hasQuorum(0, threshold));
}
