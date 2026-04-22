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

pub fn receiveBlock(
    allocator: std.mem.Allocator,
    pending_blocks: *BlockMap,
    committed_blocks: *BlockMap,
    block_data: []const u8,
) !void {
    var block = try Mysticeti.Block.create(
        .{0} ** 32,
        Mysticeti.Round{ .value = 0 },
        block_data,
        &.{},
        allocator,
    );

    if (pending_blocks.contains(block.digest) or committed_blocks.contains(block.digest)) {
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
) !VoteIngressResult {
    const vote = Mysticeti.Vote.deserialize(allocator, vote_data) catch return .ignored_invalid;
    if (!vote.verifySignature()) return .ignored_invalid;

    if (findExistingVote(pending_blocks, vote)) |existing_vote| {
        if (Mysticeti.detectEquivocation(existing_vote, vote)) |evidence| {
            return .{ .equivocation = evidence };
        }
    }
    if (findExistingVote(committed_blocks, vote)) |existing_vote| {
        if (Mysticeti.detectEquivocation(existing_vote, vote)) |evidence| {
            return .{ .equivocation = evidence };
        }
    }

    if (pending_blocks.getPtr(vote.block_digest)) |block| {
        if (!block.votes.contains(vote.voter)) {
            try block.votes.put(allocator, vote.voter, vote);
            return .accepted;
        }
        return .duplicate;
    } else if (committed_blocks.getPtr(vote.block_digest)) |block| {
        if (!block.votes.contains(vote.voter)) {
            try block.votes.put(allocator, vote.voter, vote);
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

    var block_a = try Mysticeti.Block.create([_]u8{1} ** 32, .{ .value = 10 }, "a", &.{}, allocator);
    var block_b = try Mysticeti.Block.create([_]u8{2} ** 32, .{ .value = 10 }, "b", &.{}, allocator);
    try pending_blocks.put(allocator, block_a.digest, block_a);
    try pending_blocks.put(allocator, block_b.digest, block_b);
    defer {
        if (pending_blocks.getPtr(block_a.digest)) |b| b.deinit(allocator);
        if (pending_blocks.getPtr(block_b.digest)) |b| b.deinit(allocator);
    }

    const seed = [_]u8{9} ** 32;
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.SigningFailed;
    const voter = kp.public_key.toBytes();

    var msg_a: [40]u8 = undefined;
    std.mem.writeInt(u64, msg_a[0..8], block_a.round.value, .big);
    @memcpy(msg_a[8..40], &block_a.digest);
    const sig_a = try @import("../property/Signature.zig").Ed25519.sign(seed, &msg_a);
    const vote_a = Mysticeti.Vote{
        .voter = voter,
        .stake = 100,
        .round = block_a.round,
        .block_digest = block_a.digest,
        .signature = sig_a,
    };
    const vote_a_data = try vote_a.serialize(allocator);
    defer allocator.free(vote_a_data);
    const first_result = try receiveVote(allocator, &pending_blocks, &committed_blocks, vote_a_data);
    try std.testing.expect(first_result == .accepted);

    var msg_b: [40]u8 = undefined;
    std.mem.writeInt(u64, msg_b[0..8], block_b.round.value, .big);
    @memcpy(msg_b[8..40], &block_b.digest);
    const sig_b = try @import("../property/Signature.zig").Ed25519.sign(seed, &msg_b);
    const vote_b = Mysticeti.Vote{
        .voter = voter,
        .stake = 100,
        .round = block_b.round,
        .block_digest = block_b.digest,
        .signature = sig_b,
    };
    const vote_b_data = try vote_b.serialize(allocator);
    defer allocator.free(vote_b_data);

    const second_result = try receiveVote(allocator, &pending_blocks, &committed_blocks, vote_b_data);
    switch (second_result) {
        .equivocation => |ev| {
            try std.testing.expectEqual(vote_a.block_digest, ev.first_block_digest);
            try std.testing.expectEqual(vote_b.block_digest, ev.conflicting_block_digest);
        },
        else => return error.TestUnexpectedResult,
    }
}

