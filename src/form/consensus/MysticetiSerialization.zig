// Serialization utilities for Mysticeti consensus protocol
// Provides efficient network transmission and deserialization

const std = @import("std");
const core = @import("../../core.zig");
const Mysticeti = @import("Mysticeti.zig");
const Block = Mysticeti.Block;
const Round = Mysticeti.Round;
const Vote = Mysticeti.Vote;
const CommitCertificate = Mysticeti.CommitCertificate;

/// Optimized block serialization for network transmission
pub fn serializeBlock(block: Block, allocator: std.mem.Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256 + block.payload.len);
    errdefer buf.deinit();

    try buf.appendSlice(&block.author);
    var round_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &round_bytes, block.round.value, .big);
    try buf.appendSlice(&round_bytes);
    const payload_len: u32 = @intCast(block.payload.len);
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, payload_len, .big);
    try buf.appendSlice(&len_bytes);
    try buf.appendSlice(block.payload);
    const parents_len: u32 = @intCast(block.parents.len);
    var parents_len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &parents_len_bytes, parents_len, .big);
    try buf.appendSlice(&parents_len_bytes);
    for (block.parents) |parent| {
        var parent_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &parent_bytes, parent.value, .big);
        try buf.appendSlice(&parent_bytes);
    }
    try buf.appendSlice(&block.digest);

    return buf.toOwnedSlice();
}

/// Optimized block deserialization from network transmission
pub fn deserializeBlock(data: []const u8, allocator: std.mem.Allocator) !Block {
    if (data.len < 32 + 8 + 4 + 32) return error.InvalidFormat;
    var offset: usize = 0;

    const author = data[offset..][0..32].*;
    offset += 32;
    const round_value = std.mem.readInt(u64, data[offset..][0..8], .big);
    offset += 8;
    const round = Round{ .value = round_value };
    const payload_len = std.mem.readInt(u32, data[offset..][0..4], .big);
    offset += 4;
    const payload = try allocator.dupe(u8, data[offset..][0..payload_len]);
    offset += payload_len;
    const parents_len = std.mem.readInt(u32, data[offset..][0..4], .big);
    offset += 4;
    const parents = try allocator.alloc(Round, parents_len);
    for (0..parents_len) |i| {
        parents[i] = Round{ .value = std.mem.readInt(u64, data[offset..][0..8], .big) };
        offset += 8;
    }
    const digest = data[offset..][0..32].*;

    return Block{
        .author = author,
        .round = round,
        .payload = payload,
        .parents = parents,
        .votes = std.AutoArrayHashMapUnmanaged([32]u8, Vote).empty,
        .digest = digest,
    };
}

/// Serialize multiple blocks for batch transmission
pub fn serializeBlocksBatch(blocks: []const Block, allocator: std.mem.Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, blocks.len * 512);
    errdefer buf.deinit();

    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, @as(u32, @intCast(blocks.len)), .big);
    try buf.appendSlice(&count_bytes);

    for (blocks) |block| {
        const serialized = try serializeBlock(block, allocator);
        defer allocator.free(serialized);
        var size_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_bytes, @as(u32, @intCast(serialized.len)), .big);
        try buf.appendSlice(&size_bytes);
        try buf.appendSlice(serialized);
    }

    return buf.toOwnedSlice();
}

/// Deserialize multiple blocks from batch transmission
pub fn deserializeBlocksBatch(data: []const u8, allocator: std.mem.Allocator) ![]Block {
    if (data.len < 4) return error.InvalidBatchFormat;
    var offset: usize = 0;

    const count = std.mem.readInt(u32, data[offset..][0..4], .big);
    offset += 4;

    var blocks = try std.ArrayList(Block).initCapacity(allocator, count);
    errdefer blocks.deinit();

    for (0..count) |_| {
        if (offset + 4 > data.len) return error.InvalidBatchFormat;
        const size = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        if (offset + size > data.len) return error.InvalidBatchFormat;
        const block = try deserializeBlock(data[offset..][0..size], allocator);
        offset += size;

        try blocks.append(block);
    }

    return blocks.toOwnedSlice();
}

/// Optimized vote serialization for network transmission
pub fn serializeVote(vote: Vote, allocator: std.mem.Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 128);
    errdefer buf.deinit();

    try buf.appendSlice(&vote.voter);
    var stake_bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &stake_bytes, vote.stake, .big);
    try buf.appendSlice(&stake_bytes);
    var round_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &round_bytes, vote.round.value, .big);
    try buf.appendSlice(&round_bytes);
    try buf.appendSlice(&vote.block_digest);
    try buf.appendSlice(&vote.signature);

    return buf.toOwnedSlice();
}

/// Optimized vote deserialization from network transmission
pub fn deserializeVote(data: []const u8, allocator: std.mem.Allocator) !Vote {
    _ = allocator;
    if (data.len < 32 + 16 + 8 + 32 + 64) return error.InvalidVoteFormat;
    var offset: usize = 0;

    const voter = data[offset..][0..32].*;
    offset += 32;
    const stake = std.mem.readInt(u128, data[offset..][0..16], .big);
    offset += 16;
    const round_value = std.mem.readInt(u64, data[offset..][0..8], .big);
    offset += 8;
    const block_digest = data[offset..][0..32].*;
    offset += 32;
    const signature = data[offset..][0..64].*;

    return Vote{
        .voter = voter,
        .stake = stake,
        .round = .{ .value = round_value },
        .block_digest = block_digest,
        .signature = signature,
    };
}

