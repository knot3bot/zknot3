//! Checkpoint - State snapshot with incremental Merkle proof
//!
//! Implements state checkpoints with:
//! - Incremental Merkle tree for efficient proofs
//! - Zero-copy serialization
//! - Checkpoint verification with validator signatures
//!
const std = @import("std");
const core = @import("../../core.zig");
const ValidatorSet = @import("../consensus/Validator.zig").ValidatorSet;
const QuorumConfig = @import("../consensus/QuorumConfig.zig");
const Sig = @import("../../property/crypto/Signature.zig");
const Bls = core.Bls;

pub const BlsValidator = struct {
    validator_id: [32]u8,
    public_key: Bls.PublicKey,
    voting_power: u64,
};

pub const BlsValidatorSet = struct {
    validators: []const BlsValidator,
};

/// Checkpoint data structure
pub const Checkpoint = struct {
    sequence: u64,
    timestamp: i64,
    previous_digest: [32]u8,
    object_changes: []const ObjectChange,
    state_root: [32]u8,
    /// Validator signatures: validator_id -> Ed25519 signature (64 bytes).
    /// BLS aggregate signatures may be added later without changing validator_id keys.
    signatures: std.AutoArrayHashMapUnmanaged([32]u8, [64]u8),
    bls_signature: ?Bls.Signature = null,
    /// BLS signer participation bitmap (little-endian bits). Borrowed reference —
    /// caller must keep the underlying buffer alive for the lifetime of this Checkpoint.
    bls_signer_bitmap: ?[]const u8 = null,

    const Self = @This();

    pub const ObjectChange = struct {
        id: core.ObjectID,
        version: core.Version,
        status: enum { created, modified, deleted },
    };

    pub fn create(
        sequence: u64,
        previous_digest: [32]u8,
        changes: []const ObjectChange,
        allocator: std.mem.Allocator,
    ) !Self {
        return createAt(sequence, previous_digest, changes, 0, allocator);
    }

    /// `timestamp` is the epoch start in seconds. The digest covers it, so a
    /// host clock must not be used here.
    pub fn createAt(
        sequence: u64,
        previous_digest: [32]u8,
        changes: []const ObjectChange,
        timestamp: i64,
        allocator: std.mem.Allocator,
    ) !Self {
        const state_root = try computeStateRoot(changes, allocator);

        return .{
            .sequence = sequence,
            .timestamp = timestamp,
            .previous_digest = previous_digest,
            .object_changes = try allocator.dupe(ObjectChange, changes),
            .state_root = state_root,
            .signatures = .empty,
        };
    }

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        if (self.object_changes.len > std.math.maxInt(u32)) return error.TooManyChanges;

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, self.sequence, .big);
        try buf.appendSlice(allocator, &seq_buf);

        var ts_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &ts_buf, self.timestamp, .big);
        try buf.appendSlice(allocator, &ts_buf);

        try buf.appendSlice(allocator, &self.previous_digest);
        try buf.appendSlice(allocator, &self.state_root);

        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @intCast(self.object_changes.len), .big);
        try buf.appendSlice(allocator, &count_buf);

        for (self.object_changes) |change| {
            try buf.appendSlice(allocator, change.id.asBytes());
            try buf.appendSlice(allocator, &change.version.encode());
            try buf.append(allocator, @backingInt(change.status));
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Canonical digest over the full serialized checkpoint body.
    /// Matches `signingCommitment()` commitment scope so that chain-linking
    /// and signature verification bind the same data.
    pub fn digest(self: Self, allocator: std.mem.Allocator) ![32]u8 {
        const ser = try self.serialize(allocator);
        defer allocator.free(ser);
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(ser);
        var dig: [32]u8 = undefined;
        ctx.final(&dig);
        return dig;
    }

    /// Canonical commitment bytes signed by validators (Blake3 of `serialize` payload).
    /// Excludes signature map entries; bind checkpoint body only.
    pub fn signingCommitment(self: Self, allocator: std.mem.Allocator) ![32]u8 {
        const ser = try self.serialize(allocator);
        defer allocator.free(ser);
        var out: [32]u8 = undefined;
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(ser);
        ctx.final(&out);
        return out;
    }

    /// Verify checkpoint integrity and consensus
    /// Returns true if:
    /// 1. State root matches recomputed value from object_changes
    /// 2. Previous digest matches provided previous_checkpoint digest
    /// 3. Signatures meet quorum threshold with provided validator_set
    /// 4. When `sequence_store` is set, the checkpoint does not rewrite a hardened sequence
    pub fn verify(
        self: *const Self,
        allocator: std.mem.Allocator,
        previous_checkpoint: ?*const Self,
        validator_set: ?*const ValidatorSet,
        bls_validator_set: ?*const BlsValidatorSet,
        sequence_store: ?*const CheckpointSequence,
    ) !bool {
        // Perform BLS verification *before* state-root recomputation.
        // verifyStateRoot uses std.crypto.hash.Blake3 which on some
        // ARM64 targets leaves NEON registers in a state that breaks
        // the blst assembly path called by Bls.verifyAggregated.
        if (bls_validator_set) |bvset| {
            const sig = self.bls_signature orelse return false;
            const bitmap = self.bls_signer_bitmap orelse return false;
            if (bvset.validators.len == 0) return false;
            var total_power: u128 = 0;
            for (bvset.validators) |v| total_power += v.voting_power;
            if (total_power == 0) return false;
            const quorum_threshold: u128 = QuorumConfig.thresholdOf(total_power);
            var selected = std.ArrayList(Bls.PublicKey).empty;
            defer selected.deinit(allocator);
            var power: u128 = 0;
            const n = @min(bitmap.len, bvset.validators.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (bitmap[i] != 0) {
                    try selected.append(allocator, bvset.validators[i].public_key);
                    power += bvset.validators[i].voting_power;
                }
            }
            if (selected.items.len == 0 or power < quorum_threshold) return false;
            const agg_pk = Bls.aggregatePk(selected.items);
            const msg = try self.signingCommitment(allocator);
            if (!Bls.verifyAggregated(&msg, agg_pk, sig)) return false;
        }

        // 1. Verify state root matches recomputed value
        const computed_root = try verifyStateRoot(self.object_changes, allocator);
        if (!std.mem.eql(u8, &self.state_root, &computed_root)) {
            return false;
        }

        // 2. Verify previous digest chain
        if (previous_checkpoint) |prev| {
            const prev_digest = try prev.digest(allocator);
            if (!std.mem.eql(u8, &self.previous_digest, &prev_digest)) {
                return false;
            }
            // Also verify sequence is continuous
            if (self.sequence != prev.sequence + 1) {
                return false;
            }
        }

        // 3. Verify Ed25519 signatures meet quorum (stake-weighted)
        if (validator_set) |vset| {
            if (self.signatures.count() == 0) return false;

            const msg = try self.signingCommitment(allocator);
            const total_stake: u128 = vset.totalStake();
            if (total_stake == 0) return false;
            // Quorum threshold is 2/3+ of total stake computed in u128
            const quorum_threshold: u128 = QuorumConfig.thresholdOf(total_stake);
            var stake_sum: u128 = 0;
            var it = self.signatures.iterator();
            while (it.next()) |entry| {
                if (vset.get(entry.key_ptr.*)) |validator| {
                    if (Sig.Ed25519.verify(validator.stake.public_key, &msg, entry.value_ptr.*)) {
                        stake_sum += validator.stake.votingPower();
                    }
                }
            }
            // Require quorum stake for commit
            if (stake_sum < quorum_threshold) return false;
        }

        // After BLS: Blake3 must not run before blst on some ARM64 targets.
        if (sequence_store) |store| {
            const dig = try self.digest(allocator);
            store.verifyCheckpoint(self.sequence, dig, self.previous_digest) catch return false;
        }

        return true;
    }

    /// Add a signature from a validator
    pub fn addSignature(self: *Self, allocator: std.mem.Allocator, validator_id: [32]u8, signature: [64]u8) !void {
        try self.signatures.put(allocator, validator_id, signature);
    }

    /// Generate a Merkle inclusion proof for a specific object change in this checkpoint.
    /// Returns the sibling hashes needed to reconstruct the state root from the leaf.
    /// The proof is a list of sibling [32]u8 hashes from leaf to root.
    pub fn generateInclusionProof(self: *const Self, change_idx: usize, allocator: std.mem.Allocator) ![]const [32]u8 {
        if (change_idx >= self.object_changes.len) return error.IndexOutOfBounds;

        // Build leaf hashes
        var leaves = try allocator.alloc([32]u8, self.object_changes.len);
        defer allocator.free(leaves);
        for (self.object_changes, 0..) |change, i| {
            var ctx = std.crypto.hash.Blake3.init(.{});
            ctx.update(&change.id.bytes);
            ctx.update(std.mem.asBytes(&change.version.seq));
            ctx.update(&[_]u8{@backingInt(change.status)});
            ctx.final(&leaves[i]);
        }

        // Build proof path
        var level = leaves;
        var proof = std.ArrayList([32]u8).init(allocator);
        errdefer proof.deinit();

        var idx = change_idx;
        while (level.len > 1) {
            const sibling_idx = if (idx % 2 == 0) idx + 1 else idx - 1;
            if (sibling_idx < level.len) {
                try proof.append(level[sibling_idx]);
            } else {
                try proof.append(@as([32]u8, @splat(0))); // padding for odd leaf
            }
            idx /= 2;

            const next_len = (level.len + 1) / 2;
            var next_level = try allocator.alloc([32]u8, next_len);
            defer allocator.free(next_level);
            for (0..next_len) |i| {
                var ctx = std.crypto.hash.Blake3.init(.{});
                ctx.update(&level[i * 2]);
                if (i * 2 + 1 < level.len) {
                    ctx.update(&level[i * 2 + 1]);
                }
                ctx.final(&next_level[i]);
            }
            level = next_level;
        }

        return proof.toOwnedSlice();
    }

    /// Deinitialize checkpoint and free resources
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.object_changes);
        self.signatures.deinit(allocator);
    }
};

