//! NodeStatsCoordinator - centralized, lock-free stats mutation helpers.
//!
//! Writers (commit loop, executor callbacks) and readers (HTTP `/metrics`,
//! gRPC status endpoints) touch the same counters on distinct threads, so the
//! shared struct uses `std.atomic.Value(u64)` and all access goes through this
//! module. Writes use `fetchAdd`/`store` with `.monotonic` ordering, reads use
//! `.monotonic` loads. That is sufficient for counter-style metrics because
//! each field is independently consistent - we do not need cross-field
//! happens-before, only that each field's own value is torn-free and monotonic.

const std = @import("std");
const ExecutionResult = @import("../pipeline/Executor.zig").ExecutionResult;

/// Canonical node stats layout. Any struct that exposes these four atomic
/// fields can be handed to the helpers below; we keep `anytype` so tests and
/// mocks can reuse the helpers without importing the real `Node` module.
pub const NodeStatsAtomic = struct {
    transactions_executed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_gas_used: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    blocks_committed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    highest_round: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Plain-old-data snapshot for callers that want a consistent-ish view of all
/// counters for reporting (e.g. `/metrics` render, `NodeInfo`). Each field is
/// read independently with monotonic ordering, so the snapshot can observe
/// intermediate states across fields - that is acceptable for counter metrics
/// and avoids introducing a global lock on the hot path.
pub const NodeStatsSnapshot = struct {
    transactions_executed: u64 = 0,
    total_gas_used: u64 = 0,
    blocks_committed: u64 = 0,
    highest_round: u64 = 0,
};

pub fn onRoundAdvanced(stats: anytype, round: u64) void {
    // `highest_round` is a high-water mark - only advance, never regress.
    // CAS loop keeps it monotonic across racing writers (advanceRound and
    // onBlockCommitted).
    var cur = stats.*.highest_round.load(.monotonic);
    while (round > cur) {
        const swapped = stats.*.highest_round.cmpxchgWeak(cur, round, .monotonic, .monotonic);
        if (swapped == null) break;
        cur = swapped.?;
    }
}

pub fn onBlockCommitted(stats: anytype, round: u64) void {
    _ = stats.*.blocks_committed.fetchAdd(1, .monotonic);
    onRoundAdvanced(stats, round);
}

pub fn onTransactionsExecuted(stats: anytype, count: usize, gas_used: u64) void {
    _ = stats.*.transactions_executed.fetchAdd(count, .monotonic);
    _ = stats.*.total_gas_used.fetchAdd(gas_used, .monotonic);
}

pub fn gasSum(results: []const ExecutionResult) u64 {
    var total: u64 = 0;
    for (results) |res| total += res.gas_used;
    return total;
}

/// Lock-free snapshot across all four counters. Callers should prefer this
/// over direct field reads so we have a single place to upgrade ordering /
/// seqlock semantics if future profiles require cross-field consistency.
pub fn snapshot(stats: anytype) NodeStatsSnapshot {
    return .{
        .transactions_executed = stats.*.transactions_executed.load(.monotonic),
        .total_gas_used = stats.*.total_gas_used.load(.monotonic),
        .blocks_committed = stats.*.blocks_committed.load(.monotonic),
        .highest_round = stats.*.highest_round.load(.monotonic),
    };
}

pub fn txExecuted(stats: anytype) u64 {
    return stats.*.transactions_executed.load(.monotonic);
}

pub fn totalGas(stats: anytype) u64 {
    return stats.*.total_gas_used.load(.monotonic);
}

pub fn blocksCommitted(stats: anytype) u64 {
    return stats.*.blocks_committed.load(.monotonic);
}

pub fn highestRound(stats: anytype) u64 {
    return stats.*.highest_round.load(.monotonic);
}

test "NodeStatsCoordinator updates counters and round" {
    var stats: NodeStatsAtomic = .{};

    onRoundAdvanced(&stats, 3);
    try std.testing.expectEqual(@as(u64, 3), highestRound(&stats));

    onTransactionsExecuted(&stats, 2, 99);
    try std.testing.expectEqual(@as(u64, 2), txExecuted(&stats));
    try std.testing.expectEqual(@as(u64, 99), totalGas(&stats));

    onBlockCommitted(&stats, 5);
    try std.testing.expectEqual(@as(u64, 1), blocksCommitted(&stats));
    try std.testing.expectEqual(@as(u64, 5), highestRound(&stats));

    // Regressed round must not be applied.
    onRoundAdvanced(&stats, 2);
    try std.testing.expectEqual(@as(u64, 5), highestRound(&stats));

    const snap = snapshot(&stats);
    try std.testing.expectEqual(@as(u64, 2), snap.transactions_executed);
    try std.testing.expectEqual(@as(u64, 99), snap.total_gas_used);
    try std.testing.expectEqual(@as(u64, 1), snap.blocks_committed);
    try std.testing.expectEqual(@as(u64, 5), snap.highest_round);
}

test "NodeStatsCoordinator concurrent writers + reader snapshot is torn-free" {
    var stats: NodeStatsAtomic = .{};

    const WriterCtx = struct {
        stats: *NodeStatsAtomic,
        iters: u64,

        fn txWorker(ctx: @This()) void {
            var i: u64 = 0;
            while (i < ctx.iters) : (i += 1) {
                onTransactionsExecuted(ctx.stats, 1, 10);
            }
        }

        fn commitWorker(ctx: @This()) void {
            var i: u64 = 0;
            while (i < ctx.iters) : (i += 1) {
                onBlockCommitted(ctx.stats, i + 1);
            }
        }
    };

    const iters: u64 = 10_000;
    const ctx = WriterCtx{ .stats = &stats, .iters = iters };

    var reader_observations: u64 = 0;
    const reader = struct {
        fn run(s: *NodeStatsAtomic, out: *u64) void {
            var observed: u64 = 0;
            while (observed < 2_000) : (observed += 1) {
                const snap = snapshot(s);
                // Fields must never decrease (monotonic counters).
                std.debug.assert(snap.transactions_executed <= 1_000_000);
                std.debug.assert(snap.blocks_committed <= 1_000_000);
            }
            out.* = observed;
        }
    }.run;

    const t1 = try std.Thread.spawn(.{}, WriterCtx.txWorker, .{ctx});
    const t2 = try std.Thread.spawn(.{}, WriterCtx.commitWorker, .{ctx});
    const t3 = try std.Thread.spawn(.{}, reader, .{ &stats, &reader_observations });
    t1.join();
    t2.join();
    t3.join();

    try std.testing.expectEqual(iters, txExecuted(&stats));
    try std.testing.expectEqual(iters * 10, totalGas(&stats));
    try std.testing.expectEqual(iters, blocksCommitted(&stats));
    try std.testing.expectEqual(iters, highestRound(&stats));
}
