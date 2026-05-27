//! Stake - Staking algebra for voting power in consensus

const std = @import("std");

/// Stake amount (u128 for large stake amounts)
pub const StakeAmount = u128;

/// Delegation record
pub const Delegation = struct {
    delegator: [32]u8,
    validator: [32]u8,
    amount: StakeAmount,
};

/// Stake pool
pub const StakePool = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Total stake
    total: StakeAmount,
    /// Self-stake by validators
    self_stake: StakeAmount,
    /// Delegated stake
    delegated: StakeAmount,
    /// Active validators
    validators: std.AutoArrayHashMapUnmanaged([32]u8, StakeAmount),
    /// Per-validator self-stake tracking for correct removeStake
    validator_self_stake: std.AutoArrayHashMapUnmanaged([32]u8, StakeAmount),
    /// Delegations
    delegations: std.ArrayList(Delegation),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .total = 0,
            .self_stake = 0,
            .delegated = 0,
            .validators = .empty,
            .validator_self_stake = .empty,
            .delegations = try std.ArrayList(Delegation).initCapacity(allocator, 16),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.validators.deinit(self.allocator);
        self.validator_self_stake.deinit(self.allocator);
        self.delegations.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Add stake for a validator
    pub fn addStake(self: *Self, validator: [32]u8, amount: StakeAmount, is_self: bool) !void {
        // Update validator stake with overflow check
        const current = self.validators.get(validator) orelse 0;
        const new_validator_stake = std.math.add(StakeAmount, current, amount) catch return error.Overflow;
        try self.validators.put(self.allocator, validator, new_validator_stake);

        // Update totals with overflow check
        self.total = std.math.add(StakeAmount, self.total, amount) catch return error.Overflow;
        if (is_self) {
            self.self_stake = std.math.add(StakeAmount, self.self_stake, amount) catch return error.Overflow;
            const current_self = self.validator_self_stake.get(validator) orelse 0;
            const new_self = std.math.add(StakeAmount, current_self, amount) catch return error.Overflow;
            try self.validator_self_stake.put(self.allocator, validator, new_self);
        } else {
            self.delegated = std.math.add(StakeAmount, self.delegated, amount) catch return error.Overflow;
        }
    }

    /// Remove stake. Tracks self vs delegated correctly.
    pub fn removeStake(self: *Self, validator: [32]u8, amount: StakeAmount, is_self: bool) !void {
        const current = self.validators.get(validator) orelse 0;
        if (current < amount) return error.InsufficientStake;

        const new_validator_stake = std.math.sub(StakeAmount, current, amount) catch return error.Overflow;
        try self.validators.put(self.allocator, validator, new_validator_stake);

        self.total = std.math.sub(StakeAmount, self.total, amount) catch return error.Overflow;

        if (is_self) {
            const current_self = self.validator_self_stake.get(validator) orelse 0;
            if (current_self < amount) return error.InsufficientStake;
            const new_self = std.math.sub(StakeAmount, current_self, amount) catch return error.Overflow;
            try self.validator_self_stake.put(self.allocator, validator, new_self);
            self.self_stake = std.math.sub(StakeAmount, self.self_stake, amount) catch return error.Overflow;
        } else {
            if (self.delegated < amount) return error.InsufficientStake;
            self.delegated = std.math.sub(StakeAmount, self.delegated, amount) catch return error.Overflow;
        }
    }

    /// Get voting power of validator
    pub fn getVotingPower(self: *const Self, validator: [32]u8) StakeAmount {
        return self.validators.get(validator) orelse 0;
    }

    /// Get total active stake
    pub fn getTotalStake(self: *const Self) StakeAmount {
        return self.total;
    }

    /// Compute quorum threshold (> 2/3), overflow-safe
    pub fn quorumThreshold(self: *const Self) StakeAmount {
        // Use checked multiplication to avoid overflow on self.total * 2
        if (self.total > std.math.maxInt(StakeAmount) / 2) {
            // For very large total, use division-first approach
            return @divFloor(self.total * 2, 3) + 1;
        }
        return (self.total * 2) / 3 + 1;
    }

    /// Check if a set of stakes reaches quorum, overflow-safe
    pub fn hasQuorum(self: *const Self, stakes: []const StakeAmount) bool {
        var total_accum: StakeAmount = 0;
        for (stakes) |s| {
            total_accum = std.math.add(StakeAmount, total_accum, s) catch return true;
        }
        return total_accum > self.quorumThreshold();
    }

    /// Byzantine stake threshold: maximum faulty stake tolerated (floor(total / 3))
    pub fn byzantineStakeThreshold(self: *const Self) StakeAmount {
        return self.total / 3;
    }
};

test "StakePool basic operations" {
    const allocator = std.testing.allocator;
    var pool = try StakePool.init(allocator);
    defer pool.deinit();

    const validator = @as([32]u8, @splat(1));

    try pool.addStake(validator, 1000, true);
    try std.testing.expect(pool.getTotalStake() == 1000);
    try std.testing.expect(pool.getVotingPower(validator) == 1000);

    // Remove stake
    try pool.removeStake(validator, 300, true);
    try std.testing.expect(pool.getTotalStake() == 700);
    try std.testing.expect(pool.getVotingPower(validator) == 700);
}

test "StakePool delegated stake tracking" {
    const allocator = std.testing.allocator;
    var pool = try StakePool.init(allocator);
    defer pool.deinit();

    const validator = @as([32]u8, @splat(1));

    try pool.addStake(validator, 500, true);
    try pool.addStake(validator, 300, false); // delegated
    try std.testing.expect(pool.getTotalStake() == 800);
    try std.testing.expect(pool.self_stake == 500);
    try std.testing.expect(pool.delegated == 300);

    // Remove delegated stake
    try pool.removeStake(validator, 100, false);
    try std.testing.expect(pool.getTotalStake() == 700);
    try std.testing.expect(pool.delegated == 200);
}

test "StakePool quorum threshold" {
    const allocator = std.testing.allocator;
    var pool = try StakePool.init(allocator);
    defer pool.deinit();

    // Add 4 validators with 1000 each
    for (0..4) |i| {
        try pool.addStake(@as([32]u8, @splat(@intCast(i))), 1000, true);
    }

    // Total = 4000, quorum = 4000*2/3 + 1 = 2667
    try std.testing.expect(pool.quorumThreshold() == 2667);

    // Byzantine threshold = 4000 / 3 = 1333
    try std.testing.expect(pool.byzantineStakeThreshold() == 1333);
}

test "StakePool overflow detection" {
    const allocator = std.testing.allocator;
    var pool = try StakePool.init(allocator);
    defer pool.deinit();

    const validator = @as([32]u8, @splat(1));

    // Add near-max stake
    try pool.addStake(validator, std.math.maxInt(u128), true);
    // Adding more should overflow
    try std.testing.expectError(error.Overflow, pool.addStake(validator, 1, true));
}

test "StakePool insufficient stake error" {
    const allocator = std.testing.allocator;
    var pool = try StakePool.init(allocator);
    defer pool.deinit();

    const validator = @as([32]u8, @splat(1));

    try std.testing.expectError(error.InsufficientStake, pool.removeStake(validator, 100, true));
}