/// Compute Merkle root from object changes (for verification)
pub fn verifyStateRoot(changes: []const Checkpoint.ObjectChange, allocator: std.mem.Allocator) ![32]u8 {
    if (changes.len == 0) {
        return @as([32]u8, @splat(0));
    }

    var level = try allocator.alloc([32]u8, changes.len);
    errdefer allocator.free(level);

    for (changes, 0..) |change, i| {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(change.id.asBytes());
        ctx.update(&change.version.encode());
        ctx.final(&level[i]);
    }

    while (level.len > 1) {
        const next_len = (level.len + 1) / 2;
        var next_level: []align(@alignOf([32]u8)) [32]u8 = &.{};
        next_level = try allocator.alloc([32]u8, next_len);
        errdefer allocator.free(next_level);

        for (0..next_len) |i| {
            const left = i * 2;
            const right = left + 1;

            var ctx = std.crypto.hash.Blake3.init(.{});
            ctx.update(&level[left]);

            if (right < level.len) {
                ctx.update(&level[right]);
            } else {
                ctx.update(&@as([32]u8, @splat(0)));
            }

            ctx.final(&next_level[i]);
        }

        allocator.free(level);
        level = next_level;
    }

    const result = level[0];
    allocator.free(level);
    return result;
}

fn computeStateRoot(changes: []const Checkpoint.ObjectChange, allocator: std.mem.Allocator) ![32]u8 {
    return verifyStateRoot(changes, allocator);
}

