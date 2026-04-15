//! Consensus Integration Test - End-to-end consensus flow test
//!
//! Tests the complete consensus flow:
//! 1. Quorum formation with 4 validators (2f+1 for BFT)
//! 2. Block proposal at multiple rounds
//! 3. Vote collection with stake weighting
//! 4. 3-round implicit commit rule
//! 5. Checkpoint creation on committed rounds

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

/// Test helper to create a validator ID
fn makeValidatorId(i: u8) [32]u8 {
    return [_]u8{i} ** 32;
}

/// Test that 4 validators can form a quorum
test "Consensus quorum formation" {
    const allocator = std.testing.allocator;
    
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    
    // Add 4 validators with 1000 stake each (total = 4000)
    // With f=1, quorum size = 2f+1 = 3
    try quorum.addValidator(makeValidatorId(1), 1000);
    try quorum.addValidator(makeValidatorId(2), 1000);
    try quorum.addValidator(makeValidatorId(3), 1000);
    try quorum.addValidator(makeValidatorId(4), 1000);
    
    try std.testing.expect(quorum.totalStake() == 4000);
    try std.testing.expect(quorum.byzantineThreshold() == 1);
    try std.testing.expect(quorum.quorumSize() == 3);
    try std.testing.expect(quorum.quorumStakeThreshold() == 2667); // 4000*2/3+1
}

/// Test block creation and DAG insertion
test "Consensus block proposal" {
    const allocator = std.testing.allocator;
    
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    
    try quorum.addValidator(makeValidatorId(1), 1000);
    try quorum.addValidator(makeValidatorId(2), 1000);
    
    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();
    
    // Propose a block at round 0
    const block = try consensus.proposeBlock(makeValidatorId(1), "tx data");
    defer block.deinit(allocator);
    
    try std.testing.expect(consensus.dag.contains(.{ .value = 0 }));
    
    // Block should be retrievable by author
    const round0 = consensus.dag.get(.{ .value = 0 }).?;
    try std.testing.expect(round0.contains(block.author));
}

/// Test vote collection and stake weighting
test "Consensus vote collection" {
    const allocator = std.testing.allocator;
    
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    
    // 4 validators with equal stake
    try quorum.addValidator(makeValidatorId(1), 1000);
    try quorum.addValidator(makeValidatorId(2), 1000);
    try quorum.addValidator(makeValidatorId(3), 1000);
    try quorum.addValidator(makeValidatorId(4), 1000);
    
    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();
    
    // Propose block at round 0
    const block = try consensus.proposeBlock(makeValidatorId(1), "tx data");
    
    // Cast votes from 3 validators (should reach quorum of 2667+)
    // 3 validators * 1000 stake = 3000 stake > 2667 threshold
    const vote1 = try consensus.createVote(makeValidatorId(1), makeValidatorId(1), 1000, block);
    const vote2 = try consensus.createVote(makeValidatorId(2), makeValidatorId(2), 1000, block);
    const vote3 = try consensus.createVote(makeValidatorId(3), makeValidatorId(3), 1000, block);
    
    try consensus.receiveVote(vote1);
    try consensus.receiveVote(vote2);
    try consensus.receiveVote(vote3);
    
    // Check stake threshold
    const threshold = (consensus.total_stake * 2) / 3 + 1;
    try std.testing.expect(block.hasQuorum(0, threshold));
}

/// Test 3-round commit rule
test "Consensus 3-round commit" {
    const allocator = std.testing.allocator;
    
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    
    // 4 validators with 1000 stake each
    try quorum.addValidator(makeValidatorId(1), 1000);
    try quorum.addValidator(makeValidatorId(2), 1000);
    try quorum.addValidator(makeValidatorId(3), 1000);
    try quorum.addValidator(makeValidatorId(4), 1000);
    
    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();
    
    // Round 0: Propose block
    const block0 = try consensus.proposeBlock(makeValidatorId(1), "round 0 tx");
    
    // Round 1: Propose block (references round 0)
    consensus.advanceRound();
    const block1 = try consensus.proposeBlock(makeValidatorId(2), "round 1 tx");
    
    // Round 2: Propose block (references round 0, 1)
    consensus.advanceRound();
    const block2 = try consensus.proposeBlock(makeValidatorId(3), "round 2 tx");
    
    // Cast votes for round 1 block to create QC
    // 3 validators * 1000 = 3000 > 2667 threshold
    const vote1a = try consensus.createVote(makeValidatorId(1), makeValidatorId(1), 1000, block1);
    const vote1b = try consensus.createVote(makeValidatorId(2), makeValidatorId(2), 1000, block1);
    const vote1c = try consensus.createVote(makeValidatorId(3), makeValidatorId(3), 1000, block1);
    
    try consensus.receiveVote(vote1a);
    try consensus.receiveVote(vote1b);
    try consensus.receiveVote(vote1c);
    
    // Now try to commit - round 0 should be committed when round 1 has QC
    // tryCommit checks if round (r+1) has QC, which means (r-2) is committed
    // With block1 having QC, we should be able to commit block0 (at round 0, which is r-2 when r=2)
    const cert = try consensus.tryCommit(.{ .value = 0 }, block0.digest);
    
    // Note: In Mysticeti, round r is committed when we observe a QC in round r+1
    // So round 0 is committed when round 1 has QC
    try std.testing.expect(cert != null);
    try std.testing.expect(cert.?.round.value == 0);
}

