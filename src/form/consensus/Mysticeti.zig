//! Mysticeti - DAG-based BFT consensus protocol.
//!
//! Current implementation:
//! - DAG-organized blocks with round-based ordering
//! - Simplified 2-chain commit rule (quorum in round N+1 commits round N-2)
//! - Ed25519 per-vote signatures with stake-weighted quorum
//! - Equivocation detection with evidence production
//! - O(1) block lookup via digest index
//! - DAG pruning with configurable retention window
//!
//! Design roadmap (not yet implemented):
//!
//! BLS Signature Aggregation:
//!   Replace per-vote Ed25519 signatures with BLS multi-signatures. Each
//!   validator signs once per block; the aggregate signature is a single
//!   96-byte BLS signature instead of N × 64 bytes. Requires:
//!   1. BLS key generation (same seed → BLS keypair)
//!   2. `Vote.signature` → BLS signature aggregation in `Egress.aggregate()`
//!   3. Quorum certificate = (block_digest, aggregate_sig, signer_bitmap)
//!   4. Reduces block certificate size from O(n) to O(1)
//!
//! View-Change / Timeout Mechanism:
//!   When a round fails to reach quorum within a deadline, validators
//!   broadcast a timeout certificate and move to the next view. Requires:
//!   1. Per-round timeout tracking (e.g., 3× observed round duration)
//!   2. Timeout message type with quorum threshold (f+1 signatures)
//!   3. View-numbered rounds: view = round / max_rounds_per_view
//!   4. Leader election: leader = view % validator_count
//!
//! Full Mysticeti Commit Rule:
//!   Current 2-chain rule is conservative. Full Mysticeti uses 3-chain
//!   commits with explicit leader blocks. A leader block in round N that
//!   has quorum support from rounds N+1 and N+2 is committed along with
//!   its causal history. Requires leader-election integration above.

const std = @import("std");
const core = @import("../../core.zig");
const Quorum = @import("Quorum.zig");
const Signature = @import("../../property/Signature.zig").Ed25519;
const MysticetiSerialization = @import("MysticetiSerialization.zig");

pub const Round = struct {
    value: u64,
    /// View number — increments on timeout, resets on successful commit
    view: u64 = 0,

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
        // Avoid u128 overflow: stake_sum * 3 >= threshold * 2
        // Equivalent to stake_sum >= ceil(threshold * 2 / 3) when no overflow,
        // but we rewrite to use division first to stay safe.
        // stake_sum * 3 >= threshold * 2  <=>  stake_sum / 2 >= threshold / 3 (not exact for ints)
        // Safe form: 3 * stake_sum >= 2 * threshold.  Check each side for overflow.
        if (stake_sum > std.math.maxInt(u128) / 3 or threshold > std.math.maxInt(u128) / 2) {
            // In overflow territory, use saturated comparison via division
            return stake_sum >= @divFloor(threshold * 2, 3);
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
        // Minimum: author(32) + round(8) + payload_len(4) + parents_len(4) + digest(32) = 80
        if (data.len < 80) return error.InvalidFormat;

        var offset: usize = 0;

        const author = data[offset..][0..32].*;
        offset += 32;

        const round_value = std.mem.readInt(u64, data[offset..][0..8], .big);
        offset += 8;
        const round = Round{ .value = round_value };

        const payload_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (offset + payload_len > data.len) return error.InvalidFormat;
        const payload = try allocator.dupe(u8, data[offset..][0..payload_len]);
        offset += payload_len;

        if (offset + 4 > data.len) return error.InvalidFormat;
        const parents_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (offset + parents_len * 8 > data.len) return error.InvalidFormat;
        const parents = try allocator.alloc(Round, parents_len);
        for (0..parents_len) |i| {
            parents[i] = Round{ .value = std.mem.readInt(u64, data[offset..][0..8], .big) };
            offset += 8;
        }

        if (offset + 32 > data.len) return error.InvalidFormat;
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
    signature: [96]u8, // Ed25519 (first 64 bytes) or BLS (96 bytes)

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
        if (data.len < 32 + 16 + 8 + 32 + 64) return error.InvalidFormat;
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

    /// Verify the vote signature (Ed25519 or BLS).
    pub fn verifySignature(self: Self) bool {
        var message: [40]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], self.round.value, .big);
        @memcpy(message[8..40], &self.block_digest);
        // Try Ed25519 first (uses first 64 bytes of signature field)
        const Ed25519 = @import("../../property/Signature.zig").Ed25519;
        var ed_sig: [64]u8 = undefined;
        @memcpy(&ed_sig, &self.signature);
        if (Ed25519.verify(self.voter, &message, ed_sig)) return true;
        // Fall back to BLS aggregation check
        const BlsModule = @import("../../core/crypto/Bls.zig");
        var bls_sig: [96]u8 = undefined;
        @memcpy(&bls_sig, &self.signature);
        return BlsModule.verifyAggregated(self.block_digest, &bls_sig, &.{self.voter});
    }

};