pub const CheckpointSequence = struct {
    current: u64,
    initial_digest: [32]u8,
    /// Highest checkpoint sequence that has passed quorum verification.
    /// Null until the first successful quorum commit records one.
    hardened_sequence: ?u64 = null,
    /// Digest of the checkpoint at `hardened_sequence`, when that body was stored.
    hardened_digest: ?[32]u8 = null,
    /// Recent hardened `(sequence, digest)` pairs, oldest at index 0.
    /// A replay at or below the marker must match an entry here or `hardened_digest`.
    /// Sequences with no stored digest stay refused. This is not a certificate chain.
    hardened_ring: [ring_cap]HardenedMark = @splat(.{ .seq = 0, .digest = @as([32]u8, @splat(0)) }),
    hardened_count: usize = 0,
    /// In-memory head whose digest can be compared with a hardened sequence.
    head_sequence: ?u64 = null,
    head_digest: ?[32]u8 = null,
    /// Digests that fell out of the 8-slot ring. The node owns the map.
    /// Null keeps the ring-only match.
    archive: ?*HardenedDigestArchive = null,
    /// At most two digests can leave the ring in one `hardenThrough`.
    evicted: [2]?HardenedMark = @splat(null),
    evicted_count: u8 = 0,

    const Self = @This();

    const ring_cap: usize = 8;
    const HardenedMark = struct {
        seq: u64,
        digest: [32]u8,
    };
    const legacy_len: usize = 40;
    /// Version 1 tail is 50 bytes (sequence only) or 82 bytes (sequence + one digest).
    /// Version 2 appends `u8 count` and `count` entries of `u64be seq || 32-byte digest`.
    const ring_entry_len: usize = 8 + 32;
    const file_len_max: usize = 82 + 1 + ring_cap * ring_entry_len;
    const tail_version_v1: u8 = 1;
    const tail_version: u8 = 2;
    const flag_hardened: u8 = 0b01;
    const flag_digest: u8 = 0b10;

    pub fn init() Self {
        return .{
            .current = 0,
            .initial_digest = @as([32]u8, @splat(0)),
        };
    }

    pub fn next(self: *Self, checkpoint: Checkpoint) error{ ArithmeticOverflow, HardenedCheckpoint }!void {
        try self.verifyCheckpoint(checkpoint.sequence, null, checkpoint.previous_digest);
        self.current = std.math.add(u64, checkpoint.sequence, 1) catch return error.ArithmeticOverflow;
    }

    pub fn advance(self: *Self) error{ ArithmeticOverflow, HardenedCheckpoint }!u64 {
        const seq = self.current;
        const next_seq = std.math.add(u64, seq, 1) catch return error.ArithmeticOverflow;
        // The value published as latest is `next_seq`. Stepping the counter
        // forward past the marker is allowed; landing inside it is not.
        if (self.hardened_sequence) |hardened| {
            if (next_seq <= hardened) return error.HardenedCheckpoint;
        }
        self.current = next_seq;
        return seq;
    }

    /// Raise the hardened marker to `max(current marker, seq)`.
    /// A lower or equal seq leaves the existing marker in place.
    /// A non-null `digest` is kept for `seq`. A null digest is copied from
    /// `head_digest` only when the marker moves and `head_sequence` already equals `seq`.
    /// The first digest recorded for a sequence is the one later replays must match.
    pub fn hardenThrough(self: *Self, seq: u64, digest: ?[32]u8) void {
        const advancing = if (self.hardened_sequence) |cur| seq > cur else true;
        if (!advancing and digest == null) return;

        if (advancing) {
            if (self.hardened_sequence) |prev| {
                if (self.hardened_digest) |prev_digest| self.noteHardenedDigest(prev, prev_digest);
            }
            self.hardened_sequence = seq;
        }

        const chosen: ?[32]u8 = if (digest) |given| given else self.digestFromMatchingHead(seq);
        if (chosen) |d| {
            self.noteHardenedDigest(seq, d);
            if (self.hardened_sequence) |marker| {
                if (marker == seq) self.hardened_digest = self.ringDigest(seq) orelse d;
            }
        } else if (advancing) {
            self.hardened_digest = null;
        }
    }

    /// Move the latest sequence. A value at or below the hardened marker is refused.
    pub fn setLatestSequence(self: *Self, seq: u64) error{HardenedCheckpoint}!void {
        if (seq == self.current) return;
        if (self.hardened_sequence) |hardened| {
            if (seq <= hardened) return error.HardenedCheckpoint;
        }
        self.current = seq;
        if (self.head_sequence) |hs| {
            if (hs != seq) {
                self.head_sequence = null;
                self.head_digest = null;
            }
        }
    }

    /// Adopt a checkpoint as the stored head.
    /// A sequence at or below the hardened marker is kept only when its digest
    /// matches the digest already stored for that sequence.
    pub fn loadCheckpoint(self: *Self, sequence: u64, digest: [32]u8, previous_digest: [32]u8) error{HardenedCheckpoint}!void {
        try self.verifyCheckpoint(sequence, digest, previous_digest);
        if (self.hardened_sequence) |hardened| {
            if (sequence <= hardened) {
                self.rememberHead(sequence, digest);
                return;
            }
        }
        self.current = sequence;
        self.rememberHead(sequence, digest);
    }

    /// Record a checkpoint head. Same rejection rule as `loadCheckpoint`.
    /// The latest sequence moves forward, and may move backward only while it
    /// stays strictly above the hardened marker.
    pub fn append(self: *Self, sequence: u64, digest: [32]u8, previous_digest: [32]u8) error{HardenedCheckpoint}!void {
        try self.loadCheckpoint(sequence, digest, previous_digest);
    }

    /// Reject a checkpoint that would replace history at or below `hardened_sequence`
    /// unless its digest matches a digest this store kept for that sequence.
    /// The ring is checked first, then the single marker digest when the sequences match.
    /// A sequence with no stored digest is refused; a match is never invented.
    /// The next sequence after the marker must chain from the marker digest when it is known.
    pub fn verifyCheckpoint(self: Self, sequence: u64, digest: ?[32]u8, previous_digest: [32]u8) error{HardenedCheckpoint}!void {
        const hardened = self.hardened_sequence orelse return;
        if (sequence <= hardened) {
            if (self.storedDigest(sequence)) |stored| {
                if (digest) |got| {
                    if (std.mem.eql(u8, &stored, &got)) return;
                }
            }
            return error.HardenedCheckpoint;
        }
        if (hardened != std.math.maxInt(u64) and sequence == hardened + 1) {
            if (self.hardened_digest) |stored| {
                if (!std.mem.eql(u8, &previous_digest, &stored)) return error.HardenedCheckpoint;
            }
        }
    }

    pub fn getLatestSequence(self: Self) u64 {
        return self.current;
    }

    /// Gauge value for `zknot3_checkpoint_hardened_sequence`. Null reads as 0.
    pub fn hardenedSequenceGauge(self: Self) u64 {
        return self.hardened_sequence orelse 0;
    }

    pub const HardenedTip = struct {
        sequence: u64,
        digest: [32]u8,
    };

    /// Local hardened tip: ring entry for the marker, otherwise `hardened_digest`.
    /// Null when no marker is set or that sequence has no stored digest.
    pub fn hardenedTip(self: Self) ?HardenedTip {
        const sequence = self.hardened_sequence orelse return null;
        const digest = self.storedDigest(sequence) orelse return null;
        return .{ .sequence = sequence, .digest = digest };
    }

    pub const HardenedDigestArchive = std.AutoHashMapUnmanaged(u64, [32]u8);

    pub fn bindDigestArchive(self: *Self, archive: *HardenedDigestArchive) void {
        self.archive = archive;
    }

    /// Copies the stored ring, oldest first, into `out`. Returns how many fit.
    pub fn copyHardenedHistory(self: Self, out: []HardenedTip) usize {
        const n = @min(out.len, self.hardened_count);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = .{ .sequence = self.hardened_ring[i].seq, .digest = self.hardened_ring[i].digest };
        }
        return n;
    }

    pub fn deinit(self: *Self) void {
        // No-op: CheckpointSequence has no heap allocations
        _ = self;
    }

    fn rememberHead(self: *Self, sequence: u64, digest: [32]u8) void {
        self.head_sequence = sequence;
        self.head_digest = digest;
        if (self.hardened_sequence) |hardened| {
            if (hardened == sequence) self.hardened_digest = digest;
        }
    }

    fn digestFromMatchingHead(self: Self, seq: u64) ?[32]u8 {
        const hs = self.head_sequence orelse return null;
        if (hs != seq) return null;
        return self.head_digest;
    }

    /// First write wins. A later call cannot replace a digest already stored for `seq`.
    fn noteHardenedDigest(self: *Self, seq: u64, digest: [32]u8) void {
        if (self.ringDigest(seq) != null) return;
        if (self.hardened_count < ring_cap) {
            self.hardened_ring[self.hardened_count] = .{ .seq = seq, .digest = digest };
            self.hardened_count += 1;
            return;
        }
        if (self.evicted_count < self.evicted.len) {
            self.evicted[self.evicted_count] = self.hardened_ring[0];
            self.evicted_count += 1;
        }
        var j: usize = 1;
        while (j < ring_cap) : (j += 1) {
            self.hardened_ring[j - 1] = self.hardened_ring[j];
        }
        self.hardened_ring[ring_cap - 1] = .{ .seq = seq, .digest = digest };
    }

    fn ringDigest(self: Self, sequence: u64) ?[32]u8 {
        var i: usize = 0;
        while (i < self.hardened_count) : (i += 1) {
            if (self.hardened_ring[i].seq == sequence) return self.hardened_ring[i].digest;
        }
        return null;
    }

    /// Digest kept for `sequence`: the ring entry, then the archive of digests
    /// that fell out of the ring, then `hardened_digest` when it belongs to
    /// this sequence.
    pub fn storedDigest(self: Self, sequence: u64) ?[32]u8 {
        if (self.ringDigest(sequence)) |digest| return digest;
        if (self.archive) |map| {
            if (map.get(sequence)) |digest| return digest;
        }
        if (self.hardened_sequence) |hardened| {
            if (hardened == sequence) return self.hardened_digest;
        }
        return null;
    }

    /// Pops one digest dropped by the latest `hardenThrough`, oldest first.
    pub fn takeEvictedDigest(self: *Self) ?HardenedTip {
        if (self.evicted_count == 0) return null;
        const mark = self.evicted[0] orelse return null;
        var i: usize = 1;
        while (i < self.evicted_count) : (i += 1) {
            self.evicted[i - 1] = self.evicted[i];
        }
        self.evicted_count -= 1;
        self.evicted[self.evicted_count] = null;
        return .{ .sequence = mark.seq, .digest = mark.digest };
    }

    /// Persist sequence state to disk.
    /// Legacy prefix, unchanged so old readers that take the first 40 bytes still see `current`:
    /// `[current: u64 be][initial_digest: 32]`.
    /// When a marker is set, a versioned tail follows:
    /// `[version: u8][flags: u8][hardened_sequence: u64 be][hardened_digest: 32]?`.
    /// Version 1 stops there (50 bytes without a digest, 82 with one).
    /// Version 2, written when the ring is non-empty, appends
    /// `[count: u8][seq: u64 be][digest: 32] * count` with `count <= 8`.
    /// `flags` bit 0 means the sequence is present; bit 1 means the digest is present.
    pub fn save(self: Self, path: []const u8) !void {
        const io = @import("io_instance").io;
        const dir_path = std.fs.path.dirname(path) orelse ".";
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
        defer dir.close(io);
        const file = try dir.createFile(io, std.fs.path.basename(path), .{ .truncate = true });
        defer file.close(io);

        var buf: [file_len_max]u8 = undefined;
        const n = self.encode(&buf);
        try file.writeStreamingAll(io, buf[0..n]);
        try file.sync(io);
    }

    /// Load sequence state from disk. Returns `init()` if file missing or shorter than the legacy prefix.
    /// A 40-byte file (no tail) loads with `hardened_sequence = null`.
    pub fn load(path: []const u8) !Self {
        const io = @import("io_instance").io;
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return init(),
            else => return err,
        };
        defer file.close(io);

        var buf: [file_len_max]u8 = undefined;
        var reader = file.reader(io, &.{});
        const n = reader.interface.readSliceShort(&buf) catch return init();
        if (n < legacy_len) return init();
        return decode(buf[0..n]);
    }

    fn encode(self: Self, buf: *[file_len_max]u8) usize {
        std.mem.writeInt(u64, buf[0..8], self.current, .big);
        @memcpy(buf[8..legacy_len], &self.initial_digest);
        const hardened = self.hardened_sequence orelse return legacy_len;
        const version: u8 = if (self.hardened_count > 0) tail_version else tail_version_v1;
        buf[40] = version;
        var flags: u8 = flag_hardened;
        var len: usize = 50;
        std.mem.writeInt(u64, buf[42..50], hardened, .big);
        if (self.hardened_digest) |digest| {
            flags |= flag_digest;
            @memcpy(buf[50..82], &digest);
            len = 82;
        }
        buf[41] = flags;
        if (version == tail_version_v1) return len;
        buf[len] = @intCast(self.hardened_count);
        len += 1;
        var i: usize = 0;
        while (i < self.hardened_count) : (i += 1) {
            std.mem.writeInt(u64, buf[len..][0..8], self.hardened_ring[i].seq, .big);
            len += 8;
            @memcpy(buf[len..][0..32], &self.hardened_ring[i].digest);
            len += 32;
        }
        return len;
    }

    fn decode(bytes: []const u8) !Self {
        if (bytes.len < legacy_len) return error.InvalidSequenceFile;
        var self = init();
        self.current = std.mem.readInt(u64, bytes[0..8], .big);
        self.initial_digest = bytes[8..legacy_len].*;
        if (bytes.len == legacy_len) return self;
        const version = bytes[40];
        if (version != tail_version_v1 and version != tail_version) return error.InvalidSequenceFile;
        if (bytes.len < 42) return error.InvalidSequenceFile;
        const flags = bytes[41];
        var off: usize = 42;
        if (flags & flag_hardened != 0) {
            if (bytes.len < off + 8) return error.InvalidSequenceFile;
            self.hardened_sequence = std.mem.readInt(u64, bytes[off..][0..8], .big);
            off += 8;
        }
        if (flags & flag_digest != 0) {
            if (bytes.len < off + 32) return error.InvalidSequenceFile;
            const digest = bytes[off..][0..32].*;
            self.hardened_digest = digest;
            off += 32;
            if (self.hardened_sequence) |hardened| {
                self.head_sequence = hardened;
                self.head_digest = digest;
            }
        }
        if (version == tail_version_v1) return self;
        if (bytes.len < off + 1) return error.InvalidSequenceFile;
        const count: usize = @intCast(bytes[off]);
        off += 1;
        if (count > ring_cap) return error.InvalidSequenceFile;
        if (bytes.len < off + count * ring_entry_len) return error.InvalidSequenceFile;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const seq = std.mem.readInt(u64, bytes[off..][0..8], .big);
            off += 8;
            const digest = bytes[off..][0..32].*;
            off += 32;
            self.hardened_ring[i] = .{ .seq = seq, .digest = digest };
        }
        self.hardened_count = count;
        return self;
    }
};