/// Test that insufficient votes don't create commit
test "Consensus no commit without quorum" {
    const allocator = std.testing.allocator;
    
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    
    // 4 validators
    try quorum.addValidator(makeValidatorId(1), 1000);
    try quorum.addValidator(makeValidatorId(2), 1000);
    try quorum.addValidator(makeValidatorId(3), 1000);
    try quorum.addValidator(makeValidatorId(4), 1000);
    
    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();
    
    // Round 0: Propose block
    const block0 = try consensus.proposeBlock(makeValidatorId(1), "round 0 tx");
    
    // Round 1: Propose block
    consensus.advanceRound();
    const block1 = try consensus.proposeBlock(makeValidatorId(2), "round 1 tx");
    
    // Only 2 votes (2000 stake < 2667 threshold) - should NOT reach quorum
    const vote1a = try consensus.createVote(makeValidatorId(1), makeValidatorId(1), 1000, block1);
    const vote1b = try consensus.createVote(makeValidatorId(2), makeValidatorId(2), 1000, block1);
    
    try consensus.receiveVote(vote1a);
    try consensus.receiveVote(vote1b);
    
    // Should NOT be able to commit round 0
    const cert = try consensus.tryCommit(.{ .value = 0 }, block0.digest);
    try std.testing.expect(cert == null);
}

/// Test checkpoint sequence on committed rounds
test "Checkpoint sequence integration" {
    const allocator = std.testing.allocator;
    
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    
    try quorum.addValidator(makeValidatorId(1), 1000);
    try quorum.addValidator(makeValidatorId(2), 1000);
    try quorum.addValidator(makeValidatorId(3), 1000);
    try quorum.addValidator(makeValidatorId(4), 1000);
    
    var consensus = try Mysticeti.init(allocator, &quorum);
    defer consensus.deinit();
    
    var checkpoint_seq = CheckpointSequence.init();
    defer checkpoint_seq.deinit();
    
    // Simulate committing blocks at rounds 0, 1, 2
    // Create commits
    const commit0 = CommitCertificate{
        .block_digest = [_]u8{0} ** 32,
        .round = .{ .value = 0 },
        .quorum_stake = 3000,
        .confidence = 0.99,
    };
    
    const commit1 = CommitCertificate{
        .block_digest = [_]u8{1} ** 32,
        .round = .{ .value = 1 },
        .quorum_stake = 3000,
        .confidence = 0.99,
    };
    
    // Create checkpoints
    const changes0 = &[_]Checkpoint.ObjectChange{};
    const cp0 = try Checkpoint.create(0, [_]u8{0} ** 32, changes0, allocator);
    checkpoint_seq.next(cp0);
    
    const changes1 = &[_]Checkpoint.ObjectChange{};
    const cp1 = try Checkpoint.create(1, cp0.digest(), changes1, allocator);
    checkpoint_seq.next(cp1);
    
    try std.testing.expect(checkpoint_seq.getLatestSequence() == 2);
}

/// Test validator canVote at epoch
test "Validator epoch voting" {
    const allocator = std.testing.allocator;
    
    // Create a validator
    const validator_pk = [_]u8{1} ** 32;
    var validator = try root.form.consensus.Validator.Validator.create(validator_pk, 1000, "TestValidator", allocator);
    defer validator.deinit(allocator);
    
    // Validator should be able to vote at epoch 0
    try std.testing.expect(validator.canVote(0));
    
    // Validator should be able to vote at epoch 100
    try std.testing.expect(validator.canVote(100));
    
    // Validator should NOT be able to vote before start epoch
    validator.start_epoch = 50;
    try std.testing.expect(!validator.canVote(49));
    try std.testing.expect(validator.canVote(50));
    
    // Validator should NOT be able to vote after end epoch
    validator.end_epoch = 100;
    try std.testing.expect(!validator.canVote(100));
    try std.testing.expect(validator.canVote(99));
}

/// Test byzantine threshold calculation
test "Byzantine threshold" {
    const allocator = std.testing.allocator;
    
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    
    // f = (n-1)/3
    // n=1: f=0, quorum=1
    try quorum.addValidator(makeValidatorId(1), 1000);
    try std.testing.expect(quorum.byzantineThreshold() == 0);
    try std.testing.expect(quorum.quorumSize() == 1);
    
    // n=4: f=1, quorum=3
    try quorum.addValidator(makeValidatorId(2), 1000);
    try quorum.addValidator(makeValidatorId(3), 1000);
    try quorum.addValidator(makeValidatorId(4), 1000);
    try std.testing.expect(quorum.byzantineThreshold() == 1);
    try std.testing.expect(quorum.quorumSize() == 3);
    
    // n=7: f=2, quorum=5
    // (7-1)/3 = 2
}

/// Test stake-weighted quorum
test "Stake weighted quorum" {
    const allocator = std.testing.allocator;
    
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    
    // Validator 1: 5000 stake (50%)
    // Validator 2: 3000 stake (30%)
    // Validator 3: 2000 stake (20%)
    // Total: 10000, threshold: 6667
    try quorum.addValidator(makeValidatorId(1), 5000);
    try quorum.addValidator(makeValidatorId(2), 3000);
    try quorum.addValidator(makeValidatorId(3), 2000);
    
    try std.testing.expect(quorum.totalStake() == 10000);
    try std.testing.expect(quorum.quorumStakeThreshold() == 6667); // 10000*2/3+1
    
    // Validator 1 alone should NOT reach quorum (5000 < 6667)
    const votes1 = &[_]Quorum.Vote{.{ .id = makeValidatorId(1), .stake = 5000 }};
    try std.testing.expect(!quorum.hasQuorum(votes1));
    
    // Validators 1+2 should reach quorum (5000+3000=8000 > 6667)
    const votes2 = &[_]Quorum.Vote{
        .{ .id = makeValidatorId(1), .stake = 5000 },
        .{ .id = makeValidatorId(2), .stake = 3000 },
    };
    try std.testing.expect(quorum.hasQuorum(votes2));
}