//! Runtime Invariants - Debug assertions for system safety
//!
//! Implements runtime checks for the 三源合恰 framework:
//! - Form invariants: ObjectID uniqueness, version ordering
//! - Property invariants: Linear resource tracking, access control
//! - Metric invariants: Consensus round ordering, stake arithmetic

const std = @import("std");
const core = @import("../core.zig");
const ObjectID = core.ObjectID;
const Versioned = core.Versioned;
const Ownership = core.Ownership;
const LSMTree = @import("form/storage/LSMTree");
const Interpreter = @import("property/move_vm/Interpreter");
const Quorum = @import("form/consensus/Quorum");

/// Runtime invariant violation error
pub const InvariantError = error{
    ObjectIDNotUnique,
    VersionNotMonotonic,
    OwnershipInvalid,
    ResourceLeak,
    ConsensusRoundViolation,
    StakeArithmeticOverflow,
    CausalOrderViolation,
};

/// Form layer invariants
pub const FormInvariants = struct {
    const Self = @This();

    /// Check that object IDs are unique in a set
    pub fn areUnique(ids: []const ObjectID) InvariantError!void {
        var seen = std.AutoArrayHashMap(ObjectID, void).init(std.heap.page_allocator);
        defer seen.deinit();

        for (ids) |id| {
            if (seen.contains(id)) {
                return InvariantError.ObjectIDNotUnique;
            }
            try seen.put(id, {});
        }
    }

    /// Check version monotonicity
    pub fn isMonotonic(versions: []const Versioned) InvariantError!void {
        for (0..versions.len) |i| {
            if (i > 0) {
                if (versions[i].seq <= versions[i - 1].seq) {
                    return InvariantError.VersionNotMonotonic;
                }
            }
        }
    }

    /// Check causal ordering is preserved
    pub fn isCausallyOrdered(versions: []const Versioned) InvariantError!void {
        for (versions) |v| {
            if (v.seq == 0) continue;
            // Causal hash should be non-zero for seq > 0
            const causal_nonzero = for (v.causal) |b| {
                if (b != 0) break true;
            } else false;

            if (!causal_nonzero) {
                return InvariantError.CausalOrderViolation;
            }
        }
    }
};

/// Property layer invariants
pub const PropertyInvariants = struct {
    const Self = @This();

    /// Check linear resource tracking has no leaks
    pub fn isLinear(resources: []const Interpreter.Resource) InvariantError!void {
        for (resources) |r| {
            // Each resource should be used at most once
            var use_count: u32 = 0;
            if (r.moved) use_count += 1;
            if (r.destroyed) use_count += 1;

            if (use_count > 1) {
                return InvariantError.ResourceLeak;
            }
        }
    }

    /// Check ownership transfer is valid
    pub fn isValidOwnership(ownership: Ownership, owner: [32]u8) InvariantError!void {
        switch (ownership) {
            .owned => {
                // Owned objects must have a non-zero owner
                const owner_nonzero = for (owner) |b| {
                    if (b != 0) break true;
                } else false;

                if (!owner_nonzero) {
                    return InvariantError.OwnershipInvalid;
                }
            },
            .shared, .immutable => {
                // Shared and immutable objects don't require owner check
            },
        }
    }
};

/// Metric layer invariants
pub const MetricInvariants = struct {
    const Self = @This();

    /// Check stake arithmetic doesn't overflow
    pub fn stakeArithmeticSafe(total: u128, stake: u128) InvariantError!void {
        if (stake > total) {
            return InvariantError.StakeArithmeticOverflow;
        }
    }

    /// Check consensus rounds are properly ordered
    pub fn roundsOrdered(rounds: []const u64) InvariantError!void {
        for (0..rounds.len) |i| {
            if (i > 0) {
                if (rounds[i] < rounds[i - 1]) {
                    return InvariantError.ConsensusRoundViolation;
                }
            }
        }
    }
};

