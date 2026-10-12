//! ConsensusIngressCoordinator - block/vote ingress coordination for Node

const std = @import("std");
const Mysticeti = @import("../form/consensus/Mysticeti.zig");

pub const BlockMap = std.AutoArrayHashMapUnmanaged([32]u8, Mysticeti.Block);
pub const VoteIngressResult = union(enum) {
    accepted,
    duplicate,
    ignored_invalid,
    equivocation: Mysticeti.EquivocationEvidence,
};

/// Ingest a block received from a peer.
///
/// `block_data` must be a `Mysticeti.Block.serialize` payload — that is what
/// `ConsensusIntegration.onBlockReceived` forwards after deserializing it from
/// the wire.
///
/// This previously re-created a block with `block_data` as its *payload* and a
/// zero author/round, which produced a *different* digest from the proposer's.
/// Votes are signed over the real digest, so every vote failed to match the
/// stored pending block and a node could never reach quorum over real P2P.
///
/// The digest is recomputed and checked. `Block.deserialize` trusts the digest
/// carried in the wire bytes, so without this an attacker could inject a block
/// under any digest they liked and have it filed under a key that no honest
/// vote will ever match (or, worse, pre-empt a real block's slot).
pub fn receiveBlock(
    allocator: std.mem.Allocator,
    pending_blocks: *BlockMap,
    committed_blocks: *BlockMap,
    block_data: []const u8,
) !void {
    var block = Mysticeti.Block.deserialize(allocator, block_data) catch |err| switch (err) {
        error.InvalidFormat => return error.InvalidBlockFormat,
        else => return err,
    };
    errdefer block.deinit(allocator);

    // Recompute rather than trust the transmitted digest.
    const expected = Mysticeti.Block.computeDigest(block.author, block.round, block.payload, block.parents);
    if (!std.mem.eql(u8, &expected, &block.digest)) {
        return error.BlockDigestMismatch;
    }

    if (pending_blocks.contains(block.digest) or committed_blocks.contains(block.digest)) {
        // Already have this block. `errdefer` only fires on the error path, so
        // the freshly deserialized copy has to be released explicitly here —
        // otherwise every duplicate gossiped block leaks its payload.
        block.deinit(allocator);
        return;
    }

    try pending_blocks.put(allocator, block.digest, block);
}

pub fn receiveVote(
    allocator: std.mem.Allocator,
    pending_blocks: *BlockMap,
    committed_blocks: *BlockMap,
    vote_data: []const u8,
    /// Authoritative voting weight for a validator. Supplied by the caller so
    /// this module stays stateless.
    ///
    /// `Vote.stake` travels on the wire and is covered by the vote signature,
    /// which proves only *who* sent it, not *how much* they are worth. Storing
    /// the self-reported value would let any peer claim an arbitrary weight and
    /// manufacture a quorum on its own. The received value is therefore
    /// discarded and replaced with the node's own view of that validator.
    /// `null` means "no weight table available", in which case the vote is
    /// dropped rather than trusted.
    stake_of: ?*const fn (validator: [32]u8) u128,
) !VoteIngressResult {
    const vote = Mysticeti.Vote.deserialize(allocator, vote_data) catch return .ignored_invalid;
    if (!vote.verifySignature()) return .ignored_invalid;

    const weight_fn = stake_of orelse return .ignored_invalid;
    const real_stake = weight_fn(vote.voter);
    // Unknown validator, or one with no stake: it cannot contribute weight.
    if (real_stake == 0) return .ignored_invalid;
    var weighted = vote;
    weighted.stake = real_stake;

    if (findExistingVote(pending_blocks, weighted)) |existing_vote| {
        if (Mysticeti.detectEquivocation(existing_vote, weighted)) |evidence| {
            return .{ .equivocation = evidence };
        }
    }
    if (findExistingVote(committed_blocks, weighted)) |existing_vote| {
        if (Mysticeti.detectEquivocation(existing_vote, weighted)) |evidence| {
            return .{ .equivocation = evidence };
        }
    }

    if (pending_blocks.getPtr(weighted.block_digest)) |block| {
        if (!block.votes.contains(weighted.voter)) {
            try block.votes.put(allocator, weighted.voter, weighted);
            return .accepted;
        }
        return .duplicate;
    } else if (committed_blocks.getPtr(weighted.block_digest)) |block| {
        if (!block.votes.contains(weighted.voter)) {
            try block.votes.put(allocator, weighted.voter, weighted);
            return .accepted;
        }
        return .duplicate;
    }

    return .ignored_invalid;
}

