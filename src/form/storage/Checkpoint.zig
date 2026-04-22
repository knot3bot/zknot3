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
        const state_root = try computeStateRoot(changes, allocator);

        return .{
            .sequence = sequence,
            .timestamp = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .previous_digest = previous_digest,
            .object_changes = try allocator.dupe(ObjectChange, changes),
            .state_root = state_root,
            .signatures = .empty,
        };
    }

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
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
            try buf.append(allocator, @intFromEnum(change.status));
        }

        return buf.toOwnedSlice(allocator);
    }

    pub fn digest(self: Self) [32]u8 {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&self.state_root);
        ctx.update(&self.previous_digest);
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
    pub fn verify(
        self: Self,
        allocator: std.mem.Allocator,
        previous_checkpoint: ?*const Self,
        validator_set: ?*const ValidatorSet,
        bls_validator_set: ?*const BlsValidatorSet,
    ) !bool {
        // 1. Verify state root matches recomputed value
        const computed_root = try verifyStateRoot(self.object_changes, allocator);
        if (!std.mem.eql(u8, &self.state_root, &computed_root)) {
            return false;
        }

        // 2. Verify previous digest chain
        if (previous_checkpoint) |prev| {
            const prev_digest = prev.digest();
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
            const total_stake = vset.totalStake();
            if (total_stake == 0) return false;
            // Quorum threshold is 2/3+ of total stake
            const quorum_threshold = (total_stake * 2) / 3 + 1;
            var stake_sum: u64 = 0;
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

        // 4. Optional BLS aggregate verification (same quorum threshold).
        if (bls_validator_set) |bvset| {
            const sig = self.bls_signature orelse return false;
            const bitmap = self.bls_signer_bitmap orelse return false;
            if (bvset.validators.len == 0) return false;
            var total_power: u64 = 0;
            for (bvset.validators) |v| total_power += v.voting_power;
            if (total_power == 0) return false;
            const quorum_threshold = (total_power * 2) / 3 + 1;
            var selected = std.ArrayList(Bls.PublicKey).empty;
            defer selected.deinit(allocator);
            var power: u64 = 0;
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

        return true;
    }

    /// Add a signature from a validator
    pub fn addSignature(self: *Self, allocator: std.mem.Allocator, validator_id: [32]u8, signature: [64]u8) !void {
        try self.signatures.put(allocator, validator_id, signature);
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
        return [_]u8{0} ** 32;
    }

    var level = try allocator.alloc([32]u8, changes.len);
    defer allocator.free(level);

    for (changes, 0..) |change, i| {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(change.id.asBytes());
        ctx.update(&change.version.encode());
        ctx.final(&level[i]);
    }

    while (level.len > 1) {
        const next_len = (level.len + 1) / 2;
        var next_level = try allocator.alloc([32]u8, next_len);
        defer allocator.free(level);
        level = next_level;

        for (0..next_len) |i| {
            const left = i * 2;
            const right = left + 1;

            var ctx = std.crypto.hash.Blake3.init(.{});
            ctx.update(&level[left]);

            if (right < level.len) {
                ctx.update(&level[right]);
            } else {
                ctx.update(&[_]u8{0} ** 32);
            }

            ctx.final(&next_level[i]);
        }
    }

    return level[0];
}

fn computeStateRoot(changes: []const Checkpoint.ObjectChange, allocator: std.mem.Allocator) ![32]u8 {
    return verifyStateRoot(changes, allocator);
}

pub const CheckpointSequence = struct {
    current: u64,
    initial_digest: [32]u8,

    const Self = @This();

    pub fn init() Self {
        return .{
            .current = 0,
            .initial_digest = [_]u8{0} ** 32,
        };
    }

    pub fn next(self: *Self, checkpoint: Checkpoint) void {
        self.current = checkpoint.sequence + 1;
    }

    pub fn getLatestSequence(self: Self) u64 {
        return self.current;
    }

    pub fn deinit(self: *Self) void {
        // No-op: CheckpointSequence has no heap allocations
        _ = self;
    }
};

test "Checkpoint creation" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(
        1,
        [_]u8{0} ** 32,
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

test "Checkpoint digest" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(
        1,
        [_]u8{0} ** 32,
        &changes,
        allocator,
    );
    defer cp.deinit(allocator);
    const digest1 = cp.digest();
    const digest2 = cp.digest();

    try std.testing.expect(std.mem.eql(u8, &digest1, &digest2));
}

test "Checkpoint verify state root" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(1, [_]u8{0} ** 32, &changes, allocator);
    defer cp.deinit(allocator);

    // Verify should pass with no previous checkpoint and no validator set
    const is_valid = try cp.verify(allocator, null, null, null);
    try std.testing.expect(is_valid);
}

