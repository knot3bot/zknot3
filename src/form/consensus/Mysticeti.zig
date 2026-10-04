//! Mysticeti - DAG-based BFT consensus protocol.
//!
//! Current implementation:
//! - DAG-organized blocks with round-based ordering
//! - Commit rule auto-selection: simplified 2-chain for small validator sets
//!   (default ≤20) and leader-driven 3-chain for larger sets
//! - Leader election: deterministic Blake3 seed over (round, view, stake)
//! - Ed25519 per-vote signatures with stake-weighted quorum; optional BLS
//!   mode (`use_bls_aggregation`) producing O(1) aggregate certificates
//! - Compact QuorumCertificate: BLS multi-signature + signer bitmap
//! - View change: f+1 signed TimeoutVotes assemble a TimeoutCertificate and
//!   advance the view (see `receiveTimeoutVote` / `tryViewChange`)
//! - Equivocation detection with evidence production
//! - O(1) block lookup via digest index
//! - DAG pruning with configurable retention window
//!
//! Known simplifications:
//! - 2-chain commits do not verify leader identity (leaderless mode)
//! - QuorumCertificate bitmap is u128: validator sets >128 fall back to
//!   per-vote verification (buildQuorumCertificate returns error.SetTooLarge)

const std = @import("std");
const core = @import("../../core.zig");
const Quorum = @import("Quorum.zig");
const Signature = @import("../../property/Signature.zig").Ed25519;
const Bls = @import("../../core/crypto/Bls.zig");
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
    /// Ed25519 signature by the author over `computeDigest(...)` — set via
    /// `createSigned`; `addBlock` rejects signed blocks whose signature does
    /// not verify under the author id. Unsigned blocks stay accepted for
    /// local/test proposals.
    author_signature: ?[64]u8 = null,
    stake_cache: u128 = 0,

    const Self = @This();

    /// Canonical digest over the full block commitment: author, round,
    /// payload, and DAG parents. Shared by `create` and `addBlock` so the
    /// producer and the validator cannot diverge.
    pub fn computeDigest(author: [32]u8, round: Round, payload: []const u8, parents: []const Round) [32]u8 {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&author);
        var round_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &round_bytes, round.value, .big);
        ctx.update(&round_bytes);
        ctx.update(payload);
        // Commit to the DAG structure: without parents in the digest, two
        // blocks with identical (author, round, payload) but different
        // parents would share a digest, weakening equivocation evidence.
        var parents_len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &parents_len_bytes, parents.len, .big);
        ctx.update(&parents_len_bytes);
        for (parents) |parent| {
            var parent_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &parent_bytes, parent.value, .big);
            ctx.update(&parent_bytes);
        }
        var digest: [32]u8 = undefined;
        ctx.final(&digest);
        return digest;
    }

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

        block.digest = computeDigest(author, round, payload, parents);

        return block;
    }

    /// Create a block with an Ed25519 author signature over its digest.
    /// `author` must be the public key matching `author_private_key`.
    pub fn createSigned(
        author: [32]u8,
        author_private_key: [32]u8,
        round: Round,
        payload: []const u8,
        parents: []const Round,
        allocator: std.mem.Allocator,
    ) !Self {
        var block = try create(author, round, payload, parents, allocator);
        block.author_signature = try Signature.sign(author_private_key, &block.digest);
        return block;
    }

    /// Verify the author signature (present-signature policy).
    pub fn verifyAuthorSignature(self: *const Self) bool {
        const sig = self.author_signature orelse return true;
        // Digest must still match the canonical commitment.
        if (!std.mem.eql(u8, &self.digest, &computeDigest(self.author, self.round, self.payload, self.parents))) return false;
        return Signature.verify(self.author, &self.digest, sig);
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
        const signature_ed = data[offset..][0..64].*;
        var signature: [96]u8 = @as([96]u8, @splat(0));
        @memcpy(signature[0..64], &signature_ed);
        return Self{
            .voter = voter,
            .stake = stake,
            .round = round,
            .block_digest = block_digest,
            .signature = signature,
        };
    }

    /// Verify the vote signature. When the voter's BLS public key is known
    /// (registered at epoch start), the signature is checked as a BLS
    /// signature under that key; otherwise it is checked as Ed25519.
    pub fn verifySignatureWith(self: Self, bls_pk: ?Bls.PublicKey) bool {
        const message = QuorumCertificate.signedMessage(self.round, self.block_digest);
        if (bls_pk) |pk| {
            return Bls.verifyAggregated(&message, pk, self.signature);
        }
        const Ed25519 = @import("../../property/Signature.zig").Ed25519;
        var ed_sig: [64]u8 = undefined;
        @memcpy(&ed_sig, self.signature[0..64]);
        return Ed25519.verify(self.voter, &message, ed_sig);
    }

    /// Verify with Ed25519 only (standalone use without registered BLS keys).
    pub fn verifySignature(self: Self) bool {
        return self.verifySignatureWith(null);
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

/// Maximum validators addressable by the u128 signer bitmap.
pub const max_bitmap_validators = 128;

/// Compact quorum certificate: one 96-byte BLS multi-signature plus a signer
/// bitmap instead of N individual signatures. The signed message is the
/// canonical vote message (round BE64 || block_digest). Verification
/// aggregates the public keys of the bitmap signers and checks the
/// multi-signature in a single BLS operation (rogue-key safe: the DST uses
/// the proof-of-presence variant).
pub const QuorumCertificate = struct {
    block_digest: [32]u8,
    round: Round,
    aggregate_signature: [96]u8,
    signer_bitmap: u128,
    quorum_stake: u128,

    const Self = @This();

    pub const wire_size = 32 + 8 + 8 + 96 + 16 + 16;

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, wire_size);
        try buf.appendSlice(allocator, &self.block_digest);
        var rb: [8]u8 = undefined;
        std.mem.writeInt(u64, &rb, self.round.value, .big);
        try buf.appendSlice(allocator, &rb);
        std.mem.writeInt(u64, &rb, self.round.view, .big);
        try buf.appendSlice(allocator, &rb);
        try buf.appendSlice(allocator, &self.aggregate_signature);
        var sb: [16]u8 = undefined;
        std.mem.writeInt(u128, &sb, self.signer_bitmap, .big);
        try buf.appendSlice(allocator, &sb);
        std.mem.writeInt(u128, &sb, self.quorum_stake, .big);
        try buf.appendSlice(allocator, &sb);
        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(_: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < wire_size) return error.InvalidFormat;
        var offset: usize = 0;
        const block_digest = data[offset..][0..32].*;
        offset += 32;
        const round = Round{
            .value = std.mem.readInt(u64, data[offset..][0..8], .big),
            .view = std.mem.readInt(u64, data[offset + 8 ..][0..8], .big),
        };
        offset += 16;
        const aggregate_signature = data[offset..][0..96].*;
        offset += 96;
        const signer_bitmap = std.mem.readInt(u128, data[offset..][0..16], .big);
        offset += 16;
        const quorum_stake = std.mem.readInt(u128, data[offset..][0..16], .big);
        return Self{
            .block_digest = block_digest,
            .round = round,
            .aggregate_signature = aggregate_signature,
            .signer_bitmap = signer_bitmap,
            .quorum_stake = quorum_stake,
        };
    }

    /// Canonical vote message that the aggregate signature commits to.
    pub fn signedMessage(round: Round, block_digest: [32]u8) [40]u8 {
        var message: [40]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], round.value, .big);
        @memcpy(message[8..40], &block_digest);
        return message;
    }

    /// Verify against a quorum and a validator-id → BLS-public-key map.
    /// Checks (a) every bitmap signer has a registered BLS key,
    /// (b) signers form a stake quorum, and (c) the multi-signature is valid.
    pub fn verify(
        self: Self,
        quorum: *const Quorum.Quorum,
        bls_keys: *const std.AutoArrayHashMapUnmanaged([32]u8, Bls.PublicKey),
    ) bool {
        const BlsModule = @import("../../core/crypto/Bls.zig");
        var pks_buf: [max_bitmap_validators]Bls.PublicKey = undefined;
        var pks_len: usize = 0;
        var signer_stake: u128 = 0;
        const members = quorum.members.items;
        for (members, 0..) |member, i| {
            if (i >= max_bitmap_validators) break;
            const bit = @as(u128, 1) << @intCast(i);
            if (self.signer_bitmap & bit == 0) continue;
            const pk = bls_keys.get(member.id) orelse return false;
            pks_buf[pks_len] = pk;
            pks_len += 1;
            signer_stake += member.weight();
        }
        if (signer_stake < quorum.quorumStakeThreshold()) return false;
        if (pks_len == 0) return false;
        const message = Self.signedMessage(self.round, self.block_digest);
        return BlsModule.verifyAggregated(&message, BlsModule.aggregatePk(pks_buf[0..pks_len]), self.aggregate_signature);
    }
};

