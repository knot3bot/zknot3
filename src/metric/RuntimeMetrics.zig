//! Runtime Metrics - Actual system measurement for tri-source metrics
//!
//! Implements runtime collection of:
//! - 物丰 (wu_feng): CPU, memory, storage efficiency
//! - 象大 (xiang_da): Transaction diversity, object coverage
//! - 性自在 (zi_zai): Latency, throughput from user perspective

const std = @import("std");
pub const TriSourceMetrics = TriSourceMetricsType;

/// Re-export TriSourceMetrics from metrics.zig
const TriSourceMetricsType = @import("Metrics.zig").TriSourceMetrics;

/// System resource measurements
pub const ResourceMetrics = struct {
    const Self = @This();

    /// CPU utilization [0-1]
    cpu_util: f64,
    /// Memory utilization [0-1]
    mem_util: f64,
    /// Storage I/O utilization [0-1]
    storage_util: f64,
    /// Network bandwidth utilization [0-1]
    network_util: f64,

    /// Compute 物丰 (wu_feng) - resource efficiency
    pub fn computeWuFeng(self: Self) f64 {
        // Weighted geometric mean emphasizing balanced resource usage
        const product = self.cpu_util * self.mem_util * self.storage_util * self.network_util;
        const geo_mean = std.math.pow(f64, product, 1.0 / 4.0);

        // Penalize imbalance (one resource saturated while others idle)
        const max_util = @max(self.cpu_util, self.mem_util, self.storage_util, self.network_util);
        const min_util = @min(self.cpu_util, self.mem_util, self.storage_util, self.network_util);
        const imbalance_penalty = if (max_util > 0) min_util / max_util else 1.0;

        return geo_mean * (0.7 + 0.3 * imbalance_penalty);
    }
};

/// Knowledge/graph coverage measurements
pub const KnowledgeMetrics = struct {
    const Self = @This();

    /// Unique object types observed
    unique_types: usize,
    /// Total object count
    total_objects: usize,
    /// Unique transactions types
    unique_tx_types: usize,
    /// Total transactions processed
    total_transactions: usize,
    /// Ownership diversity (Shannon entropy)
    ownership_entropy: f64,

    /// Compute 象大 (xiang_da) - knowledge coverage
    pub fn computeXiangDa(self: Self) f64 {
        // Type coverage: fraction of known types observed
        const max_types: f64 = 1000; // Assumed maximum type space
        const type_coverage = @min(1.0, @as(f64, @floatFromInt(self.unique_types)) / max_types);

        // Object diversity: how distributed are objects across types
        const object_diversity = if (self.total_objects > 0)
            1.0 - @abs(1.0 - @as(f64, @floatFromInt(self.unique_types)) / @as(f64, @floatFromInt(@max(1, self.total_objects))))
        else
            0.0;

        // Transaction coverage
        const max_tx_types: f64 = 100;
        const tx_coverage = @min(1.0, @as(f64, @floatFromInt(self.unique_tx_types)) / max_tx_types);

        // Weighted combination
        return 0.4 * type_coverage + 0.3 * object_diversity + 0.3 * tx_coverage;
    }
};

/// User satisfaction measurements
pub const UserMetrics = struct {
    const Self = @This();

    /// P50 latency in milliseconds
    latency_p50: f64,
    /// P99 latency in milliseconds
    latency_p99: f64,
    /// Throughput in transactions per second
    tps: f64,
    /// Target TPS
    target_tps: f64,
    /// Error rate [0-1]
    error_rate: f64,
    /// User-reported satisfaction [0-1]
    user_satisfaction: f64,

    /// Compute 性自在 (zi_zai) - user satisfaction
    pub fn computeZiZai(self: Self) f64 {
        // Latency score: lower is better
        const latency_score = if (self.latency_p99 < 100)
            1.0 - (self.latency_p99 / 1000.0) // Normalize to [0, 1]
        else
            0.0;

        // Throughput score: how close to target
        const tps_score = if (self.target_tps > 0)
            @min(1.0, self.tps / self.target_tps)
        else
            1.0;

        // Reliability score: inverse of error rate
        const reliability_score = 1.0 - self.error_rate;

        // Weighted combination
        return 0.35 * latency_score + 0.35 * tps_score + 0.30 * reliability_score;
    }
};

