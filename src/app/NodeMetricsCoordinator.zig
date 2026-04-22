//! NodeMetricsCoordinator - metric aggregation helpers for Node

const std = @import("std");
const ExecutionResult = @import("../pipeline/Executor.zig").ExecutionResult;

pub const ExecutionSummary = struct {
    successful: u64,
    total: u64,
};

pub const ExecutorStats = struct {
    transactions_executed: u64,
    total_gas_used: u64,
    parallelism: usize,
};

pub fn currentUnixSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

pub fn computeUptimeSeconds(started_at: i64) i64 {
    return currentUnixSeconds() - started_at;
}

pub fn computeNetworkUtil(peer_count: usize, max_peers: usize) f64 {
    if (max_peers == 0) return 0.0;
    return @min(1.0, @as(f64, @floatFromInt(peer_count)) / @as(f64, @floatFromInt(max_peers)));
}

pub fn computeStorageUtil(execution_results_count: usize) f64 {
    return @min(1.0, @as(f64, @floatFromInt(execution_results_count)) / 10000.0);
}

pub fn summarizeExecutionResults(execution_results: *const std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult)) ExecutionSummary {
    var successful: u64 = 0;
    var total: u64 = 0;
    var it = execution_results.iterator();
    while (it.next()) |entry| {
        total += 1;
        if (entry.value_ptr.status == .success) successful += 1;
    }
    return .{ .successful = successful, .total = total };
}

pub fn computeErrorRate(summary: ExecutionSummary) f64 {
    if (summary.total == 0) return 0.0;
    return 1.0 - (@as(f64, @floatFromInt(summary.successful)) / @as(f64, @floatFromInt(summary.total)));
}

pub fn computeTps(transactions_executed: u64, blocks_committed: u64) f64 {
    if (transactions_executed == 0 or blocks_committed == 0) return 0.0;
    return @as(f64, @floatFromInt(transactions_executed)) / @as(f64, @floatFromInt(blocks_committed));
}

pub fn buildExecutorStats(transactions_executed: u64, total_gas_used: u64, parallelism: usize) ExecutorStats {
    return .{
        .transactions_executed = transactions_executed,
        .total_gas_used = total_gas_used,
        .parallelism = parallelism,
    };
}

test "NodeMetricsCoordinator computes rates and uptime" {
    try std.testing.expect(computeNetworkUtil(5, 10) > 0.4);
    try std.testing.expectEqual(@as(f64, 0.0), computeNetworkUtil(1, 0));
    try std.testing.expect(computeStorageUtil(5000) > 0.4);
    try std.testing.expectEqual(@as(f64, 0.0), computeTps(0, 10));
}

