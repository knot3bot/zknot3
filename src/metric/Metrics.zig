//! Metrics - Tri-source metrics (三源指标)
//!
//! Implements the 三源合恰 framework:
//! - 物丰 (wu_feng): Resource efficiency (0-1)
//! - 象大 (xiang_da): Knowledge coverage (0-1)
//! - 性自在 (zi_zai): User satisfaction (0-1)

const std = @import("std");

/// Tri-source metrics container
pub const TriSourceMetrics = struct {
    const Self = @This();

    /// 物丰: Resource utilization efficiency (0-1)
    wu_feng: f64,
    /// 象大: Knowledge/graph coverage (0-1)
    xiang_da: f64,
    /// 性自在: User satisfaction/freedom (0-1)
    zi_zai: f64,

    /// Initialize with default values
    pub fn init() Self {
        return .{
            .wu_feng = 0.0,
            .xiang_da = 0.0,
            .zi_zai = 0.0,
        };
    }

    /// Check if all metrics are above threshold
    pub fn isHealthy(self: Self, threshold: f64) bool {
        return self.wu_feng >= threshold and
            self.xiang_da >= threshold and
            self.zi_zai >= threshold;
    }

    /// Compute Pareto score (multi-objective optimization)
    pub fn paretoScore(self: Self) f64 {
        // Geometric mean of three metrics
        const product = self.wu_feng * self.xiang_da * self.zi_zai;
        return std.math.pow(f64, product, 1.0 / 3.0);
    }

    /// Compute gradient for optimization
    pub fn computeGradient(self: Self, target: Self) Self {
        return .{
            .wu_feng = target.wu_feng - self.wu_feng,
            .xiang_da = target.xiang_da - self.xiang_da,
            .zi_zai = target.zi_zai - self.zi_zai,
        };
    }

    /// Adjust metrics by gradient step
    pub fn adjust(self: *Self, gradient: Self, step_size: f64) void {
        self.wu_feng += gradient.wu_feng * step_size;
        self.xiang_da += gradient.xiang_da * step_size;
        self.zi_zai += gradient.zi_zai * step_size;

        // Clamp to [0, 1]
        self.wu_feng = @max(0.0, @min(1.0, self.wu_feng));
        self.xiang_da = @max(0.0, @min(1.0, self.xiang_da));
        self.zi_zai = @max(0.0, @min(1.0, self.zi_zai));
    }

    /// Get minimum of all metrics
    pub fn minimum(self: Self) f64 {
        return @min(self.wu_feng, @min(self.xiang_da, self.zi_zai));
    }
};

/// Metrics collector for runtime monitoring
pub const MetricsCollector = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Historical metrics
    history: std.ArrayList(TriSourceMetrics),
    /// Window size for rolling average
    window_size: usize,

    pub fn init(allocator: std.mem.Allocator, window_size: usize) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .history = std.ArrayList(TriSourceMetrics).empty,
            .window_size = window_size,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.history.deinit(self.allocator);
    }

    /// Record a metrics snapshot
    pub fn record(self: *Self, metrics: TriSourceMetrics) !void {
        try self.history.append(self.allocator, metrics);

        // Trim history if too long
        while (self.history.items.len > self.window_size) {
            _ = self.history.orderedRemove(0);
        }
    }

    /// Get rolling average
    pub fn average(self: Self) TriSourceMetrics {
        if (self.history.items.len == 0) {
            return TriSourceMetrics.init();
        }

        var sum = TriSourceMetrics.init();
        for (self.history.items) |m| {
            sum.wu_feng += m.wu_feng;
            sum.xiang_da += m.xiang_da;
            sum.zi_zai += m.zi_zai;
        }

        const count = @as(f64, @floatFromInt(self.history.items.len));
        return .{
            .wu_feng = sum.wu_feng / count,
            .xiang_da = sum.xiang_da / count,
            .zi_zai = sum.zi_zai / count,
        };
    }

    /// Get latest metrics
    pub fn latest(self: Self) ?TriSourceMetrics {
        return self.history.items.last;
    }

    /// Check if recent metrics are healthy
    pub fn isRecentlyHealthy(self: Self, threshold: f64) bool {
        if (self.history.items.len == 0) return false;

        // Check last N metrics
        const count = @min(self.history.items.len, 5);
        for (self.history.items[self.history.items.len - count ..]) |m| {
            if (!m.isHealthy(threshold)) return false;
        }
        return true;
    }
};

test "TriSourceMetrics basic" {
    const metrics = TriSourceMetrics{
        .wu_feng = 0.9,
        .xiang_da = 0.8,
        .zi_zai = 0.7,
    };

    try std.testing.expect(metrics.minimum() == 0.7);
    try std.testing.expect(metrics.isHealthy(0.6));
    try std.testing.expect(!metrics.isHealthy(0.8));
}

test "TriSourceMetrics Pareto score" {
    const metrics = TriSourceMetrics{
        .wu_feng = 0.9,
        .xiang_da = 0.9,
        .zi_zai = 0.9,
    };

    const score = metrics.paretoScore();
    try std.testing.expect(score > 0.89);
}

test "MetricsCollector" {
    const allocator = std.testing.allocator;
    var collector = try MetricsCollector.init(allocator, 10);
    defer {
        collector.deinit();
        allocator.destroy(collector);
    }

    try collector.record(.{ .wu_feng = 0.8, .xiang_da = 0.8, .zi_zai = 0.8 });
    try collector.record(.{ .wu_feng = 0.9, .xiang_da = 0.9, .zi_zai = 0.9 });

    const avg = collector.average();
    try std.testing.expect(avg.wu_feng > 0.84);
    try std.testing.expect(avg.wu_feng < 0.86);
}