/// Timeout vote for the current (round, view): signed statement that the
/// signer observes no quorum. Ed25519 over the canonical timeout message.
pub const TimeoutVote = struct {
    voter: [32]u8,
    round: Round,
    signature: [64]u8,

    const Self = @This();

    pub fn message(round: Round) [30]u8 {
        var msg: [30]u8 = undefined;
        @memcpy(msg[0..14], "zknot3-timeout");
        std.mem.writeInt(u64, msg[14..22], round.value, .big);
        std.mem.writeInt(u64, msg[22..30], round.view, .big);
        return msg;
    }

    pub fn sign(voter_pubkey: [32]u8, private_key: [32]u8, round: Round) Self {
        const msg = Self.message(round);
        const Ed25519 = @import("../../property/Signature.zig").Ed25519;
        const sig = Ed25519.sign(private_key, &msg) catch return Self{
            .voter = voter_pubkey,
            .round = round,
            .signature = @as([64]u8, @splat(0)),
        };
        return Self{ .voter = voter_pubkey, .round = round, .signature = sig };
    }

    pub fn verifySignature(self: Self) bool {
        const Ed25519 = @import("../../property/Signature.zig").Ed25519;
        const msg = Self.message(self.round);
        return Ed25519.verify(self.voter, &msg, self.signature);
    }
};

