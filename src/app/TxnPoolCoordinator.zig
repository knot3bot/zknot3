//! TxnPoolCoordinator - txn pool query/maintenance helpers for Node.
//!
//! Layered access pattern:
//! * `getTxnPoolStats` / `getPendingTxnCount` are the HOT read path used by
//!   HTTP, Prometheus, and the dashboard. They route through
//!   `pipeline.TxnPool.metricsSnapshot()`, which only touches atomic counters
//!   and therefore never races with the single-threaded executor / ingress
//!   writers that mutate the priority queue and per-sender map.
//! * `cleanupExpiredTransactions` mutates the pool and MUST be invoked from
//!   the executor thread that owns the pool (the same thread that calls
//!   `add` / `next`).

const std = @import("std");
const core = @import("../core.zig");
const pipeline = @import("../pipeline.zig");

pub const TxnPoolStats = struct {
    pending: usize,
    executing: usize,
    received_total: u64 = 0,
    executed_total: u64 = 0,
    /// Distinct senders currently tracked in the pool (snapshot view).
    sender_count: usize = 0,
};

pub fn getTxnPoolStats(txn_pool: *pipeline.TxnPool) TxnPoolStats {
    // Lock-free snapshot; safe from any thread.
    const snap = txn_pool.metricsSnapshot();
    return .{
        .pending = @intCast(snap.pool_size),
        .executing = 0,
        .received_total = snap.received_total,
        .executed_total = snap.executed_total,
        .sender_count = @intCast(snap.sender_count),
    };
}

pub fn cleanupExpiredTransactions(txn_pool: *pipeline.TxnPool) usize {
    return txn_pool.removeExpired();
}

pub fn getPendingTxnCount(txn_pool: *pipeline.TxnPool) usize {
    return @intCast(txn_pool.metricsSnapshot().pool_size);
}

test "TxnPoolCoordinator stats and pending count" {
    const allocator = std.testing.allocator;
    var pool = try pipeline.TxnPool.init(allocator, .{});
    defer pool.deinit();

    const tx = pipeline.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = try allocator.alloc(core.ObjectID, 0),
        .program = try allocator.dupe(u8, "coord-test"),
        .gas_budget = 1000,
        .sequence = 1,
    };
    try pool.add(tx, 1000);

    const stats = getTxnPoolStats(pool);
    try std.testing.expectEqual(@as(usize, 1), stats.pending);
    try std.testing.expectEqual(@as(usize, 1), getPendingTxnCount(pool));
}

test "TxnPoolCoordinator metricsSnapshot races cleanly vs writer thread" {
    const allocator = std.testing.allocator;
    var pool = try pipeline.TxnPool.init(allocator, .{});
    defer pool.deinit();

    const Ctx = struct {
        pool: *pipeline.TxnPool,
        alloc: std.mem.Allocator,
        iterations: usize,

        fn writer(ctx: *@This()) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var sender_id: [32]u8 = [_]u8{0} ** 32;
                std.mem.writeInt(u64, sender_id[0..8], @intCast(i), .little);
                const tx = pipeline.Transaction{
                    .sender = sender_id,
                    .inputs = &.{},
                    .program = ctx.alloc.dupe(u8, "race") catch return,
                    .gas_budget = 1000,
                    .sequence = 1,
                };
                ctx.pool.add(tx, 1000) catch {};
                _ = ctx.pool.next();
            }
        }
    };

    var ctx = Ctx{ .pool = pool, .alloc = allocator, .iterations = 1000 };

    const writer_thread = try std.Thread.spawn(.{}, Ctx.writer, .{&ctx});

    // Concurrent reader: just ensures snapshot never panics / tears. Values
    // themselves will race but each field is torn-free individually.
    var reads: usize = 0;
    while (reads < 5000) : (reads += 1) {
        const stats = getTxnPoolStats(pool);
        // Sanity invariants that must always hold even under races.
        try std.testing.expect(stats.received_total >= stats.executed_total);
    }

    writer_thread.join();

    const final = getTxnPoolStats(pool);
    try std.testing.expectEqual(@as(u64, ctx.iterations), final.received_total);
    try std.testing.expectEqual(@as(u64, ctx.iterations), final.executed_total);
    try std.testing.expectEqual(@as(usize, 0), final.pending);
    try std.testing.expectEqual(@as(usize, 0), final.sender_count);
}

test "TxnPoolCoordinator cleanupExpiredTransactions removes expired txs" {
    const allocator = std.testing.allocator;
    var pool = try pipeline.TxnPool.init(allocator, .{ .timeout_seconds = -1 });
    defer pool.deinit();

    const tx = pipeline.Transaction{
        .sender = [_]u8{2} ** 32,
        .inputs = try allocator.alloc(core.ObjectID, 0),
        .program = try allocator.dupe(u8, "coord-expire"),
        .gas_budget = 1000,
        .sequence = 1,
    };
    try pool.add(tx, 1000);
    const removed = cleanupExpiredTransactions(pool);
    try std.testing.expect(removed >= 1);
    try std.testing.expectEqual(@as(usize, 0), getPendingTxnCount(pool));
}