/// Runtime metrics collector with actual measurement
pub const RuntimeMetricsCollector = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// Resource metrics history
    resource_history: std.ArrayList(ResourceMetrics),
    /// Knowledge metrics history
    knowledge_history: std.ArrayList(KnowledgeMetrics),
    /// User metrics history
    user_history: std.ArrayList(UserMetrics),

    /// Window size for rolling averages
    window_size: usize,

    /// Current metrics (updated in real-time)
    current_resource: ResourceMetrics,
    current_knowledge: KnowledgeMetrics,
    current_user: UserMetrics,

    pub fn init(allocator: std.mem.Allocator, window_size: usize) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .resource_history = std.ArrayList(ResourceMetrics){},
            .knowledge_history = std.ArrayList(KnowledgeMetrics){},
            .user_history = std.ArrayList(UserMetrics){},
            .window_size = window_size,
            .current_resource = .{ .cpu_util = 0, .mem_util = 0, .storage_util = 0, .network_util = 0 },
            .current_knowledge = .{ .unique_types = 0, .total_objects = 0, .unique_tx_types = 0, .total_transactions = 0, .ownership_entropy = 0 },
            .current_user = .{ .latency_p50 = 0, .latency_p99 = 0, .tps = 0, .target_tps = 10000, .error_rate = 0, .user_satisfaction = 1.0 },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.resource_history.deinit(self.allocator);
        self.knowledge_history.deinit(self.allocator);
        self.user_history.deinit(self.allocator);
    }

    /// Update current resource metrics
    pub fn updateResource(self: *Self, metrics: ResourceMetrics) !void {
        self.current_resource = metrics;
        try self.resource_history.append(self.allocator, metrics);
        while (self.resource_history.items.len > self.window_size) {
            _ = self.resource_history.orderedRemove(0);
        }
    }

    /// Update current knowledge metrics
    pub fn updateKnowledge(self: *Self, metrics: KnowledgeMetrics) !void {
        self.current_knowledge = metrics;
        try self.knowledge_history.append(self.allocator, metrics);
        while (self.knowledge_history.items.len > self.window_size) {
            _ = self.knowledge_history.orderedRemove(0);
        }
    }

    /// Update current user metrics
    pub fn updateUser(self: *Self, metrics: UserMetrics) !void {
        self.current_user = metrics;
        try self.user_history.append(self.allocator, metrics);
        while (self.user_history.items.len > self.window_size) {
            _ = self.user_history.orderedRemove(0);
        }
    }

    /// Get current tri-source metrics
    pub fn getTriSource(self: Self) TriSourceMetrics {
        return .{
            .wu_feng = self.current_resource.computeWuFeng(),
            .xiang_da = self.current_knowledge.computeXiangDa(),
            .zi_zai = self.current_user.computeZiZai(),
        };
    }

    /// Get rolling average tri-source metrics
    pub fn getAverageTriSource(self: Self) TriSourceMetrics {
        if (self.resource_history.items.len == 0) {
            return self.getTriSource();
        }

        var total_wu_feng: f64 = 0;
        var total_xiang_da: f64 = 0;
        var total_zi_zai: f64 = 0;

        for (self.resource_history.items) |r| {
            total_wu_feng += r.computeWuFeng();
        }
        for (self.knowledge_history.items) |k| {
            total_xiang_da += k.computeXiangDa();
        }
        for (self.user_history.items) |u| {
            total_zi_zai += u.computeZiZai();
        }

        const count = @as(f64, @floatFromInt(self.resource_history.items.len));
        return .{
            .wu_feng = total_wu_feng / count,
            .xiang_da = total_xiang_da / count,
            .zi_zai = total_zi_zai / count,
        };
    }

    /// Check if system is healthy based on tri-source metrics
    pub fn isHealthy(self: Self, threshold: f64) bool {
        const metrics = self.getTriSource();
        return metrics.isHealthy(threshold);
    }
};