test "Checkpoint verify fails on previous digest mismatch" {
    const allocator = std.testing.allocator;

    const changes_prev = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj_prev"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };
    var prev = try Checkpoint.create(7, [_]u8{0} ** 32, &changes_prev, allocator);
    defer prev.deinit(allocator);

    const changes_cur = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("obj_cur"),
            .version = .{ .seq = 2, .causal = [_]u8{1} ** 16 },
            .status = .modified,
        },
    };
    // Intentionally wrong previous digest.
    var current = try Checkpoint.create(8, [_]u8{9} ** 32, &changes_cur, allocator);
    defer current.deinit(allocator);

    const is_valid = try current.verify(allocator, &prev, null, null);
    try std.testing.expect(!is_valid);
}

test "Checkpoint verify fails on non-continuous sequence" {
    const allocator = std.testing.allocator;

    const changes_prev = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("seq_prev"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };
    var prev = try Checkpoint.create(11, [_]u8{0} ** 32, &changes_prev, allocator);
    defer prev.deinit(allocator);

    const changes_cur = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("seq_cur"),
            .version = .{ .seq = 2, .causal = [_]u8{2} ** 16 },
            .status = .modified,
        },
    };
    var current = try Checkpoint.create(13, prev.digest(), &changes_cur, allocator);
    defer current.deinit(allocator);

    const is_valid = try current.verify(allocator, &prev, null, null);
    try std.testing.expect(!is_valid);
}

test "Checkpoint verify accepts BLS quorum over signingCommitment" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("bls_obj"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(1, [_]u8{0} ** 32, &changes, allocator);
    defer cp.deinit(allocator);

    const sk1 = [_]u8{0x31} ** 32;
    const sk2 = [_]u8{0x32} ** 32;
    const msg = try cp.signingCommitment(allocator);
    const sig1 = Bls.sign(sk1, &msg);
    const sig2 = Bls.sign(sk2, &msg);
    cp.bls_signature = Bls.aggregateSig(&[_]Bls.Signature{ sig1, sig2 });
    const bitmap = [_]u8{ 1, 1, 0 };
    cp.bls_signer_bitmap = &bitmap;

    const vset = BlsValidatorSet{
        .validators = &[_]BlsValidator{
            .{ .validator_id = [_]u8{0x01} ** 32, .public_key = Bls.derivePublicKey(sk1), .voting_power = 400 },
            .{ .validator_id = [_]u8{0x02} ** 32, .public_key = Bls.derivePublicKey(sk2), .voting_power = 400 },
            .{ .validator_id = [_]u8{0x03} ** 32, .public_key = Bls.derivePublicKey([_]u8{0x33} ** 32), .voting_power = 400 },
        },
    };

    try std.testing.expect(try cp.verify(allocator, null, null, &vset));
}

test "Checkpoint verify rejects BLS bitmap below quorum threshold" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = core.ObjectID.hash("bls_obj_low"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };

    var cp = try Checkpoint.create(1, [_]u8{0} ** 32, &changes, allocator);
    defer cp.deinit(allocator);

    const sk1 = [_]u8{0x41} ** 32;
    const msg = try cp.signingCommitment(allocator);
    cp.bls_signature = Bls.aggregateSig(&[_]Bls.Signature{Bls.sign(sk1, &msg)});
    const bitmap = [_]u8{ 1, 0, 0 };
    cp.bls_signer_bitmap = &bitmap;

    const vset = BlsValidatorSet{
        .validators = &[_]BlsValidator{
            .{ .validator_id = [_]u8{0x01} ** 32, .public_key = Bls.derivePublicKey(sk1), .voting_power = 400 },
            .{ .validator_id = [_]u8{0x02} ** 32, .public_key = Bls.derivePublicKey([_]u8{0x42} ** 32), .voting_power = 400 },
            .{ .validator_id = [_]u8{0x03} ** 32, .public_key = Bls.derivePublicKey([_]u8{0x43} ** 32), .voting_power = 400 },
        },
    };

    try std.testing.expect(!try cp.verify(allocator, null, null, &vset));
}