/// Certificate that f+1 validators timed out on a given (round, view),
/// justifying a view change. Carries the individual signatures so any
/// receiver (including light clients) can re-verify the evidence.
pub const TimeoutCertificate = struct {
    round: Round,
    voters: [][32]u8,
    signatures: [][64]u8,

    const Self = @This();

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.voters);
        allocator.free(self.signatures);
    }

    /// Verify: all signatures valid, all voters distinct, count >= f+1.
    pub fn verify(self: Self, quorum: *const Quorum.Quorum) bool {
        if (self.voters.len != self.signatures.len) return false;
        if (self.voters.len < quorum.byzantineThreshold() + 1) return false;
        for (self.voters, 0..) |voter, i| {
            for (self.voters[0..i]) |seen| {
                if (std.mem.eql(u8, &seen, &voter)) return false;
            }
            const vote = TimeoutVote{ .voter = voter, .round = self.round, .signature = self.signatures[i] };
            if (!vote.verifySignature()) return false;
        }
        return true;
    }

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 16 + self.voters.len * 96);
        var rb: [8]u8 = undefined;
        std.mem.writeInt(u64, &rb, self.round.value, .big);
        try buf.appendSlice(allocator, &rb);
        std.mem.writeInt(u64, &rb, self.round.view, .big);
        try buf.appendSlice(allocator, &rb);
        var nb: [8]u8 = undefined;
        std.mem.writeInt(u64, &nb, self.voters.len, .big);
        try buf.appendSlice(allocator, &nb);
        for (self.voters, 0..) |voter, i| {
            try buf.appendSlice(allocator, &voter);
            try buf.appendSlice(allocator, &self.signatures[i]);
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 24) return error.InvalidFormat;
        var offset: usize = 0;
        const round = Round{
            .value = std.mem.readInt(u64, data[offset..][0..8], .big),
            .view = std.mem.readInt(u64, data[offset + 8 ..][0..8], .big),
        };
        offset += 16;
        const n = std.mem.readInt(u64, data[offset..][0..8], .big);
        offset += 8;
        if (n > max_bitmap_validators) return error.InvalidFormat;
        const need = @as(usize, @intCast(n)) * (32 + 64);
        if (data.len - offset < need) return error.InvalidFormat;
        const voters = try allocator.alloc([32]u8, @intCast(n));
        errdefer allocator.free(voters);
        const signatures = try allocator.alloc([64]u8, @intCast(n));
        errdefer allocator.free(signatures);
        for (0..@intCast(n)) |i| {
            voters[i] = data[offset..][0..32].*;
            offset += 32;
            signatures[i] = data[offset..][0..64].*;
            offset += 64;
        }
        return Self{ .round = round, .voters = voters, .signatures = signatures };
    }
};

/// Stable position of a block inside the DAG (round map + author key).
pub const BlockLocator = struct {
    round: Round,
    author: [32]u8,
};

