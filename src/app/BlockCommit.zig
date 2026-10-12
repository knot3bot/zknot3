//! BlockCommit - block commit orchestration helpers
//!
//! Keeps Node focused on lifecycle and scheduling by extracting
//! quorum/certificate/promote-and-prune commit flow helpers.

const std = @import("std");
const Mysticeti = @import("../form/consensus/Mysticeti.zig");
const QuorumConfig = @import("../form/consensus/QuorumConfig.zig");

pub const BlockMap = std.AutoArrayHashMapUnmanaged([32]u8, Mysticeti.Block);

/// Total stake that has voted for `block`.
///
/// Vote weights are authoritative: `ConsensusIngressCoordinator.receiveVote`
/// replaces the wire value with the local stake pool's weight for the voter, so
/// a peer cannot inflate its own contribution.
pub fn gatheredStake(block: *const Mysticeti.Block) u128 {
    var sum: u128 = 0;
    var it = block.votes.iterator();
    while (it.next()) |entry| {
        // Saturating add: a malformed set of weights must not wrap to a small
        // total and accidentally satisfy the threshold.
        sum = std.math.add(u128, sum, entry.value_ptr.stake) catch return std.math.maxInt(u128);
    }
    return sum;
}

/// Whether the votes gathered on `block` carry enough stake to commit.
///
/// The test is stake-weighted against `QuorumConfig`, i.e. strictly more than
/// two thirds of `total_stake`. The previous check counted ballots
/// (`votes.count() >= vote_quorum`), which ignored stake entirely: four
/// validators holding 1% each would have passed the same bar as one holding
/// 90%, so the BFT safety argument did not hold on the commit path.
///
/// `vote_quorum` remains a floor on the number of distinct validators, keeping
/// the "no single voter can commit alone" property that a pure stake test on an
/// under-populated stake table would otherwise allow.
pub fn hasQuorum(block: *const Mysticeti.Block, total_stake: u128, vote_quorum: usize) bool {
    if (total_stake == 0) return false;
    if (block.votes.count() < vote_quorum) return false;
    return QuorumConfig.accepts(gatheredStake(block), total_stake);
}

pub fn buildCommitCertificate(block: *const Mysticeti.Block) Mysticeti.CommitCertificate {
    return .{
        .block_digest = block.digest,
        .round = block.round,
        // The real gathered stake, not a per-vote constant.
        .quorum_stake = gatheredStake(block),
        .confidence = 0.95,
    };
}

pub fn promotePendingBlock(
    allocator: std.mem.Allocator,
    pending: *BlockMap,
    committed: *BlockMap,
    digest: [32]u8,
    max_committed_blocks: usize,
    promoted_round: *u64,
) !bool {
    if (pending.get(digest)) |pending_block| {
        _ = pending.swapRemove(digest);
        try committed.put(allocator, digest, pending_block);

        while (committed.count() > max_committed_blocks) {
            const first_key = committed.keys()[0];
            if (committed.getPtr(first_key)) |block_ptr| {
                block_ptr.*.deinit(allocator);
            }
            _ = committed.swapRemove(first_key);
        }

        promoted_round.* = pending_block.round.value;
        return true;
    }
    return false;
}

test "hasQuorum is stake-weighted, not a ballot count" {
    const std2 = @import("std");

    // Two validators each holding 1 of 100 total stake. Two ballots is the old
    // `vote_quorum`, but 2% of stake is nowhere near two thirds.
    const total: u128 = 100;

    var block = Mysticeti.Block{
        .author = @splat(0),
        .round = .{ .value = 1 },
        .payload = &.{},
        .parents = &.{},
        .votes = .empty,
        .digest = @splat(0),
    };
    for ([_]u8{ 1, 2 }, [_]u128{ 1, 1 }) |id, w| {
        var voter_id: [32]u8 = @splat(0);
        voter_id[0] = id;
        try block.votes.put(std2.testing.allocator, voter_id, .{
            .voter = voter_id,
            .stake = w,
            .round = .{ .value = 1 },
            .block_digest = @splat(0),
            .signature = @splat(0),
        });
    }
    defer block.deinit(std2.testing.allocator);

    // Meets the ballot floor but not the stake bar.
    try std2.testing.expectEqual(@as(usize, 2), block.votes.count());
    try std2.testing.expectEqual(@as(u128, 2), gatheredStake(&block));
    try std2.testing.expect(!hasQuorum(&block, total, 2));

    // A single large holder does clear it, which is the whole point of
    // weighting by stake.
    var heavy = Mysticeti.Block{
        .author = @splat(0),
        .round = .{ .value = 1 },
        .payload = &.{},
        .parents = &.{},
        .votes = .empty,
        .digest = @splat(0),
    };
    for (0..70) |i| {
        var voter_id: [32]u8 = @splat(0);
        voter_id[0] = @as(u8, @intCast(i % 251)) + 1;
        try heavy.votes.put(std2.testing.allocator, voter_id, .{
            .voter = voter_id,
            .stake = 1,
            .round = .{ .value = 1 },
            .block_digest = @splat(0),
            .signature = @splat(0),
        });
    }
    defer heavy.deinit(std2.testing.allocator);
    try std2.testing.expect(hasQuorum(&heavy, total, 2));

    // No stake table at all -> nothing can commit (fail closed).
    try std2.testing.expect(!hasQuorum(&heavy, 0, 2));

    // The certificate reports the stake that actually gathered.
    try std2.testing.expectEqual(@as(u128, 70), buildCommitCertificate(&heavy).quorum_stake);
}
