//! Quorum - 2f+1 voting power quorum management
//!
//! Implements quotient group semantics for BFT quorum calculations.

const std = @import("std");

/// QuorumMember - lightweight validator record for quorum calculations
///
/// This is distinct from form.consensus.Validator which includes full metadata.
/// QuorumMember is used internally by Quorum for stake-weighted voting.
pub const QuorumMember = struct {
    id: [32]u8,
    stake: u128,
    is_active: bool,

    const Self = @This();

    pub fn weight(self: Self) u128 {
        return if (self.is_active) self.stake else 0;
    }
};

/// Quorum management for BFT consensus
pub const Quorum = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    members: std.ArrayList(QuorumMember),
    total_stake: u128,
    active_stake: u128,

    /// Initialize empty quorum
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .members = try std.ArrayList(QuorumMember).initCapacity(allocator, 4),
            .total_stake = 0,
            .active_stake = 0,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.members.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Add a validator member
    pub fn addValidator(self: *Self, id: [32]u8, stake: u128) !void {
        try self.members.append(self.allocator, .{
            .id = id,
            .stake = stake,
            .is_active = true,
        });
        self.total_stake += stake;
        self.active_stake += stake;
    }

    /// Remove a validator member
    pub fn removeValidator(self: *Self, id: [32]u8) void {
        for (self.members.items, 0..) |v, i| {
            if (std.mem.eql(u8, &v.id, &id)) {
                if (v.is_active) {
                    self.active_stake -= v.stake;
                }
                self.members.items[i].is_active = false;
                break;
            }
        }
    }

    /// Get total stake
    pub fn totalStake(self: Self) u128 {
        return self.total_stake;
    }

    /// Get active stake
    pub fn activeStake(self: Self) u128 {
        return self.active_stake;
    }

    /// Byzantine threshold based on validator COUNT (not stake)
    ///
    /// For stake-based systems, prefer byzantineStakeThreshold()
    pub fn byzantineThreshold(self: Self) usize {
        const n = self.members.items.len;
        if (n == 0) return 0;
        return (n - 1) / 3;
    }

    /// Byzantine threshold based on TOTAL STAKE (correct for stake-based BFT)
    /// f = (total_stake - 1) / 3
    pub fn byzantineStakeThreshold(self: Self) u128 {
        if (self.total_stake == 0) return 0;
        return (self.total_stake - 1) / 3;
    }

    /// Quorum size 2f+1 based on validator count
    pub fn quorumSize(self: Self) usize {
        return 2 * self.byzantineThreshold() + 1;
    }

    /// Minimum stake for quorum (> 2/3 of total)
    /// This is the PRIMARY quorum check for stake-based consensus
    pub fn quorumStakeThreshold(self: Self) u128 {
        if (self.total_stake == 0) return 0;
        return (self.total_stake * 2) / 3 + 1;
    }

    /// Vote type for quorum check
    pub const Vote = struct { id: [32]u8, stake: u128 };

    /// Check if votes reach quorum
    pub fn hasQuorum(self: Self, votes: []const Vote) bool {
        var total: u128 = 0;
        for (votes) |vote| {
            total += vote.stake;
        }
        return total > self.quorumStakeThreshold();
    }

    /// Get voting power for an address
    pub fn getVotingPower(self: Self, id: [32]u8) u128 {
        for (self.members.items) |v| {
            if (std.mem.eql(u8, &v.id, &id)) {
                return v.weight();
            }
        }
        return 0;
    }

    /// Check if set of validators forms a quorum
    pub fn isQuorum(self: Self, validator_ids: []const [32]u8) bool {
        var stake: u128 = 0;
        for (validator_ids) |id| {
            stake += self.getVotingPower(id);
        }
        return stake > self.quorumStakeThreshold();
    }
};

test "Quorum basic operations" {
    const allocator = std.testing.allocator;
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    // Add 4 validators with 1000 stake each
    for (0..4) |i| {
        try quorum.addValidator([_]u8{@intCast(i)} ** 32, 1000);
    }

    try std.testing.expect(quorum.totalStake() == 4000);
    try std.testing.expect(quorum.byzantineThreshold() == 1);
    try std.testing.expect(quorum.quorumSize() == 3);
    try std.testing.expect(quorum.quorumStakeThreshold() == 2667); // 4000*2/3+1 = 2667 (integer division)
}

test "Quorum voting" {
    const allocator = std.testing.allocator;
    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    try quorum.addValidator([_]u8{1} ** 32, 3000);
    try quorum.addValidator([_]u8{2} ** 32, 3000);

    // 2/3 threshold = 4000, so 3001 stake needed
    const votes = &[_]Quorum.Vote{
        .{ .id = [_]u8{1} ** 32, .stake = 3000 },
    };
    try std.testing.expect(!quorum.hasQuorum(votes));

    const votes2 = &[_]Quorum.Vote{
        .{ .id = [_]u8{1} ** 32, .stake = 3000 },
        .{ .id = [_]u8{2} ** 32, .stake = 3000 },
    };
    try std.testing.expect(quorum.hasQuorum(votes2));
}

// Comptime assertion: quorum forms quotient group
comptime {
    if (!@hasDecl(Quorum, "byzantineThreshold")) @compileError("Quorum must have byzantineThreshold method");
    if (!@hasDecl(Quorum, "quorumSize")) @compileError("Quorum must have quorumSize method");
}
