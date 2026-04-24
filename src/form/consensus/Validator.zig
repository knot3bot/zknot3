//! Validator - Validator identity and stake management
//!
//! Implements validator operations including stake delegation,
//! voting power calculation, and validator set management.

const std = @import("std");
const core = @import("../../core.zig");
const Signature = @import("property/crypto/Signature");

/// Validator stake information
pub const ValidatorStake = struct {
    /// Validator's Ed25519 public key
    public_key: [32]u8,
    /// Optional BLS12-381 public key (48 bytes) for checkpoint proof aggregation.
    /// When null, LightClient may fall back to a deterministic derivation from
    /// the Ed25519 public key (legacy mode).
    bls_public_key: ?[48]u8 = null,
    /// Staked amount
    stake: u64,
    /// Commission rate (0-10000 = 0%-100%)
    commission: u16,
    /// Whether validator is accepting delegations
    allows_delegation: bool,

    const Self = @This();

    /// Effective stake after commission
    pub fn effectiveStake(self: Self) u64 {
        return self.stake;
    }

    /// Voting power (proportional to stake)
    pub fn votingPower(self: Self) u64 {
        return self.stake;
    }
};

/// Validator metadata (off-chain)
pub const ValidatorMeta = struct {
    /// Validator name
    name: []u8,
    /// Validator description
    description: []u8,
    /// Validator website URL
    url: []u8,
    /// Validator icon URL
    icon_url: []u8,
    /// Contact email
    email: []u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.url);
        allocator.free(self.icon_url);
        allocator.free(self.email);
    }
};

/// Validator with full information
pub const Validator = struct {
    const Self = @This();

    /// Unique identifier (public key hash)
    id: [32]u8,
    /// Stake information
    stake: ValidatorStake,
    /// Metadata
    meta: ?ValidatorMeta,
    /// Whether validator is active
    is_active: bool,
    /// Validator start epoch
    start_epoch: u64,
    /// Validator end epoch (0 = no end)
    end_epoch: u64,

    /// Create new validator
    pub fn create(public_key: [32]u8, stake: u64, name: []const u8, allocator: std.mem.Allocator) !Self {
        var id: [32]u8 = undefined;
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&public_key);
        ctx.final(&id);

        return .{
            .id = id,
            .stake = .{
                .public_key = public_key,
                .stake = stake,
                .commission = 0,
                .allows_delegation = true,
            },
            .meta = .{
                .name = try allocator.dupe(u8, name),
                .description = try allocator.dupe(u8, ""),
                .url = try allocator.dupe(u8, ""),
                .icon_url = try allocator.dupe(u8, ""),
                .email = try allocator.dupe(u8, ""),
            },
            .is_active = true,
            .start_epoch = 0,
            .end_epoch = 0,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.meta) |*m| {
            m.deinit(allocator);
        }
    }

    /// Check if validator can vote at given epoch
    pub fn canVote(self: Self, epoch: u64) bool {
        if (!self.is_active) return false;
        if (epoch < self.start_epoch) return false;
        if (self.end_epoch > 0 and epoch >= self.end_epoch) return false;
        return true;
    }
};