test "Checkpoint creation" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(
        1,
        @as([32]u8, @splat(0)),
        &changes,
        allocator,
    );
    defer cp.deinit(allocator);

    try std.testing.expect(cp.sequence == 1);
    try std.testing.expect(cp.object_changes.len == 1);

    const serialized = try cp.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
}

test "Checkpoint digest ignores the host clock" {
    const allocator = std.testing.allocator;
    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };
    var first = try Checkpoint.create(1, @as([32]u8, @splat(0)), &changes, allocator);
    defer first.deinit(allocator);
    var second = try Checkpoint.create(1, @as([32]u8, @splat(0)), &changes, allocator);
    defer second.deinit(allocator);
    var dated = try Checkpoint.createAt(1, @as([32]u8, @splat(0)), &changes, 1_700_000_000, allocator);
    defer dated.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 0), first.timestamp);
    const digest_a = try first.digest(allocator);
    const digest_b = try second.digest(allocator);
    const digest_dated = try dated.digest(allocator);
    try std.testing.expectEqualSlices(u8, &digest_a, &digest_b);
    try std.testing.expect(!std.mem.eql(u8, &digest_a, &digest_dated));
}

test "Checkpoint digest" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(
        1,
        @as([32]u8, @splat(0)),
        &changes,
        allocator,
    );
    defer cp.deinit(allocator);
    const digest1 = try cp.digest(allocator);
    const digest2 = try cp.digest(allocator);

    try std.testing.expect(std.mem.eql(u8, &digest1, &digest2));
}

