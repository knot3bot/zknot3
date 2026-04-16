//! Epoch - Epoch management for periodic reconfiguration

const std = @import("std");

/// Epoch configuration
pub const EpochConfig = struct {
    /// Duration of epoch in seconds
    duration_seconds: u64 = 86400, // 24 hours
    /// Minimum number of validators
    min_validators: usize = 4,
    /// Maximum validators
    max_validators: usize = 100,
};

/// Epoch state
pub const Epoch = struct {
    const Self = @This();

    /// Epoch number
    number: u64,
    /// Start timestamp
    start_time: i64,
    /// End timestamp
    end_time: i64,
    /// Total stake at epoch start
    total_stake: u128,
    /// Validator count
    validator_count: usize,
    /// Is finalized
    finalized: bool,

    /// Create new epoch
    pub fn create(number: u64, start_time: i64, duration: u64, total_stake: u128, validator_count: usize) Self {
        return .{
            .number = number,
            .start_time = start_time,
            .end_time = start_time + @as(i64, @intCast(duration)),
            .total_stake = total_stake,
            .validator_count = validator_count,
            .finalized = false,
        };
    }

    /// Check if epoch is active at given time
    pub fn isActive(self: Self, current_time: i64) bool {
        return current_time >= self.start_time and current_time < self.end_time;
    }

    /// Check if epoch has ended
    pub fn hasEnded(self: Self, current_time: i64) bool {
        return current_time >= self.end_time;
    }

    /// Get remaining duration
    pub fn remainingDuration(self: Self, current_time: i64) i64 {
        if (current_time >= self.end_time) return 0;
        return self.end_time - current_time;
    }

    /// Finalize epoch
    pub fn finalize(self: *Self) void {
        self.finalized = true;
    }
};

/// Epoch manager
pub const EpochManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: EpochConfig,
    current_epoch: Epoch,
    epoch_history: std.ArrayList(Epoch),

    pub fn init(allocator: std.mem.Allocator, config: EpochConfig, current_time: i64) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .current_epoch = Epoch.create(0, current_time, config.duration_seconds, 0, 0),
            .epoch_history = try std.ArrayList(Epoch).initCapacity(allocator, 16),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.epoch_history.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Advance to next epoch
    pub fn advanceEpoch(self: *Self, total_stake: u128, validator_count: usize) !void {
        // Archive current epoch
        var current = self.current_epoch;
        current.finalize();
        try self.epoch_history.append(self.allocator, current);

        // Create new epoch
        const new_number = current.number + 1;
        self.current_epoch = Epoch.create(
            new_number,
            current.end_time,
            self.config.duration_seconds,
            total_stake,
            validator_count,
        );
    }

    /// Get current epoch
    pub fn getCurrentEpoch(self: Self) Epoch {
        return self.current_epoch;
    }

    /// Check if reconfiguration is needed
    pub fn needsReconfiguration(self: Self) bool {
        return self.current_epoch.validator_count < self.config.min_validators or
            self.current_epoch.validator_count > self.config.max_validators;
    }
};

test "Epoch creation" {
    const epoch = Epoch.create(1, 1000, 86400, 4000, 4);

    try std.testing.expect(epoch.number == 1);
    try std.testing.expect(epoch.start_time == 1000);
    try std.testing.expect(epoch.end_time == 87400);
    try std.testing.expect(!epoch.finalized);
}

test "Epoch is active" {
    const epoch = Epoch.create(1, 1000, 86400, 4000, 4);

    try std.testing.expect(epoch.isActive(5000));
    try std.testing.expect(!epoch.isActive(90000));
    try std.testing.expect(epoch.hasEnded(90000));
}

test "Epoch manager" {
    const allocator = std.testing.allocator;
    var manager = try EpochManager.init(allocator, .{}, 1000);
    defer manager.deinit();

    const epoch = manager.getCurrentEpoch();
    try std.testing.expect(epoch.number == 0);

    try manager.advanceEpoch(5000, 4);
    const new_epoch = manager.getCurrentEpoch();
    try std.testing.expect(new_epoch.number == 1);
}