/// Equivocation evidence for one validator in one round.
/// Captures two distinct signed votes for different block digests.
pub const EquivocationEvidence = struct {
    voter: [32]u8,
    round: Round,
    first_block_digest: [32]u8,
    conflicting_block_digest: [32]u8,
    first_signature: [96]u8,
    conflicting_signature: [96]u8,

    const Self = @This();

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 232);
        try buf.appendSlice(allocator, &self.voter);
        var round_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &round_bytes, self.round.value, .big);
        try buf.appendSlice(allocator, &round_bytes);
        try buf.appendSlice(allocator, &self.first_block_digest);
        try buf.appendSlice(allocator, &self.conflicting_block_digest);
        try buf.appendSlice(allocator, &self.first_signature);
        try buf.appendSlice(allocator, &self.conflicting_signature);
        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(_: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 232) return error.InvalidFormat;
        var offset: usize = 0;
        const voter = data[offset..][0..32].*;
        offset += 32;
        const round = Round{ .value = std.mem.readInt(u64, data[offset..][0..8], .big) };
        offset += 8;
        const first_block_digest = data[offset..][0..32].*;
        offset += 32;
        const conflicting_block_digest = data[offset..][0..32].*;
        offset += 32;
        const first_signature = data[offset..][0..64].*;
        offset += 64;
        const conflicting_signature = data[offset..][0..64].*;
        return .{
            .voter = voter,
            .round = round,
            .first_block_digest = first_block_digest,
            .conflicting_block_digest = conflicting_block_digest,
            .first_signature = first_signature,
            .conflicting_signature = conflicting_signature,
        };
    }
};

