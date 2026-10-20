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
        const sum = @as(i128, start_time) + @as(i128, duration);
        const end_time: i64 = if (sum > std.math.maxInt(i64))
            std.math.maxInt(i64)
        else if (sum < std.math.minInt(i64))
            std.math.minInt(i64)
        else
            @intCast(sum);
        return .{
            .number = number,
            .start_time = start_time,
            .end_time = end_time,
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
        const remaining = @as(i128, self.end_time) - @as(i128, current_time);
        if (remaining > std.math.maxInt(i64)) return std.math.maxInt(i64);
        return @intCast(remaining);
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
    on_epoch_advanced: ?*const fn (ctx: *anyopaque, previous: Epoch, current: Epoch) anyerror!void = null,
    on_epoch_advanced_ctx: ?*anyopaque = null,

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
        const new_number = std.math.add(u64, self.current_epoch.number, 1) catch return error.ArithmeticOverflow;

        // Archive current epoch
        var current = self.current_epoch;
        current.finalize();
        try self.epoch_history.append(self.allocator, current);

        // Create new epoch
        self.current_epoch = Epoch.create(
            new_number,
            current.end_time,
            self.config.duration_seconds,
            total_stake,
            validator_count,
        );

        if (self.on_epoch_advanced) |cb| {
            const hook_ctx = self.on_epoch_advanced_ctx orelse return error.InvalidState;
            try cb(hook_ctx, current, self.current_epoch);
        }
    }

    /// Bind consensus/security hook on epoch transition.
    pub fn setEpochAdvanceHook(
        self: *Self,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, previous: Epoch, current: Epoch) anyerror!void,
    ) void {
        self.on_epoch_advanced_ctx = ctx;
        self.on_epoch_advanced = cb;
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

test "Epoch end time and remaining duration saturate at the i64 limit" {
    const near_end = Epoch.create(1, std.math.maxInt(i64) - 10, 100, 0, 1);
    try std.testing.expectEqual(std.math.maxInt(i64), near_end.end_time);

    const huge = Epoch.create(1, 0, std.math.maxInt(u64), 0, 1);
    try std.testing.expectEqual(std.math.maxInt(i64), huge.end_time);

    const wide = Epoch.create(1, std.math.maxInt(i64), 0, 0, 1);
    try std.testing.expectEqual(std.math.maxInt(i64), wide.remainingDuration(std.math.minInt(i64)));

    const normal = Epoch.create(1, 1000, 86400, 0, 1);
    try std.testing.expectEqual(@as(i64, 86400), normal.remainingDuration(1000));
}

test "Epoch advance refuses to wrap the epoch number" {
    const allocator = std.testing.allocator;
    var manager = try EpochManager.init(allocator, .{}, 1000);
    defer manager.deinit();
    manager.current_epoch.number = std.math.maxInt(u64);
    try std.testing.expectError(error.ArithmeticOverflow, manager.advanceEpoch(1, 1));
    try std.testing.expectEqual(std.math.maxInt(u64), manager.current_epoch.number);
    try std.testing.expectEqual(@as(usize, 0), manager.epoch_history.items.len);
}

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

test "Epoch manager calls advance hook" {
    const allocator = std.testing.allocator;
    var manager = try EpochManager.init(allocator, .{}, 1000);
    defer manager.deinit();

    const HookCtx = struct {
        called: bool = false,
        previous_epoch: u64 = 0,
        current_epoch: u64 = 0,
    };
    var ctx = HookCtx{};
    const hook = struct {
        fn call(raw: *anyopaque, previous: Epoch, current: Epoch) anyerror!void {
            const typed = @as(*HookCtx, @ptrCast(@alignCast(raw)));
            typed.called = true;
            typed.previous_epoch = previous.number;
            typed.current_epoch = current.number;
        }
    }.call;
    manager.setEpochAdvanceHook(&ctx, hook);

    try manager.advanceEpoch(5000, 4);
    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(@as(u64, 0), ctx.previous_epoch);
    try std.testing.expectEqual(@as(u64, 1), ctx.current_epoch);
}

// Phase 0: epoch transition consistency and replay verification
test "Epoch transition consistency: history, stake, validator count" {
    const allocator = std.testing.allocator;
    var manager = try EpochManager.init(allocator, .{
        .duration_seconds = 3600,
        .min_validators = 4,
        .max_validators = 100,
    }, 1000);
    defer manager.deinit();

    // Initial epoch
    const e0 = manager.getCurrentEpoch();
    try std.testing.expectEqual(@as(u64, 0), e0.number);
    try std.testing.expectEqual(@as(u128, 0), e0.total_stake);
    try std.testing.expectEqual(@as(usize, 0), e0.validator_count);

    // Advance to epoch 1
    try manager.advanceEpoch(10_000, 4);
    const e1 = manager.getCurrentEpoch();
    try std.testing.expectEqual(@as(u64, 1), e1.number);
    try std.testing.expectEqual(@as(u128, 10_000), e1.total_stake);
    try std.testing.expectEqual(@as(usize, 4), e1.validator_count);

    // Advance to epoch 2 with new stake distribution
    try manager.advanceEpoch(15_000, 5);
    const e2 = manager.getCurrentEpoch();
    try std.testing.expectEqual(@as(u64, 2), e2.number);
    try std.testing.expectEqual(@as(u128, 15_000), e2.total_stake);
    try std.testing.expectEqual(@as(usize, 5), e2.validator_count);

    // History replay: verify archived epochs are finalized and sequential
    try std.testing.expectEqual(@as(usize, 2), manager.epoch_history.items.len);
    try std.testing.expect(manager.epoch_history.items[0].finalized);
    try std.testing.expect(manager.epoch_history.items[1].finalized);
    try std.testing.expectEqual(@as(u64, 0), manager.epoch_history.items[0].number);
    try std.testing.expectEqual(@as(u64, 1), manager.epoch_history.items[1].number);
    try std.testing.expectEqual(@as(i64, 1000 + 3600), manager.epoch_history.items[1].start_time);

    // Reconfiguration detection
    try std.testing.expect(!manager.needsReconfiguration());
}

test "Epoch boundary reconfiguration detection" {
    const allocator = std.testing.allocator;
    var manager = try EpochManager.init(allocator, .{
        .duration_seconds = 3600,
        .min_validators = 4,
        .max_validators = 10,
    }, 1000);
    defer manager.deinit();

    try manager.advanceEpoch(1000, 3); // below min
    try std.testing.expect(manager.needsReconfiguration());

    try manager.advanceEpoch(1000, 11); // above max
    try std.testing.expect(manager.needsReconfiguration());

    try manager.advanceEpoch(1000, 5); // within range
    try std.testing.expect(!manager.needsReconfiguration());
}