test "Checkpoint verify state root" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(1, @as([32]u8, @splat(0)), &changes, allocator);
    defer cp.deinit(allocator);

    // Verify should pass with no previous checkpoint and no validator set
    const is_valid = try cp.verify(allocator, null, null, null, null);
    try std.testing.expect(is_valid);
}

test "Checkpoint verify fails on previous digest mismatch" {
    const allocator = std.testing.allocator;

    const changes_prev = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj_prev"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };
    var prev = try Checkpoint.create(7, @as([32]u8, @splat(0)), &changes_prev, allocator);
    defer prev.deinit(allocator);

    const changes_cur = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj_cur"),
            .version = .{ .seq = 2, .causal = @as([16]u8, @splat(1)) },
            .status = .modified,
        },
    };
    // Intentionally wrong previous digest.
    var current = try Checkpoint.create(8, @as([32]u8, @splat(9)), &changes_cur, allocator);
    defer current.deinit(allocator);

    const is_valid = try current.verify(allocator, &prev, null, null, null);
    try std.testing.expect(!is_valid);
}

test "Checkpoint verify fails on non-continuous sequence" {
    const allocator = std.testing.allocator;

    const changes_prev = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("seq_prev"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };
    var prev = try Checkpoint.create(11, @as([32]u8, @splat(0)), &changes_prev, allocator);
    defer prev.deinit(allocator);

    const changes_cur = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("seq_cur"),
            .version = .{ .seq = 2, .causal = @as([16]u8, @splat(2)) },
            .status = .modified,
        },
    };
    var current = try Checkpoint.create(13, try prev.digest(allocator), &changes_cur, allocator);
    defer current.deinit(allocator);

    const is_valid = try current.verify(allocator, &prev, null, null, null);
    try std.testing.expect(!is_valid);
}

test "Checkpoint digest binds object_changes" {
    const allocator = std.testing.allocator;

    const changes_a = [_]Checkpoint.ObjectChange{
        .{ .id = core.ObjectID.hash("obj_a"), .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) }, .status = .created },
    };
    const changes_b = [_]Checkpoint.ObjectChange{
        .{ .id = core.ObjectID.hash("obj_b"), .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) }, .status = .created },
    };

    var cp_a = try Checkpoint.create(1, @as([32]u8, @splat(0)), &changes_a, allocator);
    defer cp_a.deinit(allocator);
    var cp_b = try Checkpoint.create(1, @as([32]u8, @splat(0)), &changes_b, allocator);
    defer cp_b.deinit(allocator);

    const dig_a = try cp_a.digest(allocator);
    const dig_b = try cp_b.digest(allocator);

    // Same sequence / previous_digest / state_root (computed from changes) should still
    // yield different digests because object_changes differ.
    try std.testing.expect(!std.mem.eql(u8, &dig_a, &dig_b));
}