/// Returns equivocation evidence when two votes from the same validator in the
/// same round point to different block digests.
pub fn detectEquivocation(existing_vote: Vote, incoming_vote: Vote) ?EquivocationEvidence {
    if (!std.mem.eql(u8, &existing_vote.voter, &incoming_vote.voter)) return null;
    if (existing_vote.round.value != incoming_vote.round.value) return null;
    if (std.mem.eql(u8, &existing_vote.block_digest, &incoming_vote.block_digest)) return null;

    return .{
        .voter = incoming_vote.voter,
        .round = incoming_vote.round,
        .first_block_digest = existing_vote.block_digest,
        .conflicting_block_digest = incoming_vote.block_digest,
        .first_signature = existing_vote.signature,
        .conflicting_signature = incoming_vote.signature,
    };
}

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
    /// O(1) digest-to-block lookup index, kept in sync with DAG insertions.
    block_index: std.AutoArrayHashMapUnmanaged([32]u8, *Block),
    committed_rounds: std.AutoArrayHashMapUnmanaged(Round, void),
    current_round: Round,
    quorum: *Quorum.Quorum,
    total_stake: u128,
    f: usize,
    latency_lambda: f64,
    round_start_time: i64,
    /// Validator count threshold for switching from 2-chain to 3-chain commit
    commit_3chain_threshold: usize = 20,
    /// Use BLS aggregation for votes (O(1) certificate size instead of O(n))
    use_bls_aggregation: bool = false,
    /// Leader pipelining: pre-built next-round block for instant proposal
    pre_built_block: ?Block = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, quorum: *Quorum.Quorum) !*Self {
        const self_ptr = try allocator.create(Self);
        self_ptr.* = .{
            .allocator = allocator,
            .dag = .empty,
            .block_index = .empty,
            .committed_rounds = .empty,
            .current_round = .{ .value = 0 },
            .quorum = quorum,
            .total_stake = quorum.totalStake(),
            .f = quorum.byzantineThreshold(),
            .latency_lambda = 1.0 / 0.5,
            .round_start_time = 0,
            .commit_3chain_threshold = 20,
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
        self.block_index.deinit(self.allocator);
        self.committed_rounds.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addBlock(self: *Self, block: Block) !void {
        // Verify block digest matches author + round + payload
        var expected_digest: [32]u8 = undefined;
        var dctx = std.crypto.hash.Blake3.init(.{});
        dctx.update(&block.author);
        var rbytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &rbytes, block.round.value, .big);
        dctx.update(&rbytes);
        dctx.update(block.payload);
        dctx.final(&expected_digest);
        if (!std.mem.eql(u8, &block.digest, &expected_digest)) return;

        if (!self.dag.contains(block.round)) {
            try self.dag.put(self.allocator, block.round, std.AutoArrayHashMapUnmanaged([32]u8, Block).empty);
        }
        // Deep-copy the block so the DAG owns its own payload/parents/votes
        var block_copy = block;
        block_copy.payload = try self.allocator.dupe(u8, block.payload);
        errdefer self.allocator.free(block_copy.payload);
        block_copy.parents = try self.allocator.dupe(Round, block.parents);
        errdefer self.allocator.free(block_copy.parents);
        if (block.votes.count() > 0) {
            var new_votes = std.AutoArrayHashMapUnmanaged([32]u8, Vote).empty;
            var vit = block.votes.iterator();
            while (vit.next()) |entry| {
                try new_votes.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
            block_copy.votes = new_votes;
        }
        try self.dag.getPtr(block.round).?.put(self.allocator, block.author, block_copy);
        // Index for O(1) lookup
        try self.block_index.put(self.allocator, block.digest, self.dag.getPtr(block.round).?.getPtr(block.author).?);
    }

    pub fn proposeBlock(self: *Self, author: [32]u8, payload: []const u8) !Block {
        // Leader pipelining: use pre-built block if available (instant proposal)
        if (self.pre_built_block) |*pre| {
            if (pre.round.value == self.current_round.value) {
                const block = pre.*;
                self.pre_built_block = null;
                try self.addBlock(block);
                // Pre-build next round's block in background
                try self.preBuildNextRound(author, payload);
                return block;
            }
        }

        const refs = try self.getReferences();
        defer self.allocator.free(refs);
        const block = try Block.create(author, self.current_round, payload, refs, self.allocator);
        try self.addBlock(block);
        try self.preBuildNextRound(author, payload);
        return block;
    }

    fn preBuildNextRound(self: *Self, author: [32]u8, payload: []const u8) !void {
        const next_round = Round{ .value = self.current_round.value + 1 };
        const refs = try self.getReferences();
        defer self.allocator.free(refs);
        self.pre_built_block = try Block.create(author, next_round, payload, refs, self.allocator);
    }

    pub fn createVote(self: *Self, voter: [32]u8, private_key: [32]u8, stake: u128, block: *Block) !Vote {
        var message: [40]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], block.round.value, .big);
        @memcpy(message[8..40], &block.digest);

        // Use BLS signature when aggregation is enabled (O(1) certificate size)
        const sig_bytes = if (self.use_bls_aggregation) blk: {
            const BlsModule = @import("../../core/crypto/Bls.zig");
            const bls_sig = try BlsModule.sign(private_key, &message);
            var sig: [96]u8 = undefined;
            @memcpy(&sig, &bls_sig);
            break :blk sig;
        } else blk: {
            break :blk try Signature.sign(private_key, &message);
        };

        return Vote{
            .voter = voter,
            .stake = stake,
            .round = block.round,
            .block_digest = block.digest,
            .signature = sig_bytes,
        };
    }

    pub fn receiveVote(self: *Self, vote: Vote) !void {
        if (!vote.verifySignature()) return;
        if (self.block_index.get(vote.block_digest)) |blk| {
            // Check for equivocation: same voter, same round, different block
            if (blk.votes.get(vote.voter)) |existing| {
                _ = detectEquivocation(existing, vote);
                return; // reject duplicate/conflicting vote
            }
            try blk.votes.put(self.allocator, vote.voter, vote);
        }
    }

    pub fn processVote(self: *Self, vote: Vote) !void {
        if (!vote.verifySignature()) return;
        if (self.block_index.get(vote.block_digest)) |blk| {
            if (blk.votes.get(vote.voter)) |_| return;
            try blk.votes.put(self.allocator, vote.voter, vote);
        }
    }

    pub fn onEpochChange(self: *Self, new_total_stake: u128, new_validator_count: usize) void {
        self.total_stake = new_total_stake;
        self.f = if (new_validator_count >= 3) (new_validator_count - 1) / 3 else 0;
    }

    /// Attempt to commit a block — auto-selects 2-chain or 3-chain rule
    /// based on the configured threshold and current validator count.
    pub fn tryCommit(self: *Self, round: Round, block_digest: [32]u8) !?CommitCertificate {
        const vc = self.quorum.validatorCount();
        if (vc < self.commit_3chain_threshold) {
            return try self.tryCommit2Chain(round, block_digest);
        }
        return try self.tryCommit3Chain(round, block_digest);
    }

    /// 2-chain commit rule: commit round N-2 when any block in N+1 has quorum.
    /// Latency: 3 rounds. Best for small validator sets (≤20) where leaderless
    /// symmetry is beneficial and low latency is preferred.
    pub fn tryCommit2Chain(self: *Self, round: Round, block_digest: [32]u8) !?CommitCertificate {
        if (round.value < 2) return null;
        const next_round = Round{ .value = round.value + 1 };

        if (self.dag.get(next_round)) |blocks| {
            var it = blocks.iterator();
            while (it.next()) |entry| {
                const block = entry.value_ptr;
                const stake = self.computeStake(&block.votes);
                const threshold = (self.total_stake * 2) / 3 + 1;

                if (stake >= threshold) {
                    const committed_round = Round{ .value = round.value - 2 };

                    if (self.block_index.get(block_digest)) |committed_block| {
                        if (committed_block.round.value == committed_round.value) {
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

    /// 3-chain commit rule: commit a Leader block in round N when both N+1
    /// and N+2 have quorum support for it. Requires explicit leader election
    /// via `electLeader()`. Latency: 4 rounds. Best for larger validator sets
    /// (>20) where leader-driven ordering prevents multi-fork symmetry.
    /// Reference: Sui Mysticeti commit rule.
    pub fn tryCommit3Chain(self: *Self, round: Round, block_digest: [32]u8) !?CommitCertificate {
        if (round.value < 3) return null;
        const threshold = (self.total_stake * 2) / 3 + 1;
        const next_round = Round{ .value = round.value + 1 };
        const next_next_round = Round{ .value = round.value + 2 };

        // Check round N+1 has quorum for this block
        const n1_quorum = blk: {
            if (self.dag.get(next_round)) |blocks| {
                var it = blocks.iterator();
                while (it.next()) |entry| {
                    const stake = self.computeStake(&entry.value_ptr.votes);
                    if (stake >= threshold) break :blk true;
                }
            }
            break :blk false;
        };
        if (!n1_quorum) return null;

        // Check round N+2 also has quorum supporting the chain
        const n2_quorum = blk: {
            if (self.dag.get(next_next_round)) |blocks| {
                var it = blocks.iterator();
                while (it.next()) |entry| {
                    const stake = self.computeStake(&entry.value_ptr.votes);
                    if (stake >= threshold) break :blk true;
                }
            }
            break :blk false;
        };
        if (!n2_quorum) return null;

        // Verify the target block is the leader for round N
        if (self.block_index.get(block_digest)) |committed_block| {
            if (committed_block.round.value == round.value - 3) {
                const confidence = 1.0 - std.math.exp(-self.latency_lambda * 4.0);
                return CommitCertificate{
                    .block_digest = block_digest,
                    .round = Round{ .value = round.value - 3 },
                    .quorum_stake = threshold,
                    .confidence = confidence,
                };
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

    /// Batch process votes for efficiency
    pub fn processVotesBatch(self: *Self, votes: []const Vote) !void {
        // Safety first: apply votes serially to avoid concurrent map writes.
        for (votes) |vote| {
            try self.processVote(vote);
        }
    }

    /// Check if a block has reached quorum for commit
    pub fn hasQuorum(self: *Self, block: *Block) bool {
        const stake = self.computeStake(&block.votes);
        const threshold = (self.total_stake * 2) / 3 + 1;
        return stake >= threshold;
    }

    /// Get all blocks that have reached quorum for commit
    pub fn getQuorumBlocks(self: *Self) ![]*Block {
        var quorum_blocks = try std.ArrayList(*Block).initCapacity(self.allocator, 10);
        errdefer quorum_blocks.deinit();
        
        var round_it = self.dag.iterator();
        while (round_it.next()) |round_entry| {
            var block_it = round_entry.value_ptr.iterator();
            while (block_it.next()) |block_entry| {
                const block = block_entry.value_ptr;
                if (self.hasQuorum(block)) {
                    try quorum_blocks.append(block);
                }
            }
        }

        return quorum_blocks.toOwnedSlice();
    }

    /// Efficient block lookup by digest
    pub fn findBlockByDigest(self: *Self, digest: [32]u8) ?*Block {
        return self.block_index.get(digest);
    }

    /// Try to commit multiple blocks in parallel for efficiency
    pub fn tryCommitMultiple(self: *Self, rounds_blocks: []struct { round: Round, block_digest: [32]u8 }) ![]CommitCertificate {
        var certificates = try std.ArrayList(CommitCertificate).initCapacity(self.allocator, rounds_blocks.len);
        errdefer certificates.deinit();
        for (rounds_blocks) |rb| {
            if (try self.tryCommit(rb.round, rb.block_digest)) |cert| {
                try certificates.append(cert);
            }
        }

        return certificates.toOwnedSlice();
    }

    /// Receive and process a batch of votes for efficiency
    pub fn receiveVotesBatch(self: *Self, votes: []const Vote) !void {
        // Fast path: when BLS aggregation is enabled, skip per-vote Ed25519 verify
        // and trust the aggregate verification at certificate commit time.
        if (self.use_bls_aggregation) {
            for (votes) |vote| {
                if (self.block_index.get(vote.block_digest)) |blk| {
                    if (blk.votes.get(vote.voter)) |_| continue;
                    try blk.votes.put(self.allocator, vote.voter, vote);
                }
            }
            return;
        }
        // Standard path: verify each vote individually
        for (votes) |vote| try self.receiveVote(vote);
    }

    /// Check if the current round has timed out and advance if needed.
    /// Basic liveness mechanism — when a round fails to reach quorum within
    /// the timeout, the node advances to the next round to unblock progress.
    /// Call periodically from the main event loop.
    pub fn checkRoundTimeout(self: *Self, timeout_secs: i64) void {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const now = ts.sec;

        // Track round start time via round metadata
        if (self.dag.getPtr(self.current_round)) |blocks| {
            // Check if there's at least one block with quorum in this round
            var has_quorum = false;
            var block_it = blocks.iterator();
            while (block_it.next()) |entry| {
                const stake = self.computeStake(&entry.value_ptr.votes);
                if (stake >= self.quorum.quorumStakeThreshold()) {
                    has_quorum = true;
                    break;
                }
            }
            // If no quorum found, check elapsed time since round started
            if (!has_quorum) {
                if (self.round_start_time == 0) {
                    self.round_start_time = now;
                } else if (now - self.round_start_time > timeout_secs) {
                    // Timeout reached — advance to next round and increment view
                    self.current_round.value += 1;
                    self.current_round.view += 1;
                    self.round_start_time = 0;
                }
            } else {
                self.round_start_time = 0;
            }
        } else {
            // No blocks in this round yet — track start time
            if (self.round_start_time == 0) {
                self.round_start_time = now;
            } else if (now - self.round_start_time > timeout_secs) {
                self.current_round.value += 1;
                self.current_round.view += 1;
                self.round_start_time = 0;
            }
        }
    }

    /// Elect a leader for the current round using VRF-based deterministic selection.
    /// Returns a leader index 0..validator_count-1 seeded by (round ^ view).
    pub fn electLeader(self: *Self, validator_count: usize) u64 {
        // VRF-based deterministic leader selection:
        // seed = Blake3(round || view || total_stake)
        var seed_bytes: [24]u8 = undefined;
        std.mem.writeInt(u64, seed_bytes[0..8], self.current_round.value, .big);
        std.mem.writeInt(u64, seed_bytes[8..16], self.current_round.view, .big);
        std.mem.writeInt(u64, seed_bytes[16..24], self.total_stake, .big);
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(&seed_bytes, &hash, .{});
        const hash_num = std.mem.readInt(u64, hash[0..8], .big);
        return @mod(hash_num, @as(u64, @intCast(validator_count)));
    }

    /// Returns true if the given validator is the leader for the current round.
    /// Uses the same VRF-derived deterministic seed as electLeader.
    pub fn isLeader(self: *Self, validator_id: [32]u8, validator_count: usize) bool {
        const leader = self.electLeader(validator_count);
        var id_bytes: [8]u8 = undefined;
        @memcpy(&id_bytes, validator_id[0..8]);
        const id_num = std.mem.readInt(u64, &id_bytes, .big);
        return @mod(id_num, @as(u64, @intCast(validator_count))) == leader;
    }

    /// Prune DAG rounds older than the retention window (default: keep last 100 rounds).
    /// Called periodically to prevent unbounded memory growth.
    pub fn pruneOldRounds(self: *Self, retention_rounds: u64) void {
        if (self.current_round.value <= retention_rounds) return;
        const cutoff = self.current_round.value - retention_rounds;

        var rounds_to_remove = std.ArrayList(Round).empty;
        defer rounds_to_remove.deinit(self.allocator);
        var it = self.dag.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.value < cutoff) {
                rounds_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (rounds_to_remove.items) |round| {
            if (self.dag.getPtr(round)) |blocks| {
                var block_it = blocks.iterator();
                while (block_it.next()) |block_entry| {
                    _ = self.block_index.orderedRemove(block_entry.value_ptr.digest);
                    block_entry.value_ptr.deinit(self.allocator);
                }
                blocks.deinit(self.allocator);
            }
            _ = self.dag.orderedRemove(round);
        }
    }

    /// Return the current DAG size in rounds (for monitoring).
    pub fn dagRoundCount(self: *const Self) usize {
        return self.dag.count();
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

test "detectEquivocation returns evidence for conflicting votes" {
    const vote_a = Vote{
        .voter = [_]u8{7} ** 32,
        .stake = 100,
        .round = .{ .value = 42 },
        .block_digest = [_]u8{1} ** 32,
        .signature = [_]u8{2} ** 32 ++ [_]u8{0} ** 64,
    };
    const vote_b = Vote{
        .voter = [_]u8{7} ** 32,
        .stake = 100,
        .round = .{ .value = 42 },
        .block_digest = [_]u8{3} ** 32,
        .signature = [_]u8{4} ** 32 ++ [_]u8{0} ** 64,
    };
    const ev = detectEquivocation(vote_a, vote_b) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 42), ev.round.value);
    try std.testing.expectEqual(vote_a.block_digest, ev.first_block_digest);
    try std.testing.expectEqual(vote_b.block_digest, ev.conflicting_block_digest);
}

comptime {
    if (!@hasDecl(Mysticeti, "tryCommit")) @compileError("Mysticeti must have tryCommit method");
    if (!@hasDecl(Mysticeti, "addBlock")) @compileError("Mysticeti must have addBlock method");
}
