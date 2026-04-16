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
    validators: std.AutoArrayHashMap([32]u8, StakeAmount),
    /// Delegations
    delegations: std.ArrayList(Delegation),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .total = 0,
            .self_stake = 0,
            .delegated = 0,
            .validators = std.AutoArrayHashMap([32]u8, StakeAmount).init(allocator),
            .delegations = try std.ArrayList(Delegation).initCapacity(allocator, 16),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.validators.deinit();
        self.delegations.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Add stake for a validator
    pub fn addStake(self: *Self, validator: [32]u8, amount: StakeAmount, is_self: bool) !void {
        // Update validator stake
        const current = self.validators.get(validator) orelse 0;
        try self.validators.put(validator, current + amount);

        // Update totals
        self.total += amount;
        if (is_self) {
            self.self_stake += amount;
        } else {
            self.delegated += amount;
        }
    }

    /// Remove stake
    pub fn removeStake(self: *Self, validator: [32]u8, amount: StakeAmount) !void {
        const current = self.validators.get(validator) orelse 0;
        if (current < amount) return error.InsufficientStake;

        try self.validators.put(validator, current - amount);
        self.total -= amount;

        // Check if self or delegated
        // Simplified - assume proportional removal
    }

    /// Get voting power of validator
    pub fn getVotingPower(self: Self, validator: [32]u8) StakeAmount {
        return self.validators.get(validator) orelse 0;
    }

    /// Get total active stake
    pub fn getTotalStake(self: Self) StakeAmount {
        return self.total;
    }

    /// Compute quorum threshold (> 2/3)
    pub fn quorumThreshold(self: Self) StakeAmount {
        return (self.total * 2) / 3 + 1;
    }

    /// Check if a set of stakes reaches quorum
    pub fn hasQuorum(self: Self, stakes: []const StakeAmount) bool {
        var total: StakeAmount = 0;
        for (stakes) |s| total += s;
        return total > self.quorumThreshold();
    }
};

test "StakePool basic operations" {
    const allocator = std.testing.allocator;
    var pool = try StakePool.init(allocator);
    defer pool.deinit();

    const validator = [_]u8{1} ** 32;

    try pool.addStake(validator, 1000, true);
    try std.testing.expect(pool.getTotalStake() == 1000);
    try std.testing.expect(pool.getVotingPower(validator) == 1000);
}

test "StakePool quorum threshold" {
    const allocator = std.testing.allocator;
    var pool = try StakePool.init(allocator);
    defer pool.deinit();

    // Add 4 validators with 1000 each
    for (0..4) |i| {
        try pool.addStake([_]u8{@intCast(i)} ** 32, 1000, true);
    }

    // Total = 4000, quorum = 4000*2/3 + 1 = 2667
    try std.testing.expect(pool.quorumThreshold() == 2667);
}