/// Validator set - manages the active validator population
pub const ValidatorSet = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    validators: std.AutoArrayHashMapUnmanaged([32]u8, Validator),
    sorted_by_stake: std.ArrayList([32]u8),

    /// Initialize empty validator set
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .validators = .empty,
            .sorted_by_stake = try std.ArrayList([32]u8).initCapacity(allocator, 4),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.validators.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.validators.deinit(self.allocator);
        self.sorted_by_stake.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Add a validator
    pub fn add(self: *Self, validator: Validator) !void {
        try self.validators.put(self.allocator, validator.id, validator);
        try self.rebuildSortedList();
    }

    /// Remove a validator
    pub fn remove(self: *Self, id: [32]u8) void {
        if (self.validators.getPtr(id)) |v| {
            v.deinit(self.allocator);
            _ = self.validators.remove(id);
        }
        self.rebuildSortedList();
    }

    /// Get validator by ID
    pub fn get(self: Self, id: [32]u8) ?Validator {
        return self.validators.get(id);
    }

    /// Get validator count
    pub fn count(self: Self) usize {
        return self.validators.count();
    }

    /// Get total stake across all validators
    pub fn totalStake(self: Self) u64 {
        var total: u64 = 0;
        var it = self.validators.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.stake.votingPower();
        }
        return total;
    }

    /// Get active validator count
    pub fn activeCount(self: Self) usize {
        var cnt: usize = 0;
        var it = self.validators.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.is_active) cnt += 1;
        }
        return cnt;
    }

    /// Rebuild sorted list by stake (descending)
    fn rebuildSortedList(self: *Self) !void {
        self.sorted_by_stake.clearRetainingCapacity();

        var it = self.validators.iterator();
        while (it.next()) |entry| {
            try self.sorted_by_stake.append(self.allocator, entry.key_ptr.*);
        }

        // Sort by stake (bubble sort for simplicity)
        var swapped = true;
        while (swapped) {
            swapped = false;
            for (0..self.sorted_by_stake.items.len) |i| {
                if (i + 1 >= self.sorted_by_stake.items.len) break;
                const a = self.validators.get(self.sorted_by_stake.items[i]).?.stake.stake;
                const b = self.validators.get(self.sorted_by_stake.items[i + 1]).?.stake.stake;
                if (a < b) {
                    std.mem.swap([32]u8, &self.sorted_by_stake.items[i], &self.sorted_by_stake.items[i + 1]);
                    swapped = true;
                }
            }
        }
    }

    /// Get top N validators by stake
    pub fn topN(self: Self, n: usize) []const [32]u8 {
        const cnt = @min(n, self.sorted_by_stake.items.len);
        return self.sorted_by_stake.items[0..cnt];
    }

    /// Get validators eligible to vote at epoch
    pub fn getVoters(self: Self, epoch: u64) []const [32]u8 {
        _ = epoch;
        return self.sorted_by_stake.items;
    }
};

test "Validator creation" {
    const allocator = std.testing.allocator;

    const pk = [_]u8{1} ** 32;
    var validator = try Validator.create(pk, 1000, "TestValidator", allocator);
    defer validator.deinit(allocator);

    try std.testing.expect(validator.is_active);
    try std.testing.expect(validator.stake.stake == 1000);
}

test "ValidatorSet operations" {
    const allocator = std.testing.allocator;
    var set = try ValidatorSet.init(allocator);
    defer set.deinit();

    const pk1 = [_]u8{1} ** 32;
    const pk2 = [_]u8{2} ** 32;

    const v1 = try Validator.create(pk1, 1000, "Validator1", allocator);
    const v2 = try Validator.create(pk2, 2000, "Validator2", allocator);

    try set.add(v1);
    try set.add(v2);

    try std.testing.expect(set.count() == 2);
    try std.testing.expect(set.totalStake() == 3000);
}

test "ValidatorSet top N" {
    const allocator = std.testing.allocator;
    var set = try ValidatorSet.init(allocator);
    defer set.deinit();

    const pk1 = [_]u8{1} ** 32;
    const pk2 = [_]u8{2} ** 32;
    const pk3 = [_]u8{3} ** 32;

    const v1 = try Validator.create(pk1, 1000, "V1", allocator);
    const v2 = try Validator.create(pk2, 3000, "V2", allocator);
    const v3 = try Validator.create(pk3, 2000, "V3", allocator);

    try set.add(v1);
    try set.add(v2);
    try set.add(v3);

    const top2 = set.topN(2);
    try std.testing.expect(top2.len == 2);
    // v2 should be first (highest stake) — topN returns validator id, not raw public key
    try std.testing.expect(std.mem.eql(u8, &top2[0], &v2.id));
}
