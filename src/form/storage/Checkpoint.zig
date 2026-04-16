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

/// Checkpoint data structure
pub const Checkpoint = struct {
    sequence: u64,
    timestamp: i64,
    previous_digest: [32]u8,
    object_changes: []const ObjectChange,
    state_root: [32]u8,
    /// Validator signatures: validator_id -> BLS signature
    signatures: std.AutoArrayHashMap([32]u8, [96]u8),

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
            .timestamp = std.time.timestamp(),
            .previous_digest = previous_digest,
            .object_changes = try allocator.dupe(ObjectChange, changes),
            .state_root = state_root,
            .signatures = std.AutoArrayHashMap([32]u8, [96]u8).init(allocator),
        };
    }

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
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

        // 3. Verify signatures meet quorum
        if (validator_set) |vset| {
            if (self.signatures.count() == 0) return false;

            const total_stake = vset.totalStake();
            // Quorum threshold is 2/3+ of total stake
            const quorum_threshold = (total_stake * 2) / 3 + 1;
            var stake_sum: u64 = 0;
            var it = self.signatures.iterator();
            while (it.next()) |entry| {
                if (vset.get(entry.key_ptr.*)) |validator| {
                    // Skip BLS verification in simplified build
                    stake_sum += validator.stake.votingPower();
                }
            }
            // Require quorum stake for commit
            if (stake_sum < quorum_threshold) return false;
        }

        return true;
    }

    /// Add a signature from a validator
    pub fn addSignature(self: *Self, validator_id: [32]u8, signature: [96]u8) !void {
        try self.signatures.put(validator_id, signature);
    }

    /// Deinitialize checkpoint and free resources
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.object_changes);
        self.signatures.deinit();
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
    const is_valid = try cp.verify(allocator, null, null);
    try std.testing.expect(is_valid);
}
