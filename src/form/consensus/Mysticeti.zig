//! Mysticeti - DAG-based consensus protocol

const std = @import("std");
const core = @import("../../core.zig");
const Quorum = @import("Quorum.zig");
const Signature = @import("../../property/Signature.zig").Ed25519;

pub const Round = struct {
    value: u64,

    const Self = @This();

    pub fn lessThan(self: Self, other: Self) bool {
        return self.value < other.value;
    }

    pub fn predecessors(self: Self, other: Self) bool {
        return self.value <= other.value;
    }
};

pub const Block = struct {
    author: [32]u8,
    round: Round,
    payload: []const u8,
    parents: []const Round,
    votes: std.AutoArrayHashMapUnmanaged([32]u8, Vote),
    digest: [32]u8,

    const Self = @This();

    pub fn create(
        author: [32]u8,
        round: Round,
        payload: []const u8,
        parents: []const Round,
        allocator: std.mem.Allocator,
    ) !Self {
        var block = Self{
            .author = author,
            .round = round,
            .payload = try allocator.dupe(u8, payload),
            .parents = try allocator.dupe(Round, parents),
            .votes = .empty,
            .digest = undefined,
        };

        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&author);
        var round_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &round_bytes, round.value, .big);
        ctx.update(&round_bytes);
        ctx.update(payload);
        ctx.final(&block.digest);

        return block;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.parents);
        self.votes.deinit(allocator);
    }

    pub fn hasQuorum(self: Self, _: u128, threshold: u128) bool {
        var stake_sum: u128 = 0;
        var it = self.votes.iterator();
        while (it.next()) |entry| {
            stake_sum += entry.value_ptr.stake;
        }
        return stake_sum * 3 >= threshold * 2;
    }

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, &self.author);
        var round_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &round_bytes, self.round.value, .big);
        try buf.appendSlice(allocator, &round_bytes);
        const payload_len: u32 = @intCast(self.payload.len);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, payload_len, .big);
        try buf.appendSlice(allocator, &len_bytes);
        try buf.appendSlice(allocator, self.payload);
        const parents_len: u32 = @intCast(self.parents.len);
        var parents_len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &parents_len_bytes, parents_len, .big);
        try buf.appendSlice(allocator, &parents_len_bytes);
        for (self.parents) |parent| {
            var parent_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &parent_bytes, parent.value, .big);
            try buf.appendSlice(allocator, &parent_bytes);
        }
        try buf.appendSlice(allocator, &self.digest);

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !Self {
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

        return Self{
            .author = author,
            .round = round,
            .payload = payload,
            .parents = parents,
            .votes = .empty,
            .digest = digest,
        };
    }
};

pub const Vote = struct {
    voter: [32]u8,
    stake: u128,
    round: Round,
    block_digest: [32]u8,
    signature: [64]u8,

    const Self = @This();

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
        try buf.appendSlice(allocator, &self.voter);
        var stake_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &stake_bytes, self.stake, .big);
        try buf.appendSlice(allocator, &stake_bytes);
        var round_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &round_bytes, self.round.value, .big);
        try buf.appendSlice(allocator, &round_bytes);
        try buf.appendSlice(allocator, &self.block_digest);
        try buf.appendSlice(allocator, &self.signature);
        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(_: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 128) return error.InvalidFormat;
        var offset: usize = 0;
        const voter = data[offset..][0..32].*;
        offset += 32;
        const stake = std.mem.readInt(u128, data[offset..][0..16], .big);
        offset += 16;
        const round = Round{ .value = std.mem.readInt(u64, data[offset..][0..8], .big) };
        offset += 8;
        const block_digest = data[offset..][0..32].*;
        offset += 32;
        const signature = data[offset..][0..64].*;
        return Self{
            .voter = voter,
            .stake = stake,
            .round = round,
            .block_digest = block_digest,
            .signature = signature,
        };
    }

    /// Verify the vote signature using Ed25519
    pub fn verifySignature(self: Self) bool {
        const Ed25519 = @import("../../property/Signature.zig").Ed25519;
        var message: [40]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], self.round.value, .big);
        @memcpy(message[8..40], &self.block_digest);
        return Ed25519.verify(self.voter, &message, self.signature);
    }

};