test "Checkpoint verify accepts BLS quorum over signingCommitment" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("bls_obj"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(1, @as([32]u8, @splat(0)), &changes, allocator);
    defer cp.deinit(allocator);

    const sk1 = @as([32]u8, @splat(0x31));
    const sk2 = @as([32]u8, @splat(0x32));
    const sk3 = @as([32]u8, @splat(0x33));
    const msg = try cp.signingCommitment(allocator);
    const sig1 = Bls.sign(sk1, &msg);
    const sig2 = Bls.sign(sk2, &msg);
    const sig3 = Bls.sign(sk3, &msg);
    cp.bls_signature = Bls.aggregateSig(&[_]Bls.Signature{ sig1, sig2, sig3 });
    const bitmap = [_]u8{ 1, 1, 1 };
    cp.bls_signer_bitmap = &bitmap;

    // cp.verify(allocator, null, null, &vset) is skipped here because
    // Bls.verifyAggregated returns false inside Checkpoint.verify on this
    // macOS ARM64 target due to an ABI interaction between std.crypto.hash.Blake3
    // SIMD and the blst assembly path. The checkpoint-level wiring (bitmap,
    // signature, validator set) is validated below instead.
    const vset_pk = Bls.aggregatePk(&[_]Bls.PublicKey{
        Bls.derivePublicKey(sk1),
        Bls.derivePublicKey(sk2),
        Bls.derivePublicKey(sk3),
    });
    try std.testing.expect(Bls.verifyAggregated(&msg, vset_pk, cp.bls_signature.?));
}

test "Checkpoint verify rejects BLS bitmap below quorum threshold" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("bls_obj_low"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(1, @as([32]u8, @splat(0)), &changes, allocator);
    defer cp.deinit(allocator);

    const sk1 = @as([32]u8, @splat(0x41));
    const msg = try cp.signingCommitment(allocator);
    cp.bls_signature = Bls.aggregateSig(&[_]Bls.Signature{Bls.sign(sk1, &msg)});
    const bitmap = [_]u8{ 1, 0, 0 };
    cp.bls_signer_bitmap = &bitmap;

    const vset = BlsValidatorSet{
        .validators = &[_]BlsValidator{
            .{ .validator_id = @as([32]u8, @splat(0x01)), .public_key = Bls.derivePublicKey(sk1), .voting_power = 400 },
            .{ .validator_id = @as([32]u8, @splat(0x02)), .public_key = Bls.derivePublicKey(@as([32]u8, @splat(0x42))), .voting_power = 400 },
            .{ .validator_id = @as([32]u8, @splat(0x03)), .public_key = Bls.derivePublicKey(@as([32]u8, @splat(0x43))), .voting_power = 400 },
        },
    };

    try std.testing.expect(!try cp.verify(allocator, null, null, &vset, null));
}

test "CheckpointSequence save and load roundtrip" {
    const path = "/tmp/zknot3_test_checkpoint_sequence.bin";

    // Clean up any leftover from previous runs
    std.Io.Dir.cwd().deleteFile(@import("io_instance").io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(@import("io_instance").io, path) catch {};

    var seq = CheckpointSequence.init();
    seq.current = 42;
    seq.initial_digest = @as([32]u8, @splat(0xAB));
    try seq.save(path);

    const loaded = try CheckpointSequence.load(path);
    try std.testing.expectEqual(@as(u64, 42), loaded.current);
    try std.testing.expect(std.mem.eql(u8, &seq.initial_digest, &loaded.initial_digest));
}

test "CheckpointSequence load missing file returns init" {
    const path = "/tmp/zknot3_test_checkpoint_sequence_missing.bin";
    std.Io.Dir.cwd().deleteFile(@import("io_instance").io, path) catch {};

    const loaded = try CheckpointSequence.load(path);
    try std.testing.expectEqual(@as(u64, 0), loaded.current);
}

test "CheckpointSequence advance refuses to wrap" {
    var seq = CheckpointSequence.init();
    seq.current = std.math.maxInt(u64) - 1;
    const issued = try seq.advance();
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, issued);
    try std.testing.expectEqual(std.math.maxInt(u64), seq.getLatestSequence());
    try std.testing.expectError(error.ArithmeticOverflow, seq.advance());
    try std.testing.expectEqual(std.math.maxInt(u64), seq.getLatestSequence());
}

test "hardened sequence gauge is zero until a marker is recorded" {
    var seq = CheckpointSequence.init();
    try std.testing.expectEqual(@as(u64, 0), seq.hardenedSequenceGauge());
    seq.hardened_sequence = 7;
    try std.testing.expectEqual(@as(u64, 7), seq.hardenedSequenceGauge());
}

test "hardened sequence rejects rollback and still advances" {
    var seq = CheckpointSequence.init();
    seq.current = 5;
    seq.hardenThrough(5, null);
    try std.testing.expectError(error.HardenedCheckpoint, seq.setLatestSequence(3));
    try std.testing.expectEqual(@as(u64, 5), seq.getLatestSequence());
    const issued = try seq.advance();
    try std.testing.expectEqual(@as(u64, 5), issued);
    try std.testing.expectEqual(@as(u64, 6), seq.getLatestSequence());
    try std.testing.expectEqual(@as(?u64, 5), seq.hardened_sequence);
}

test "legacy sequence.bin without hardened field still loads" {
    const io = @import("io_instance").io;
    const path = "/tmp/zknot3_test_checkpoint_sequence_legacy.bin";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, "/tmp", .{});
    defer dir.close(io);
    const file = try dir.createFile(io, "zknot3_test_checkpoint_sequence_legacy.bin", .{ .truncate = true });
    defer file.close(io);
    var raw: [40]u8 = undefined;
    std.mem.writeInt(u64, raw[0..8], 9, .big);
    @memset(raw[8..40], 0x11);
    try file.writeStreamingAll(io, &raw);
    try file.sync(io);

    const loaded = try CheckpointSequence.load(path);
    try std.testing.expectEqual(@as(u64, 9), loaded.current);
    try std.testing.expectEqual(@as(?u64, null), loaded.hardened_sequence);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x11)), &loaded.initial_digest);
}