fn findExistingVote(blocks: *BlockMap, incoming_vote: Mysticeti.Vote) ?Mysticeti.Vote {
    var it = blocks.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.round.value != incoming_vote.round.value) continue;
        if (entry.value_ptr.votes.get(incoming_vote.voter)) |existing_vote| {
            return existing_vote;
        }
    }
    return null;
}

test "receiveVote returns equivocation when same voter votes two digests in same round" {
    const allocator = std.testing.allocator;
    var pending_blocks: BlockMap = .empty;
    defer pending_blocks.deinit(allocator);
    var committed_blocks: BlockMap = .empty;
    defer committed_blocks.deinit(allocator);

    var block_a = try Mysticeti.Block.create(@as([32]u8, @splat(1)), .{ .value = 10 }, "a", &.{}, allocator);
    var block_b = try Mysticeti.Block.create(@as([32]u8, @splat(2)), .{ .value = 10 }, "b", &.{}, allocator);
    try pending_blocks.put(allocator, block_a.digest, block_a);
    try pending_blocks.put(allocator, block_b.digest, block_b);
    defer {
        if (pending_blocks.getPtr(block_a.digest)) |b| b.deinit(allocator);
        if (pending_blocks.getPtr(block_b.digest)) |b| b.deinit(allocator);
    }

    const seed = @as([32]u8, @splat(9));
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.SigningFailed;
    const voter = kp.public_key.toBytes();

    var msg_a: [40]u8 = undefined;
    std.mem.writeInt(u64, msg_a[0..8], block_a.round.value, .big);
    @memcpy(msg_a[8..40], &block_a.digest);
    const sig_a = try @import("../property/Signature.zig").Ed25519.sign(seed, &msg_a);
    // `Vote.signature` is a 96-byte field that holds either BLS (96 bytes) or
    // Ed25519 left-aligned in the first 64. `Ed25519.sign` returns 64 bytes, so
    // it must be widened here; this matches `Mysticeti.createVote`. The previous
    // direct assignment did not compile, which is why this equivocation test
    // had never been built or run.
    var sig_a_wide: [96]u8 = @splat(0);
    @memcpy(sig_a_wide[0..64], &sig_a);
    const vote_a = Mysticeti.Vote{
        .voter = voter,
        .stake = 100,
        .round = block_a.round,
        .block_digest = block_a.digest,
        .signature = sig_a_wide,
    };
    const vote_a_data = try vote_a.serialize(allocator);
    defer allocator.free(vote_a_data);
    const stake_of = struct {
        fn f(v: [32]u8) u128 {
            _ = v;
            return 100;
        }
    }.f;
    const first_result = try receiveVote(
        allocator,
        &pending_blocks,
        &committed_blocks,
        vote_a_data,
        &stake_of,
    );
    try std.testing.expect(first_result == .accepted);

    var msg_b: [40]u8 = undefined;
    std.mem.writeInt(u64, msg_b[0..8], block_b.round.value, .big);
    @memcpy(msg_b[8..40], &block_b.digest);
    const sig_b = try @import("../property/Signature.zig").Ed25519.sign(seed, &msg_b);
    var sig_b_wide: [96]u8 = @splat(0);
    @memcpy(sig_b_wide[0..64], &sig_b);
    const vote_b = Mysticeti.Vote{
        .voter = voter,
        .stake = 100,
        .round = block_b.round,
        .block_digest = block_b.digest,
        .signature = sig_b_wide,
    };
    const vote_b_data = try vote_b.serialize(allocator);
    defer allocator.free(vote_b_data);

    const second_result = try receiveVote(
        allocator,
        &pending_blocks,
        &committed_blocks,
        vote_b_data,
        &stake_of,
    );
    switch (second_result) {
        .equivocation => |ev| {
            try std.testing.expectEqual(vote_a.block_digest, ev.first_block_digest);
            try std.testing.expectEqual(vote_b.block_digest, ev.conflicting_block_digest);
        },
        else => return error.TestUnexpectedResult,
    }
}