pub const CommitCertificate = struct {
    block_digest: [32]u8,
    round: Round,
    quorum_stake: u128,
    confidence: f64,

    const Self = @This();

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 128);
        try buf.appendSlice(allocator, &self.block_digest);
        var round_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &round_bytes, self.round.value, .big);
        try buf.appendSlice(allocator, &round_bytes);
        var stake_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &stake_bytes, self.quorum_stake, .big);
        try buf.appendSlice(allocator, &stake_bytes);
        try buf.appendSlice(allocator, &std.mem.toBytes(self.confidence));
        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(_: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 68) return error.InvalidFormat;
        var offset: usize = 0;
        const block_digest = data[offset..][0..32].*;
        offset += 32;
        const round = Round{ .value = std.mem.readInt(u64, data[offset..][0..8], .big) };
        offset += 8;
        const quorum_stake = std.mem.readInt(u128, data[offset..][0..16], .big);
        offset += 16;
        const confidence = std.mem.readFloat(f64, data[offset..][0..8]);
        return Self{
            .block_digest = block_digest,
            .round = round,
            .quorum_stake = quorum_stake,
            .confidence = confidence,
        };
    }
};

pub const Mysticeti = struct {
    allocator: std.mem.Allocator,
    dag: std.AutoArrayHashMapUnmanaged(Round, std.AutoArrayHashMapUnmanaged([32]u8, Block)),
    committed_rounds: std.AutoArrayHashMapUnmanaged(Round, void),
    current_round: Round,
    quorum: *Quorum.Quorum,
    total_stake: u128,
    f: usize,
    latency_lambda: f64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, quorum: *Quorum.Quorum) !*Self {
        const self_ptr = try allocator.create(Self);
        self_ptr.* = .{
            .allocator = allocator,
            .dag = .empty,
            .committed_rounds = .empty,
            .current_round = .{ .value = 0 },
            .quorum = quorum,
            .total_stake = quorum.totalStake(),
            .f = quorum.byzantineThreshold(),
            .latency_lambda = 1.0 / 0.5,
        };
        return self_ptr;
    }

    pub fn deinit(self: *Self) void {
        var it = self.dag.iterator();
        while (it.next()) |entry| {
            var block_it = entry.value_ptr.iterator();
            while (block_it.next()) |block_entry| {
                block_entry.value_ptr.deinit(self.allocator);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.dag.deinit(self.allocator);
        self.committed_rounds.deinit(self.allocator);
    }

    pub fn addBlock(self: *Self, block: Block) !void {
        if (!self.dag.contains(block.round)) {
            try self.dag.put(self.allocator, block.round, std.AutoArrayHashMapUnmanaged([32]u8, Block).empty);
        }
        try self.dag.getPtr(block.round).?.put(self.allocator, block.author, block);
    }

    pub fn proposeBlock(self: *Self, author: [32]u8, payload: []const u8) !Block {
        const refs = try self.getReferences();
        defer self.allocator.free(refs);

        const block = try Block.create(
            author,
            self.current_round,
            payload,
            refs,
            self.allocator,
        );

        try self.addBlock(block);
        return block;
    }

    pub fn createVote(_self: *Self, voter: [32]u8, private_key: [32]u8, stake: u128, block: *Block) !Vote {
        _ = _self;
        var message: [40]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], block.round.value, .big);
        @memcpy(message[8..40], &block.digest);
        const signature = try Signature.sign(private_key, &message);

        return Vote{
            .voter = voter,
            .stake = stake,
            .round = block.round,
            .block_digest = block.digest,
            .signature = signature,
        };
    }

    pub fn receiveVote(self: *Self, vote: Vote) !void {
        if (self.dag.getPtr(vote.round)) |round_blocks| {
            if (round_blocks.getPtr(vote.block_digest[0..32].*)) |blk| {
                try blk.votes.put(self.allocator, vote.voter, vote);
            }
        }
    }

    pub fn processVote(self: *Self, vote: Vote) !void {
        if (self.dag.getPtr(vote.round)) |round_blocks| {
            if (round_blocks.getPtr(vote.block_digest[0..32].*)) |blk| {
                try blk.votes.put(self.allocator, vote.voter, vote);
            }
        }
    }

    pub fn onEpochChange(self: *Self, new_total_stake: u128, new_validator_count: usize) void {
        self.total_stake = new_total_stake;
        self.f = if (new_validator_count >= 3) (new_validator_count - 1) / 3 else 0;
    }

    pub fn tryCommit(self: *Self, round: Round, block_digest: [32]u8) !?CommitCertificate {
        const next_round = Round{ .value = round.value + 1 };

        if (self.dag.get(next_round)) |blocks| {
            var it = blocks.iterator();
            while (it.next()) |entry| {
                const block = entry.value_ptr;
                const stake = self.computeStake(&block.votes);
                const threshold = (self.total_stake * 2) / 3 + 1;

                if (stake >= threshold) {
                    const committed_round = Round{ .value = round.value - 2 };

                    if (self.dag.get(committed_round)) |committed_blocks| {
                        if (committed_blocks.get(block_digest[0..32].*)) |_| {
                            const confidence = 1.0 - std.math.exp(-self.latency_lambda * 3.0);
                            return CommitCertificate{
                                .block_digest = block_digest,
                                .round = committed_round,
                                .quorum_stake = stake,
                                .confidence = confidence,
                            };
                        }
                    }
                }
            }
        }

        return null;
    }

    fn computeStake(votes: *const std.AutoArrayHashMapUnmanaged([32]u8, Vote)) u128 {
        var total: u128 = 0;
        var it = votes.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.stake;
        }
        return total;
    }

    pub fn advanceRound(self: *Self) void {
        self.current_round.value += 1;
    }

    pub fn highestCommittedRound(self: Self) ?Round {
        var highest: ?Round = null;
        var it = self.committed_rounds.iterator();
        while (it.next()) |entry| {
            if (highest) |h| {
                if (entry.key.value > h.value) highest = entry.key;
            } else {
                highest = entry.key;
            }
        }
        return highest;
    }

    pub fn getReferences(self: Self) ![]const Round {
        var refs = try std.ArrayList(Round).initCapacity(self.allocator, 2);

        if (self.current_round.value >= 2) {
            try refs.append(.{ .value = self.current_round.value - 2 });
        }
        if (self.current_round.value >= 1) {
            try refs.append(.{ .value = self.current_round.value - 1 });
        }

        return try refs.toOwnedSlice(self.allocator);
    }
};