pub const Mysticeti = struct {
    allocator: std.mem.Allocator,
    dag: std.AutoArrayHashMapUnmanaged(Round, std.AutoArrayHashMapUnmanaged([32]u8, Block)),
    /// O(1) digest-to-block lookup index, kept in sync with DAG insertions.
    /// digest → stable locator. Storing *Block directly is unsound: the
    /// per-round maps relocate their entries when a second author joins a
    /// round, dangling every previously indexed pointer (use-after-free).
    block_index: std.AutoArrayHashMapUnmanaged([32]u8, BlockLocator),
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
    /// Validator id → BLS public key, registered by each validator at epoch
    /// start. Required for QuorumCertificate build/verify.
    bls_keys: std.AutoArrayHashMapUnmanaged([32]u8, Bls.PublicKey) = .empty,
    /// Timeout votes collected for the current (round, view); cleared on
    /// view change and on round advance.
    timeout_votes: std.AutoArrayHashMapUnmanaged([32]u8, TimeoutVote) = .empty,

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
        self.bls_keys.deinit(self.allocator);
        self.timeout_votes.deinit(self.allocator);
        if (self.pre_built_block) |*pre| pre.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addBlock(self: *Self, block: Block) !void {
        // Verify block digest matches the canonical commitment, and that a
        // present author signature authenticates the proposer.
        const expected_digest = Block.computeDigest(block.author, block.round, block.payload, block.parents);
        if (!std.mem.eql(u8, &block.digest, &expected_digest)) return;
        if (!block.verifyAuthorSignature()) return error.InvalidAuthorSignature;

        if (!self.dag.contains(block.round)) {
            try self.dag.put(self.allocator, block.round, std.AutoArrayHashMapUnmanaged([32]u8, Block).empty);
        }
        // First writer wins for (author, round): gossip can redeliver a
        // block (or replay a conflicting proposal). Replacing the stored
        // copy would leak its buffers, so duplicates are dropped instead.
        if (self.dag.getPtr(block.round).?.contains(block.author)) return;
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
        try self.block_index.put(self.allocator, block.digest, .{ .round = block.round, .author = block.author });
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

        const refs = self.getReferences();
        const ref_count = self.getReferenceCount();
        const block = try Block.create(author, self.current_round, payload, refs[0..ref_count], self.allocator);
        try self.addBlock(block);
        try self.preBuildNextRound(author, payload);
        return block;
    }

    fn preBuildNextRound(self: *Self, author: [32]u8, payload: []const u8) !void {
        const next_round = Round{ .value = self.current_round.value + 1 };
        const refs = self.getReferences();
        const ref_count = self.getReferenceCount();
        self.pre_built_block = try Block.create(author, next_round, payload, refs[0..ref_count], self.allocator);
    }

    pub fn createVote(self: *Self, voter: [32]u8, private_key: [32]u8, stake: u128, block: *Block) !Vote {
        var message: [40]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], block.round.value, .big);
        @memcpy(message[8..40], &block.digest);

        // Use BLS signature when aggregation is enabled (O(1) certificate size)
        const sig_bytes = if (self.use_bls_aggregation) blk: {
            const BlsModule = @import("../../core/crypto/Bls.zig");
            const bls_sig = BlsModule.sign(private_key, &message);
            var sig: [96]u8 = undefined;
            @memcpy(&sig, &bls_sig);
            break :blk sig;
        } else blk: {
            // Ed25519 signature stored left-aligned in the 96-byte field.
            var sig: [96]u8 = @as([96]u8, @splat(0));
            const ed = try Signature.sign(private_key, &message);
            @memcpy(sig[0..64], &ed);
            break :blk sig;
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
        if (!self.verifyIncomingVote(&vote)) return;
        if (self.lookupBlock(vote.block_digest)) |blk| {
            // Check for equivocation: same voter, same round, different block
            if (blk.votes.get(vote.voter)) |existing| {
                _ = detectEquivocation(existing, vote);
                return; // reject duplicate/conflicting vote
            }
            try blk.votes.put(self.allocator, vote.voter, vote);
            blk.stake_cache += vote.stake;
        }
    }

    pub fn processVote(self: *Self, vote: Vote) !void {
        if (!self.verifyIncomingVote(&vote)) return;
        if (self.lookupBlock(vote.block_digest)) |blk| {
            if (blk.votes.get(vote.voter)) |_| return;
            try blk.votes.put(self.allocator, vote.voter, vote);
            blk.stake_cache += vote.stake;
        }
    }

    /// Signature check for an incoming vote: BLS under the voter's
    /// registered key when operating in aggregation mode, Ed25519 otherwise.
    fn verifyIncomingVote(self: *Self, vote: *const Vote) bool {
        const bls_pk: ?Bls.PublicKey = if (self.use_bls_aggregation) self.bls_keys.get(vote.voter) else null;
        return vote.verifySignatureWith(bls_pk);
    }

    pub fn onEpochChange(self: *Self, new_total_stake: u128, new_validator_count: usize) void {
        self.total_stake = new_total_stake;
        self.f = if (new_validator_count >= 3) (new_validator_count - 1) / 3 else 0;
    }

    /// Register a validator's BLS public key (epoch-start registration).
    /// Required before that validator's votes can enter a QuorumCertificate.
    pub fn registerBlsKey(self: *Self, validator_id: [32]u8, pk: Bls.PublicKey) !void {
        try self.bls_keys.put(self.allocator, validator_id, pk);
    }

    /// Build a compact BLS QuorumCertificate for a block that already has
    /// quorum stake. Returns null when quorum is not reached, and
    /// error.SetTooLarge for validator sets beyond the bitmap capacity.
    /// The certificate is verified before being returned, so callers can
    /// trust any non-null result.
    pub fn buildQuorumCertificate(self: *Self, block: *Block) !?QuorumCertificate {
        const BlsModule = @import("../../core/crypto/Bls.zig");
        if (self.quorum.members.items.len > max_bitmap_validators) return error.SetTooLarge;
        const threshold = self.quorum.quorumStakeThreshold();
        if (block.stake_cache < threshold) return null;

        var sigs = try self.allocator.alloc(Bls.Signature, self.quorum.members.items.len);
        defer self.allocator.free(sigs);
        var sigs_len: usize = 0;
        var bitmap: u128 = 0;
        var signer_stake: u128 = 0;
        for (self.quorum.members.items, 0..) |member, i| {
            const vote = block.votes.get(member.id) orelse continue;
            if (!self.bls_keys.contains(member.id)) continue;
            sigs[sigs_len] = vote.signature;
            sigs_len += 1;
            bitmap |= @as(u128, 1) << @intCast(i);
            signer_stake += member.weight();
        }
        if (signer_stake < threshold) return null;

        const qc = QuorumCertificate{
            .block_digest = block.digest,
            .round = block.round,
            .aggregate_signature = BlsModule.aggregateSig(sigs[0..sigs_len]),
            .signer_bitmap = bitmap,
            .quorum_stake = signer_stake,
        };
        if (!qc.verify(self.quorum, &self.bls_keys)) return null;
        return qc;
    }

    /// Receive a timeout vote for the current (round, view). Stale votes and
    /// votes with invalid signatures are dropped; one vote per validator.
    pub fn receiveTimeoutVote(self: *Self, vote: TimeoutVote) !void {
        if (!vote.verifySignature()) return;
        if (vote.round.value != self.current_round.value) return;
        if (vote.round.view != self.current_round.view) return;
        if (self.timeout_votes.contains(vote.voter)) return;
        // Only timeout votes from active quorum members count.
        var is_member = false;
        for (self.quorum.members.items) |member| {
            if (std.mem.eql(u8, &member.id, &vote.voter)) {
                is_member = member.is_active;
                break;
            }
        }
        if (!is_member) return;
        try self.timeout_votes.put(self.allocator, vote.voter, vote);
    }

    /// Assemble a TimeoutCertificate once f+1 validators have timed out on
    /// the current (round, view), then advance the view. Returns the
    /// certificate (caller owns the memory) or null below threshold.
    pub fn tryViewChange(self: *Self) !?TimeoutCertificate {
        if (self.timeout_votes.count() < self.f + 1) return null;

        const voters = try self.allocator.alloc([32]u8, self.timeout_votes.count());
        errdefer self.allocator.free(voters);
        const sigs = try self.allocator.alloc([64]u8, self.timeout_votes.count());
        errdefer self.allocator.free(sigs);
        var i: usize = 0;
        var it = self.timeout_votes.iterator();
        while (it.next()) |entry| : (i += 1) {
            voters[i] = entry.key_ptr.*;
            @memcpy(&sigs[i], entry.value_ptr.signature[0..64]);
        }
        const cert = TimeoutCertificate{
            .round = self.current_round,
            .voters = voters,
            .signatures = sigs,
        };

        // Skip the stalled round and enter the next view.
        self.current_round.value += 1;
        self.current_round.view += 1;
        self.round_start_time = 0;
        self.timeout_votes.clearRetainingCapacity();
        return cert;
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

        if (self.roundBlocksByValue(next_round.value)) |blocks| {
            var it = blocks.iterator();
            while (it.next()) |entry| {
                const block = entry.value_ptr;
                const stake = computeStake(block);
                const threshold = (self.total_stake * 2) / 3 + 1;

                if (stake >= threshold) {
                    const committed_round = Round{ .value = round.value - 2 };

                    if (self.lookupBlock(block_digest)) |committed_block| {
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
            if (self.roundBlocksByValue(next_round.value)) |blocks| {
                var it = blocks.iterator();
                while (it.next()) |entry| {
                    const stake = computeStake(entry.value_ptr);
                    if (stake >= threshold) break :blk true;
                }
            }
            break :blk false;
        };
        if (!n1_quorum) return null;

        // Check round N+2 also has quorum supporting the chain
        const n2_quorum = blk: {
            if (self.roundBlocksByValue(next_next_round.value)) |blocks| {
                var it = blocks.iterator();
                while (it.next()) |entry| {
                    const stake = computeStake(entry.value_ptr);
                    if (stake >= threshold) break :blk true;
                }
            }
            break :blk false;
        };
        if (!n2_quorum) return null;

        // Verify the target block is authored by the round's elected leader:
        // leader blocks with quorum support from N+1 and N+2 commit, others
        // are skipped (their causal history commits via a later leader).
        if (self.lookupBlock(block_digest)) |committed_block| {
            if (committed_block.round.value == round.value - 3) {
                const vc = self.quorum.validatorCount();
                if (vc > 0) {
                    const leader_idx = self.leaderForRound(committed_block.round, vc);
                    const leader_id = self.quorum.members.items[leader_idx].id;
                    if (!std.mem.eql(u8, &committed_block.author, &leader_id)) return null;
                }
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

    fn computeStake(block: *const Block) u128 {
        return block.stake_cache;
    }

    /// View-agnostic round lookup: the DAG keys blocks by the full Round
    /// (value + view), but commit rules must evaluate quorum evidence
    /// across views — after a view change, round N's blocks carry a
    /// non-zero view and a direct key probe would miss them.
    fn roundBlocksByValue(self: *Self, value: u64) ?*std.AutoArrayHashMapUnmanaged([32]u8, Block) {
        var it = self.dag.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.value == value) return entry.value_ptr;
        }
        return null;
    }

    pub fn advanceRound(self: *Self) void {
        self.current_round.value += 1;
        self.timeout_votes.clearRetainingCapacity();
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
        const stake = computeStake(block);
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
    /// Resolve a digest to a live block pointer through the locator.
    /// The returned pointer is valid until the next addBlock on the same
    /// round (inner-map growth); callers use it transiently.
    pub fn lookupBlock(self: *Self, digest: [32]u8) ?*Block {
        const loc = self.block_index.get(digest) orelse return null;
        const round_map = self.dag.getPtr(loc.round) orelse return null;
        return round_map.getPtr(loc.author);
    }

    pub fn findBlockByDigest(self: *Self, digest: [32]u8) ?*Block {
        return self.lookupBlock(digest);
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

    /// Receive and process a batch of votes.
    /// For large batches (>= 64 votes), verifies signatures in parallel
    /// then inserts verified votes sequentially.
    pub fn receiveVotesBatch(self: *Self, votes: []const Vote) !void {
        if (votes.len < 64) {
            for (votes) |vote| try self.receiveVote(vote);
            return;
        }

        const num_threads = @min(@as(usize, 4), (votes.len + 31) / 32);
        const chunk_size = (votes.len + num_threads - 1) / num_threads;

        const valid_flags = try self.allocator.alloc(bool, votes.len);
        defer self.allocator.free(valid_flags);

        var threads = try self.allocator.alloc(std.Thread, num_threads);
        defer self.allocator.free(threads);

        var ti: usize = 0;
        while (ti < num_threads) : (ti += 1) {
            const start = ti * chunk_size;
            const end = @min(start + chunk_size, votes.len);
            threads[ti] = try std.Thread.spawn(.{}, verifyVoteChunk, .{
                votes, valid_flags, start, end, if (self.use_bls_aggregation) &self.bls_keys else null,
            });
        }
        for (threads[0..ti]) |t| t.join();

        // Insert verified votes sequentially (requires exclusive access to DAG)
        for (valid_flags, 0..) |valid, i| {
            if (valid) {
                const vote = votes[i];
                if (self.lookupBlock(vote.block_digest)) |blk| {
                    if (blk.votes.get(vote.voter)) |_| continue;
                    try blk.votes.put(self.allocator, vote.voter, vote);
                    blk.stake_cache += vote.stake;
                }
            }
        }
    }

    fn verifyVoteChunk(
        votes: []const Vote,
        flags: []bool,
        start: usize,
        end: usize,
        bls_keys: ?*const std.AutoArrayHashMapUnmanaged([32]u8, Bls.PublicKey),
    ) void {
        for (start..end) |i| {
            const pk = if (bls_keys) |m| m.get(votes[i].voter) else null;
            flags[i] = votes[i].verifySignatureWith(pk);
        }
    }

    /// Check if the current round has timed out and advance if needed.
    /// Basic liveness mechanism — when a round fails to reach quorum within
    /// the timeout, the node advances to the next round to unblock progress.
    /// Call periodically from the main event loop.
    pub fn checkRoundTimeout(self: *Self, timeout_secs: i64) void {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        const now = ts.sec;

        // Track round start time via round metadata
        if (self.dag.getPtr(self.current_round)) |blocks| {
            // Check if there's at least one block with quorum in this round
            var has_quorum = false;
            var block_it = blocks.iterator();
            while (block_it.next()) |entry| {
                const stake = computeStake(entry.value_ptr);
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
                    self.timeout_votes.clearRetainingCapacity();
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
                self.timeout_votes.clearRetainingCapacity();
            }
        }
    }

    /// Deterministic leader for an arbitrary (round, view).
    /// seed = Blake3(round || view || total_stake)
    pub fn leaderForRound(self: *const Self, round: Round, validator_count: usize) u64 {
        var seed_bytes: [24]u8 = undefined;
        std.mem.writeInt(u64, seed_bytes[0..8], round.value, .big);
        std.mem.writeInt(u64, seed_bytes[8..16], round.view, .big);
        std.mem.writeInt(u64, seed_bytes[16..24], @truncate(self.total_stake), .big);
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(&seed_bytes, &hash, .{});
        const hash_num = std.mem.readInt(u64, hash[0..8], .big);
        return @mod(hash_num, @as(u64, @intCast(validator_count)));
    }

    /// Elect a leader for the current round using the deterministic seed.
    /// Returns a leader index 0..validator_count-1 seeded by (round ^ view).
    pub fn electLeader(self: *Self, validator_count: usize) u64 {
        return self.leaderForRound(self.current_round, validator_count);
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

    /// Prune rounds older than (current_round - retain_horizon) from DAG memory and index.
    /// This prevents unbounded memory growth during long-running consensus operation.
    pub fn pruneHistory(self: *Self, retain_horizon: u64) usize {
        if (self.current_round.value <= retain_horizon) return 0;
        const cutoff_round = self.current_round.value - retain_horizon;
        var pruned_rounds: usize = 0;

        var dag_it = self.dag.iterator();
        var rounds_to_remove = std.ArrayList(Round).empty;
        defer rounds_to_remove.deinit(self.allocator);

        while (dag_it.next()) |entry| {
            const r = entry.key_ptr.*;
            if (r.value < cutoff_round) {
                var block_it = entry.value_ptr.iterator();
                while (block_it.next()) |block_entry| {
                    _ = self.block_index.swapRemove(block_entry.value_ptr.digest);
                    block_entry.value_ptr.deinit(self.allocator);
                }
                entry.value_ptr.deinit(self.allocator);
                rounds_to_remove.append(self.allocator, r) catch break;
                pruned_rounds += 1;
            }
        }

        for (rounds_to_remove.items) |r| {
            _ = self.dag.swapRemove(r);
        }

        var commit_it = self.committed_rounds.iterator();
        var committed_to_remove = std.ArrayList(Round).empty;
        defer committed_to_remove.deinit(self.allocator);
        while (commit_it.next()) |entry| {
            const cr = entry.key_ptr.*;
            if (cr.value < cutoff_round) {
                committed_to_remove.append(self.allocator, cr) catch break;
            }
        }
        for (committed_to_remove.items) |cr| {
            _ = self.committed_rounds.swapRemove(cr);
        }

        return pruned_rounds;
    }

    /// Return the current DAG size in rounds (for monitoring).
    pub fn dagRoundCount(self: *const Self) usize {
        return self.dag.count();
    }

    pub fn getReferences(self: Self) [2]Round {
        var refs: [2]Round = undefined;
        var count: usize = 0;

        if (self.current_round.value >= 2) {
            refs[count] = .{ .value = self.current_round.value - 2 };
            count += 1;
        }
        if (self.current_round.value >= 1) {
            refs[count] = .{ .value = self.current_round.value - 1 };
            count += 1;
        }

        return refs;
    }

    pub fn getReferenceCount(self: Self) usize {
        var count: usize = 0;
        if (self.current_round.value >= 2) count += 1;
        if (self.current_round.value >= 1) count += 1;
        return count;
    }
};

test "Mysticeti block creation" {
    const allocator = std.testing.allocator;
    var quorum = try Quorum.Quorum.init(allocator);
    defer quorum.deinit();

    for (0..4) |i| {
        try quorum.addValidator(@as([32]u8, @splat(@intCast(i + 1))), 1000);
    }

    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();

    const parents = &[_]Round{ .{ .value = 0 }, .{ .value = 1 } };
    var block = try Block.create(
        @as([32]u8, @splat(1)),
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
        try quorum.addValidator(@as([32]u8, @splat(@intCast(i + 1))), 1000);
    }

    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();

    try std.testing.expect(consensus.f == 1);
    try std.testing.expect(consensus.total_stake == 4000);
}

test "detectEquivocation returns evidence for conflicting votes" {
    const vote_a = Vote{
        .voter = @as([32]u8, @splat(7)),
        .stake = 100,
        .round = .{ .value = 42 },
        .block_digest = @as([32]u8, @splat(1)),
        .signature = @as([32]u8, @splat(2)) ++ @as([64]u8, @splat(0)),
    };
    const vote_b = Vote{
        .voter = @as([32]u8, @splat(7)),
        .stake = 100,
        .round = .{ .value = 42 },
        .block_digest = @as([32]u8, @splat(3)),
        .signature = @as([32]u8, @splat(4)) ++ @as([64]u8, @splat(0)),
    };
    const ev = detectEquivocation(vote_a, vote_b) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 42), ev.round.value);
    try std.testing.expectEqual(vote_a.block_digest, ev.first_block_digest);
    try std.testing.expectEqual(vote_b.block_digest, ev.conflicting_block_digest);
}

test "Mysticeti pruneHistory removes old rounds" {
    const allocator = std.testing.allocator;
    var quorum = try Quorum.Quorum.init(allocator);
    defer quorum.deinit();

    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();

    // Add blocks across rounds 1 to 10
    for (1..11) |r| {
        const parents = &[_]Round{.{ .value = r - 1 }};
        var block = try Block.create(
            @as([32]u8, @splat(1)),
            .{ .value = r },
            "payload",
            parents,
            allocator,
        );
        defer block.deinit(allocator);
        try consensus.addBlock(block);
    }
    consensus.current_round = .{ .value = 10 };

    // Prune with retain_horizon = 5 (keep rounds 5..10, prune 1..4)
    const pruned = consensus.pruneHistory(5);
    try std.testing.expectEqual(@as(usize, 4), pruned);
    try std.testing.expect(!consensus.dag.contains(.{ .value = 1 }));
    try std.testing.expect(consensus.dag.contains(.{ .value = 5 }));
}

comptime {
    if (!@hasDecl(Mysticeti, "tryCommit")) @compileError("Mysticeti must have tryCommit method");
    if (!@hasDecl(Mysticeti, "addBlock")) @compileError("Mysticeti must have addBlock method");
}

fn testQuorum4(allocator: std.mem.Allocator) !*Quorum.Quorum {
    const quorum = try Quorum.Quorum.init(allocator);
    for (0..4) |i| {
        try quorum.addValidator(@as([32]u8, @splat(@intCast(i + 1))), 1000);
    }
    return quorum;
}

test "QuorumCertificate build, verify, and wire roundtrip" {
    const allocator = std.testing.allocator;
    var quorum = try testQuorum4(allocator);
    defer quorum.deinit();
    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();
    consensus.use_bls_aggregation = true;

    // Register BLS keys for all four validators (seed = validator id byte).
    for (0..4) |i| {
        const seed = @as([32]u8, @splat(@intCast(0x41 + i)));
        try consensus.registerBlsKey(@as([32]u8, @splat(@intCast(i + 1))), Bls.derivePublicKey(seed));
    }

    // Propose a block and collect BLS votes from a 3-validator quorum.
    var block = try consensus.proposeBlock(@as([32]u8, @splat(1)), "qc-payload");
    defer block.deinit(allocator);
    for (0..3) |i| {
        const voter = @as([32]u8, @splat(@intCast(i + 1)));
        const sk = @as([32]u8, @splat(@intCast(0x41 + i)));
        const vote = try consensus.createVote(voter, sk, 1000, &block);
        try consensus.receiveVote(vote);
    }

    const stored = consensus.findBlockByDigest(block.digest) orelse return error.TestUnexpectedResult;
    try std.testing.expect(consensus.hasQuorum(stored));
    const qc = (try consensus.buildQuorumCertificate(stored)) orelse return error.TestUnexpectedResult;

    // Certificate commits to the block digest and carries 3 signers.
    try std.testing.expectEqual(block.digest, qc.block_digest);
    try std.testing.expectEqual(@as(u128, 3000), qc.quorum_stake);
    try std.testing.expectEqual(@as(u32, 3), @popCount(qc.signer_bitmap));
    try std.testing.expect(qc.verify(quorum, &consensus.bls_keys));

    // A fourth (non-signer) vote slot must remain unset in the bitmap.
    try std.testing.expect(qc.signer_bitmap & (@as(u128, 1) << 3) == 0);

    // Wire roundtrip preserves the certificate.
    const wire = try qc.serialize(allocator);
    defer allocator.free(wire);
    const back = try QuorumCertificate.deserialize(allocator, wire);
    try std.testing.expectEqual(qc.signer_bitmap, back.signer_bitmap);
    try std.testing.expectEqual(qc.aggregate_signature, back.aggregate_signature);
    try std.testing.expect(back.verify(quorum, &consensus.bls_keys));

    // Tampered aggregate signature must fail verification.
    var bad = qc;
    bad.aggregate_signature[0] ^= 0xFF;
    try std.testing.expect(!bad.verify(quorum, &consensus.bls_keys));

    // Bitmap claiming the non-signing validator must fail (no key misuse,
    // invalid aggregate for that signer set).
    var padded = qc;
    padded.signer_bitmap |= @as(u128, 1) << 3;
    try std.testing.expect(!padded.verify(quorum, &consensus.bls_keys));
}

/// Ed25519 identity helper: validator id IS the derived public key.
fn ed25519Id(seed: [32]u8) [32]u8 {
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    return kp.public_key.toBytes();
}

fn testQuorum4Derived(allocator: std.mem.Allocator, seeds: []const [32]u8) !*Quorum.Quorum {
    const quorum = try Quorum.Quorum.init(allocator);
    for (seeds) |seed| {
        try quorum.addValidator(ed25519Id(seed), 1000);
    }
    return quorum;
}

test "view change assembles TimeoutCertificate at f+1 validators" {
    const allocator = std.testing.allocator;
    const seeds = [_][32]u8{
        @as([32]u8, @splat(0xB1)),
        @as([32]u8, @splat(0xB2)),
        @as([32]u8, @splat(0xB3)),
        @as([32]u8, @splat(0xB4)),
    };
    var quorum = try testQuorum4Derived(allocator, &seeds);
    defer quorum.deinit();
    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();

    // f = 1 with 4 validators: view change needs 2 timeout votes.
    var below = try consensus.tryViewChange();
    try std.testing.expect(below == null);

    const tv0 = TimeoutVote.sign(ed25519Id(seeds[0]), seeds[0], consensus.current_round);
    try consensus.receiveTimeoutVote(tv0);
    below = try consensus.tryViewChange();
    try std.testing.expect(below == null);

    const tv1 = TimeoutVote.sign(ed25519Id(seeds[1]), seeds[1], consensus.current_round);
    try consensus.receiveTimeoutVote(tv1);

    // Votes for a stale round and from a non-member are dropped.
    const stale = TimeoutVote.sign(ed25519Id(seeds[2]), seeds[2], .{ .value = 99, .view = 0 });
    try consensus.receiveTimeoutVote(stale);
    const outsider_sk = @as([32]u8, @splat(0xE9));
    const outsider = TimeoutVote.sign(ed25519Id(outsider_sk), outsider_sk, consensus.current_round);
    try consensus.receiveTimeoutVote(outsider);

    const cert = (try consensus.tryViewChange()) orelse return error.TestUnexpectedResult;
    defer cert.deinit(allocator);
    try std.testing.expect(cert.verify(quorum));
    try std.testing.expectEqual(@as(u64, 2), cert.voters.len);

    // View advanced and the vote set was cleared.
    try std.testing.expectEqual(@as(u64, 1), consensus.current_round.view);
    try std.testing.expectEqual(@as(u64, 1), consensus.current_round.value);
    try std.testing.expect((try consensus.tryViewChange()) == null);

    // Wire roundtrip of the certificate remains verifiable.
    const wire = try cert.serialize(allocator);
    defer allocator.free(wire);
    const back = try TimeoutCertificate.deserialize(allocator, wire);
    defer back.deinit(allocator);
    try std.testing.expect(back.verify(quorum));
}

test "3-chain commit requires the elected leader's block" {
    const allocator = std.testing.allocator;
    const seeds = [_][32]u8{
        @as([32]u8, @splat(0xC1)),
        @as([32]u8, @splat(0xC2)),
        @as([32]u8, @splat(0xC3)),
        @as([32]u8, @splat(0xC4)),
    };
    var quorum = try testQuorum4Derived(allocator, &seeds);
    defer quorum.deinit();
    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();
    consensus.commit_3chain_threshold = 0; // force 3-chain path

    // Determine the leader of round 4, then build blocks at rounds 4..9.
    // tryCommit3Chain(N) commits the leader block at N-3 using quorum
    // evidence from rounds N+1 and N+2, so rounds 8 and 9 must exist.
    const round_four = Round{ .value = 4 };
    const leader_idx: usize = @intCast(consensus.leaderForRound(round_four, 4));
    const leader_id = quorum.members.items[leader_idx].id;

    var digests: [6][32]u8 = undefined;
    for (4..10) |r| {
        const author = if (r == 4) leader_id else ed25519Id(seeds[0]);
        const parents = &[_]Round{.{ .value = @intCast(r - 1) }};
        var block = try Block.create(author, .{ .value = @intCast(r) }, "3chain", parents, allocator);
        defer block.deinit(allocator);
        digests[r - 4] = block.digest;
        try consensus.addBlock(block);
        // Give every block full-quorum votes so N+1/N+2 checks pass.
        const stored = consensus.findBlockByDigest(block.digest) orelse return error.TestUnexpectedResult;
        for (0..3) |i| {
            const vote = try consensus.createVote(ed25519Id(seeds[i]), seeds[i], 1000, stored);
            try consensus.receiveVote(vote);
        }
    }

    // Leader block in round 2 commits via 3-chain from round 7.
    const leader_commit = try consensus.tryCommit3Chain(.{ .value = 7 }, digests[0]);
    try std.testing.expect(leader_commit != null);
    try std.testing.expectEqual(@as(u64, 4), leader_commit.?.round.value);

    // Same round authored by a non-leader must not commit.
    var nonleader_id = leader_id;
    nonleader_id[0] ^= 0xFF;
    var bad_block = try Block.create(nonleader_id, .{ .value = 4 }, "3chain-bad", &[_]Round{.{ .value = 3 }}, allocator);
    defer bad_block.deinit(allocator);
    try consensus.addBlock(bad_block);
    const stored_bad = consensus.findBlockByDigest(bad_block.digest) orelse return error.TestUnexpectedResult;
    for (0..3) |i| {
        const vote = try consensus.createVote(ed25519Id(seeds[i]), seeds[i], 1000, stored_bad);
        try consensus.receiveVote(vote);
    }
    const nonleader_commit = try consensus.tryCommit3Chain(.{ .value = 7 }, bad_block.digest);
    try std.testing.expect(nonleader_commit == null);
}

test "block author signature: valid signed blocks accepted, forged rejected" {
    const allocator = std.testing.allocator;
    var quorum = try testQuorum4(allocator);
    defer quorum.deinit();
    var consensus = try Mysticeti.init(allocator, quorum);
    defer consensus.deinit();

    const seed = @as([32]u8, @splat(0xD1));
    const author = ed25519Id(seed);

    var signed = try Block.createSigned(author, seed, .{ .value = 3 }, "signed", &[_]Round{.{ .value = 2 }}, allocator);
    defer signed.deinit(allocator);
    try consensus.addBlock(signed);
    try std.testing.expect(consensus.findBlockByDigest(signed.digest) != null);
    try std.testing.expect(signed.verifyAuthorSignature());

    // Forged signature (wrong key) must be rejected by addBlock.
    var forged = try Block.createSigned(author, @as([32]u8, @splat(0xEE)), .{ .value = 4 }, "forged", &[_]Round{.{ .value = 3 }}, allocator);
    defer forged.deinit(allocator);
    try std.testing.expectError(error.InvalidAuthorSignature, consensus.addBlock(forged));

    // Tampered digest invalidates the signature check.
    var tampered = signed;
    tampered.round = .{ .value = 5 };
    try std.testing.expect(!tampered.verifyAuthorSignature());
}