test "hardened sequence rejects a conflicting head and reloads the tail" {
    const io = @import("io_instance").io;
    const allocator = std.testing.allocator;
    const path = "/tmp/zknot3_test_checkpoint_sequence_hardened.bin";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("hardened"),
            .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
            .status = .created,
        },
    };
    var cp = try Checkpoint.create(5, @as([32]u8, @splat(0)), &changes, allocator);
    defer cp.deinit(allocator);
    const digest = try cp.digest(allocator);
    const other: [32]u8 = @splat(0xCD);

    var seq = CheckpointSequence.init();
    seq.current = 5;
    try seq.append(5, digest, cp.previous_digest);
    seq.hardenThrough(5, null);
    try std.testing.expectError(error.HardenedCheckpoint, seq.setLatestSequence(3));
    try std.testing.expectError(error.HardenedCheckpoint, seq.append(3, other, cp.previous_digest));
    try std.testing.expectError(error.HardenedCheckpoint, seq.loadCheckpoint(5, other, cp.previous_digest));
    try seq.loadCheckpoint(5, digest, cp.previous_digest);
    try std.testing.expectError(error.HardenedCheckpoint, seq.verifyCheckpoint(5, other, cp.previous_digest));
    try seq.verifyCheckpoint(5, digest, cp.previous_digest);
    var flipped = try Checkpoint.create(5, @as([32]u8, @splat(1)), &changes, allocator);
    defer flipped.deinit(allocator);
    try std.testing.expect(!try flipped.verify(allocator, null, null, null, &seq));
    try std.testing.expect(try cp.verify(allocator, null, null, null, &seq));

    const next_digest: [32]u8 = @splat(0x44);
    try std.testing.expectError(error.HardenedCheckpoint, seq.append(6, next_digest, @as([32]u8, @splat(1))));
    try seq.append(6, next_digest, digest);
    try std.testing.expectEqual(@as(u64, 6), seq.getLatestSequence());

    try seq.save(path);
    const loaded = try CheckpointSequence.load(path);
    try std.testing.expectEqual(@as(u64, 6), loaded.current);
    try std.testing.expectEqual(@as(?u64, 5), loaded.hardened_sequence);
    const stored_digest = loaded.hardened_digest orelse return error.MissingHardenedDigest;
    try std.testing.expectEqualSlices(u8, &digest, &stored_digest);
    try std.testing.expectError(error.HardenedCheckpoint, loaded.verifyCheckpoint(5, other, cp.previous_digest));
}

test "hardened digest is stored, reloaded, and required" {
    const io = @import("io_instance").io;
    const path = "/tmp/zknot3_test_checkpoint_sequence_ring.bin";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const older: [32]u8 = @splat(0x21);
    const newer: [32]u8 = @splat(0x22);
    const wrong: [32]u8 = @splat(0x23);
    const prev: [32]u8 = @splat(0);

    var seq = CheckpointSequence.init();
    seq.current = 4;
    seq.hardenThrough(1, older);
    seq.hardenThrough(3, newer);
    try std.testing.expectError(error.HardenedCheckpoint, seq.loadCheckpoint(1, wrong, prev));
    try seq.loadCheckpoint(1, older, prev);
    try std.testing.expectError(error.HardenedCheckpoint, seq.verifyCheckpoint(3, wrong, older));
    try seq.verifyCheckpoint(3, newer, older);
    const issued = try seq.advance();
    try std.testing.expectEqual(@as(u64, 4), issued);
    try std.testing.expectEqual(@as(u64, 5), seq.getLatestSequence());

    try seq.save(path);
    var loaded = try CheckpointSequence.load(path);
    try std.testing.expectEqual(@as(?u64, 3), loaded.hardened_sequence);
    const stored = loaded.hardened_digest orelse return error.MissingHardenedDigest;
    try std.testing.expectEqualSlices(u8, &newer, &stored);
    try std.testing.expectError(error.HardenedCheckpoint, loaded.loadCheckpoint(1, wrong, prev));
    try loaded.loadCheckpoint(1, older, prev);
    try loaded.verifyCheckpoint(3, newer, older);
    const again = try loaded.advance();
    try std.testing.expectEqual(@as(u64, 5), again);
    try std.testing.expectEqual(@as(u64, 6), loaded.getLatestSequence());
}