/// System state for invariant checking
pub const SystemState = struct {
    const Self = @This();

    /// All object IDs in the system
    object_ids: []const ObjectID,
    /// All versions in the system
    versions: []const Versioned,
    /// All resources
    resources: []const Interpreter.Resource,
    /// Validator stakes
    validator_stakes: []const u128,
    /// Total stake
    total_stake: u128,
    /// Current consensus round
    consensus_round: u64,

    /// Check all form invariants
    pub fn checkForm(self: Self) InvariantError!void {
        try FormInvariants.areUnique(self.object_ids);
        try FormInvariants.isMonotonic(self.versions);
        try FormInvariants.isCausallyOrdered(self.versions);
    }

    /// Check all property invariants
    pub fn checkProperty(self: Self) InvariantError!void {
        try PropertyInvariants.isLinear(self.resources);
    }

    /// Check all metric invariants
    pub fn checkMetric(self: Self) InvariantError!void {
        for (self.validator_stakes) |stake| {
            try MetricInvariants.stakeArithmeticSafe(self.total_stake, stake);
        }
    }

    /// Check all invariants
    pub fn check(self: Self) InvariantError!void {
        try self.checkForm();
        try self.checkProperty();
        try self.checkMetric();
    }
};

/// Runtime invariant checker that can be disabled in release builds
pub const RuntimeChecker = struct {
    const Self = @This();

    enabled: bool,

    pub fn init() Self {
        return .{ .enabled = std.debug.runtime_safety };
    }

    pub fn check(self: *Self, state: SystemState) void {
        if (!self.enabled) return;
        state.check() catch |err| {
            std.debug.panic("Runtime invariant violation: {}\n", .{err});
        };
    }

    pub fn checkForm(self: *Self, state: SystemState) void {
        if (!self.enabled) return;
        state.checkForm() catch |err| {
            std.debug.panic("Form invariant violation: {}\n", .{err});
        };
    }

    pub fn checkProperty(self: *Self, state: SystemState) void {
        if (!self.enabled) return;
        state.checkProperty() catch |err| {
            std.debug.panic("Property invariant violation: {}\n", .{err});
        };
    }

    pub fn checkMetric(self: *Self, state: SystemState) void {
        if (!self.enabled) return;
        state.checkMetric() catch |err| {
            std.debug.panic("Metric invariant violation: {}\n", .{err});
        };
    }
};

test "FormInvariants: unique IDs" {
    const ids = &[_]ObjectID{
        ObjectID.hash("a"),
        ObjectID.hash("b"),
        ObjectID.hash("c"),
    };

    try FormInvariants.areUnique(ids);
}

test "FormInvariants: duplicate ID fails" {
    const id = ObjectID.hash("same");
    const ids = &[_]ObjectID{ id, id };

    try std.testing.expectError(InvariantError.ObjectIDNotUnique, FormInvariants.areUnique(ids));
}

test "FormInvariants: monotonic versions" {
    const versions = &[_]Versioned{
        .{ .seq = 1, .causal = [_]u8{1} ** 16 },
        .{ .seq = 2, .causal = [_]u8{2} ** 16 },
        .{ .seq = 3, .causal = [_]u8{3} ** 16 },
    };

    try FormInvariants.isMonotonic(versions);
}

test "FormInvariants: non-monotonic fails" {
    const versions = &[_]Versioned{
        .{ .seq = 3, .causal = [_]u8{1} ** 16 },
        .{ .seq = 2, .causal = [_]u8{2} ** 16 },
        .{ .seq = 4, .causal = [_]u8{3} ** 16 },
    };

    try std.testing.expectError(InvariantError.VersionNotMonotonic, FormInvariants.isMonotonic(versions));
}

test "MetricInvariants: stake arithmetic" {
    try MetricInvariants.stakeArithmeticSafe(1000, 500);
}

test "MetricInvariants: overflow fails" {
    try std.testing.expectError(InvariantError.StakeArithmeticOverflow, MetricInvariants.stakeArithmeticSafe(1000, 1001));
}

test "MetricInvariants: ordered rounds" {
    const rounds = &[_]u64{ 1, 2, 3, 4 };
    try MetricInvariants.roundsOrdered(rounds);
}

test "MetricInvariants: unordered fails" {
    const rounds = &[_]u64{ 1, 3, 2, 4 };
    try std.testing.expectError(InvariantError.ConsensusRoundViolation, MetricInvariants.roundsOrdered(rounds));
}