/// Serialize a batch of votes for efficient transmission
pub fn serializeVotesBatch(votes: []const Vote, allocator: std.mem.Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, votes.len * 128 + 4);
    errdefer buf.deinit();

    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, @as(u32, @intCast(votes.len)), .big);
    try buf.appendSlice(&count_bytes);

    for (votes) |vote| {
        const serialized = try serializeVote(vote, allocator);
        defer allocator.free(serialized);
        var size_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_bytes, @as(u32, @intCast(serialized.len)), .big);
        try buf.appendSlice(&size_bytes);
        try buf.appendSlice(serialized);
    }

    return buf.toOwnedSlice();
}

/// Deserialize a batch of votes from network transmission
pub fn deserializeVotesBatch(data: []const u8, allocator: std.mem.Allocator) ![]Vote {
    if (data.len < 4) return error.InvalidBatchFormat;
    var offset: usize = 0;

    const count = std.mem.readInt(u32, data[offset..][0..4], .big);
    offset += 4;

    var votes = try std.ArrayList(Vote).initCapacity(allocator, count);
    errdefer votes.deinit();

    for (0..count) |_| {
        if (offset + 4 > data.len) return error.InvalidBatchFormat;
        const size = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        if (offset + size > data.len) return error.InvalidBatchFormat;
        const vote = try deserializeVote(data[offset..][0..size], allocator);
        offset += size;

        try votes.append(vote);
    }

    return votes.toOwnedSlice();
}

/// Optimized commit certificate serialization
pub fn serializeCommitCertificate(cert: CommitCertificate, allocator: std.mem.Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 128);
    errdefer buf.deinit();

    try buf.appendSlice(&cert.block_digest);
    var round_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &round_bytes, cert.round.value, .big);
    try buf.appendSlice(&round_bytes);
    var stake_bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &stake_bytes, cert.quorum_stake, .big);
    try buf.appendSlice(&stake_bytes);
    var confidence_bytes: [8]u8 = undefined;
    std.mem.writeInt(f64, &confidence_bytes, cert.confidence, .big);
    try buf.appendSlice(&confidence_bytes);

    return buf.toOwnedSlice();
}

/// Optimized commit certificate deserialization
pub fn deserializeCommitCertificate(data: []const u8, allocator: std.mem.Allocator) !CommitCertificate {
    _ = allocator;
    if (data.len < 32 + 8 + 16 + 8) return error.InvalidCertificateFormat;
    var offset: usize = 0;

    const block_digest = data[offset..][0..32].*;
    offset += 32;
    const round_value = std.mem.readInt(u64, data[offset..][0..8], .big);
    offset += 8;
    const quorum_stake = std.mem.readInt(u128, data[offset..][0..16], .big);
    offset += 16;
    const confidence = std.mem.readInt(f64, data[offset..][0..8], .big);

    return CommitCertificate{
        .block_digest = block_digest,
        .round = .{ .value = round_value },
        .quorum_stake = quorum_stake,
        .confidence = confidence,
    };
}

test "Block serialization" {
    const allocator = std.testing.allocator;
    const block = try Block.create(
        [_]u8{1} ** 32,
        .{ .value = 2 },
        "test payload",
        &[_]Round{ .{ .value = 0 }, .{ .value = 1 } },
        allocator,
    );
    defer block.deinit(allocator);

    const serialized = try serializeBlock(block, allocator);
    defer allocator.free(serialized);

    const deserialized = try deserializeBlock(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, &block.author, &deserialized.author));
    try std.testing.expect(block.round.value == deserialized.round.value);
    try std.testing.expect(std.mem.eql(u8, block.payload, deserialized.payload));
    try std.testing.expect(std.mem.eql(u8, &block.digest, &deserialized.digest));
}

test "Vote serialization" {
    const allocator = std.testing.allocator;
    const vote = Vote{
        .voter = [_]u8{2} ** 32,
        .stake = 1000,
        .round = .{ .value = 2 },
        .block_digest = [_]u8{0} ** 32,
        .signature = [_]u8{0} ** 64,
    };

    const serialized = try serializeVote(vote, allocator);
    defer allocator.free(serialized);

    const deserialized = try deserializeVote(serialized, allocator);
    try std.testing.expect(std.mem.eql(u8, &vote.voter, &deserialized.voter));
    try std.testing.expect(vote.stake == deserialized.stake);
    try std.testing.expect(vote.round.value == deserialized.round.value);
    try std.testing.expect(std.mem.eql(u8, &vote.block_digest, &deserialized.block_digest));
    try std.testing.expect(std.mem.eql(u8, &vote.signature, &deserialized.signature));
}

test "Batch operations" {
    const allocator = std.testing.allocator;
    const blocks = [_]Block{
        try Block.create([_]u8{1} ** 32, .{ .value = 0 }, "block 0", &.{}, allocator),
        try Block.create([_]u8{2} ** 32, .{ .value = 1 }, "block 1", &.{}, allocator),
    };
    defer blocks[0].deinit(allocator);
    defer blocks[1].deinit(allocator);

    const serialized = try serializeBlocksBatch(&blocks, allocator);
    defer allocator.free(serialized);

    const deserialized = try deserializeBlocksBatch(serialized, allocator);
    defer for (deserialized) |block| block.deinit(allocator);

    try std.testing.expect(deserialized.len == 2);
    try std.testing.expect(std.mem.eql(u8, &blocks[0].author, &deserialized[0].author));
    try std.testing.expect(std.mem.eql(u8, &blocks[1].author, &deserialized[1].author));
}
