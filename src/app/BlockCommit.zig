//! BlockCommit - block commit orchestration helpers
//!
//! Keeps Node focused on lifecycle and scheduling by extracting
//! quorum/certificate/promote-and-prune commit flow helpers.

const std = @import("std");
const Mysticeti = @import("../form/consensus/Mysticeti.zig");

pub const BlockMap = std.AutoArrayHashMapUnmanaged([32]u8, Mysticeti.Block);

pub fn hasQuorum(block: *const Mysticeti.Block, vote_quorum: usize) bool {
    return block.votes.count() >= vote_quorum;
}

pub fn buildCommitCertificate(block: *const Mysticeti.Block) Mysticeti.CommitCertificate {
    return .{
        .block_digest = block.digest,
        .round = block.round,
        .quorum_stake = @as(u128, @intCast(block.votes.count())) * 1000,
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