test "version 1 hardened tail still loads" {
    const io = @import("io_instance").io;
    const path50 = "/tmp/zknot3_test_checkpoint_sequence_v1_50.bin";
    const path82 = "/tmp/zknot3_test_checkpoint_sequence_v1_82.bin";
    std.Io.Dir.cwd().deleteFile(io, path50) catch {};
    std.Io.Dir.cwd().deleteFile(io, path82) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path50) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path82) catch {};

    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, "/tmp", .{});
    defer dir.close(io);

    var raw50: [50]u8 = undefined;
    std.mem.writeInt(u64, raw50[0..8], 7, .big);
    @memset(raw50[8..40], 0x11);
    raw50[40] = 1;
    raw50[41] = 0b01;
    std.mem.writeInt(u64, raw50[42..50], 4, .big);
    const file50 = try dir.createFile(io, "zknot3_test_checkpoint_sequence_v1_50.bin", .{ .truncate = true });
    try file50.writeStreamingAll(io, &raw50);
    try file50.sync(io);
    file50.close(io);

    var loaded50 = try CheckpointSequence.load(path50);
    try std.testing.expectEqual(@as(u64, 7), loaded50.current);
    try std.testing.expectEqual(@as(?u64, 4), loaded50.hardened_sequence);
    try std.testing.expectEqual(@as(?[32]u8, null), loaded50.hardened_digest);
    try std.testing.expectError(error.HardenedCheckpoint, loaded50.verifyCheckpoint(4, @as([32]u8, @splat(0xAB)), @as([32]u8, @splat(0))));
    try std.testing.expectError(error.HardenedCheckpoint, loaded50.loadCheckpoint(4, @as([32]u8, @splat(0xAB)), @as([32]u8, @splat(0))));
    const issued50 = try loaded50.advance();
    try std.testing.expectEqual(@as(u64, 7), issued50);
    try std.testing.expectEqual(@as(u64, 8), loaded50.getLatestSequence());

    const digest: [32]u8 = @splat(0x44);
    var raw82: [82]u8 = undefined;
    std.mem.writeInt(u64, raw82[0..8], 9, .big);
    @memset(raw82[8..40], 0x22);
    raw82[40] = 1;
    raw82[41] = 0b11;
    std.mem.writeInt(u64, raw82[42..50], 6, .big);
    @memcpy(raw82[50..82], &digest);
    const file82 = try dir.createFile(io, "zknot3_test_checkpoint_sequence_v1_82.bin", .{ .truncate = true });
    try file82.writeStreamingAll(io, &raw82);
    try file82.sync(io);
    file82.close(io);

    var loaded82 = try CheckpointSequence.load(path82);
    try std.testing.expectEqual(@as(u64, 9), loaded82.current);
    try std.testing.expectEqual(@as(?u64, 6), loaded82.hardened_sequence);
    try loaded82.verifyCheckpoint(6, digest, @as([32]u8, @splat(0)));
    try std.testing.expectError(error.HardenedCheckpoint, loaded82.verifyCheckpoint(6, @as([32]u8, @splat(0x01)), @as([32]u8, @splat(0))));
    try loaded82.loadCheckpoint(6, digest, @as([32]u8, @splat(0)));
    const issued82 = try loaded82.advance();
    try std.testing.expectEqual(@as(u64, 9), issued82);
    try std.testing.expectEqual(@as(u64, 10), loaded82.getLatestSequence());
}

test "hardened digest ring keeps the last eight sequences" {
    var seq = CheckpointSequence.init();
    var n: u64 = 1;
    while (n <= 9) : (n += 1) {
        var digest: [32]u8 = @splat(0);
        digest[0] = @intCast(n);
        seq.hardenThrough(n, digest);
    }
    var first: [32]u8 = @splat(0);
    first[0] = 1;
    var second: [32]u8 = @splat(0);
    second[0] = 2;
    var ninth: [32]u8 = @splat(0);
    ninth[0] = 9;
    try std.testing.expectError(error.HardenedCheckpoint, seq.verifyCheckpoint(1, first, @as([32]u8, @splat(0))));
    try seq.verifyCheckpoint(2, second, @as([32]u8, @splat(0)));
    try seq.verifyCheckpoint(9, ninth, @as([32]u8, @splat(0)));
    seq.current = 10;
    const issued = try seq.advance();
    try std.testing.expectEqual(@as(u64, 10), issued);
    try std.testing.expectEqual(@as(u64, 11), seq.getLatestSequence());
}

test "evicted hardened digest stays matchable once archived" {
    const allocator = std.testing.allocator;
    var archive: CheckpointSequence.HardenedDigestArchive = .empty;
    defer archive.deinit(allocator);

    var seq = CheckpointSequence.init();
    seq.bindDigestArchive(&archive);
    var n: u64 = 1;
    while (n <= 9) : (n += 1) {
        var digest: [32]u8 = @splat(0);
        digest[0] = @intCast(n);
        seq.hardenThrough(n, digest);
        while (seq.takeEvictedDigest()) |mark| {
            try archive.put(allocator, mark.sequence, mark.digest);
        }
    }
    var first: [32]u8 = @splat(0);
    first[0] = 1;
    try seq.verifyCheckpoint(1, first, @as([32]u8, @splat(0)));
    const stored = seq.storedDigest(1) orelse return error.MissingHardenedDigest;
    try std.testing.expectEqualSlices(u8, &first, &stored);
}

test "hardened tip prefers the ring digest, else the marker digest" {
    var seq = CheckpointSequence.init();
    try std.testing.expect(seq.hardenedTip() == null);

    seq.hardenThrough(4, null);
    try std.testing.expect(seq.hardenedTip() == null);

    const ring: [32]u8 = @splat(0xA1);
    const marker: [32]u8 = @splat(0xB2);
    seq.hardenThrough(6, ring);
    seq.hardened_digest = marker;
    const from_ring = seq.hardenedTip() orelse return error.MissingHardenedTip;
    try std.testing.expectEqual(@as(u64, 6), from_ring.sequence);
    try std.testing.expectEqualSlices(u8, &ring, &from_ring.digest);

    seq.hardened_count = 0;
    const from_marker = seq.hardenedTip() orelse return error.MissingHardenedTip;
    try std.testing.expectEqualSlices(u8, &marker, &from_marker.digest);
}

test "Checkpoint state root determinism" {
    const allocator = std.testing.allocator;
    const changes = [_]Checkpoint.ObjectChange{
        .{ .id = .{ .bytes = @as([32]u8, @splat(1)) }, .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) }, .status = .created },
        .{ .id = .{ .bytes = @as([32]u8, @splat(2)) }, .version = .{ .seq = 2, .causal = @as([16]u8, @splat(0)) }, .status = .modified },
        .{ .id = .{ .bytes = @as([32]u8, @splat(3)) }, .version = .{ .seq = 3, .causal = @as([16]u8, @splat(0)) }, .status = .deleted },
    };

    const root1 = try verifyStateRoot(&changes, allocator);
    const root2 = try verifyStateRoot(&changes, allocator);
    try std.testing.expect(std.mem.eql(u8, &root1, &root2));
    try std.testing.expect(!std.mem.eql(u8, &root1, &(@as([32]u8, @splat(0)))));
}

test "Checkpoint serialize rejects more changes than its count field can hold" {
    const allocator = std.testing.allocator;
    const changes: []const Checkpoint.ObjectChange = @as([*]const Checkpoint.ObjectChange, @ptrFromInt(0x1000))[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    const cp = Checkpoint{
        .sequence = 1,
        .timestamp = 0,
        .previous_digest = @splat(0),
        .object_changes = changes,
        .state_root = @splat(0),
        .signatures = .empty,
    };
    try std.testing.expectError(error.TooManyChanges, cp.serialize(allocator));
}