/// Simulated metrics generator for testing
pub const MetricsSimulator = struct {
    const Self = @This();

    rng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Self {
        return .{ .rng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn randomResource(self: *Self) ResourceMetrics {
        return .{
            .cpu_util = self.rng.random().float(f64) * 0.8 + 0.1,
            .mem_util = self.rng.random().float(f64) * 0.7 + 0.1,
            .storage_util = self.rng.random().float(f64) * 0.5 + 0.1,
            .network_util = self.rng.random().float(f64) * 0.6 + 0.1,
        };
    }

    /// Generate random knowledge metrics
    pub fn randomKnowledge(self: *Self) KnowledgeMetrics {
        const random = self.rng.random();
        return .{
            .unique_types = random.uintAtMost(usize, 500),
            .total_objects = random.uintAtMost(usize, 10000),
            .unique_tx_types = random.uintAtMost(usize, 50),
            .total_transactions = random.uintAtMost(usize, 100000),
            .ownership_entropy = random.float(f64) * 4.0, // Max entropy for 16 owners
        };
    }

    /// Generate random user metrics
    pub fn randomUser(self: *Self) UserMetrics {
        const random = self.rng.random();
        return .{
            .latency_p50 = random.float(f64) * 50 + 10, // 10-60ms
            .latency_p99 = random.float(f64) * 200 + 50, // 50-250ms
            .tps = random.float(f64) * 8000 + 2000, // 2000-10000
            .target_tps = 10000,
            .error_rate = random.float(f64) * 0.05, // 0-5%
            .user_satisfaction = random.float(f64) * 0.3 + 0.7, // 0.7-1.0
        };
    }
};

test "ResourceMetrics: computeWuFeng" {
    const metrics = ResourceMetrics{
        .cpu_util = 0.8,
        .mem_util = 0.7,
        .storage_util = 0.6,
        .network_util = 0.5,
    };

    const wu_feng = metrics.computeWuFeng();
    try std.testing.expect(wu_feng > 0);
    try std.testing.expect(wu_feng <= 1);
}

test "KnowledgeMetrics: computeXiangDa" {
    const metrics = KnowledgeMetrics{
        .unique_types = 100,
        .total_objects = 1000,
        .unique_tx_types = 20,
        .total_transactions = 50000,
        .ownership_entropy = 2.5,
    };

    const xiang_da = metrics.computeXiangDa();
    try std.testing.expect(xiang_da > 0);
    try std.testing.expect(xiang_da <= 1);
}

test "UserMetrics: computeZiZai" {
    const metrics = UserMetrics{
        .latency_p50 = 20,
        .latency_p99 = 80,
        .tps = 8000,
        .target_tps = 10000,
        .error_rate = 0.01,
        .user_satisfaction = 0.9,
    };

    const zi_zai = metrics.computeZiZai();
    try std.testing.expect(zi_zai > 0);
    try std.testing.expect(zi_zai <= 1);
}

test "RuntimeMetricsCollector: getTriSource" {
    const allocator = std.testing.allocator;
    var collector = try RuntimeMetricsCollector.init(allocator, 100);
    defer collector.deinit();

    try collector.updateResource(.{ .cpu_util = 0.8, .mem_util = 0.7, .storage_util = 0.6, .network_util = 0.5 });
    try collector.updateKnowledge(.{ .unique_types = 100, .total_objects = 1000, .unique_tx_types = 20, .total_transactions = 50000, .ownership_entropy = 2.5 });
    try collector.updateUser(.{ .latency_p50 = 20, .latency_p99 = 80, .tps = 8000, .target_tps = 10000, .error_rate = 0.01, .user_satisfaction = 0.9 });

    const tri = collector.getTriSource();
    try std.testing.expect(tri.wu_feng > 0);
    try std.testing.expect(tri.xiang_da > 0);
    try std.testing.expect(tri.zi_zai > 0);
}

test "MetricsSimulator: generate random metrics" {
    var sim = MetricsSimulator.init(42);

    const resource = sim.randomResource();
    try std.testing.expect(resource.cpu_util > 0 and resource.cpu_util <= 1);

    const knowledge = sim.randomKnowledge();
    try std.testing.expect(knowledge.total_objects >= knowledge.unique_types);

    const user = sim.randomUser();
    try std.testing.expect(user.latency_p99 > user.latency_p50);
}