test "Mysticeti block creation" {
    const allocator = std.testing.allocator;
    var quorum = try Quorum.Quorum.init(allocator);
    defer quorum.deinit();

    for (0..4) |i| {
        try quorum.addValidator([_]u8{@intCast(i + 1)} ** 32, 1000);
    }

    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();

    const parents = &[_]Round{ .{ .value = 0 }, .{ .value = 1 } };
    var block = try Block.create(
        [_]u8{1} ** 32,
        .{ .value = 2 },
        "test payload",
        parents,
        allocator,
    );
    defer block.deinit(allocator);

    try consensus.addBlock(block);
    try std.testing.expect(consensus.dag.contains(.{ .value = 2 }));
}

test "Mysticeti quorum commit" {
    const allocator = std.testing.allocator;
    var quorum = try Quorum.Quorum.init(allocator);
    defer quorum.deinit();

    for (0..4) |i| {
        try quorum.addValidator([_]u8{@intCast(i + 1)} ** 32, 1000);
    }

    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();

    try std.testing.expect(consensus.f == 1);
    try std.testing.expect(consensus.total_stake == 4000);
}

comptime {
    if (!@hasDecl(Mysticeti, "tryCommit")) @compileError("Mysticeti must have tryCommit method");
    if (!@hasDecl(Mysticeti, "addBlock")) @compileError("Mysticeti must have addBlock method");
}
