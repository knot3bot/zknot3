//! BlockExecution - block payload execution orchestration
//!
//! Collects all transactions from a block payload and executes them
//! in a single Block-STM batch for maximum parallel throughput.

const std = @import("std");
const pipeline = @import("../pipeline.zig");
const ExecutionResult = @import("../pipeline/Executor.zig").ExecutionResult;

pub const ExecuteContext = struct {
    allocator: std.mem.Allocator,
    executor: *pipeline.Executor,
    txn_history: *std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt),
};

pub fn senderChunkCount(payload_len: usize) usize {
    return payload_len / 32;
}

/// Collect all transactions from the payload and execute them in one
/// Block-STM batch via executeOrdered. This is the critical consensus
/// execution path — parallel execution replaces the old per-tx loop.
pub fn executePayloadTransactions(ctx: *ExecuteContext, payload: []const u8) ![]ExecutionResult {
    const sender_len = 32;
    const tx_count = payload.len / sender_len;
    if (tx_count == 0) return &.{};

    // Build transaction array
    const txs = try ctx.allocator.alloc(pipeline.Transaction, tx_count);
    defer ctx.allocator.free(txs);

    for (txs, 0..) |*tx, i| {
        const offset = i * sender_len;
        var sender: [32]u8 = undefined;
        @memcpy(&sender, payload[offset..][0..sender_len]);
        tx.* = .{
            .sender = sender,
            .inputs = &.{},
            .program = &.{},
            .gas_budget = 1000,
            .sequence = 0,
            .signature = null,
            .public_key = null,
        };
    }

    // Block-STM parallel execution (falls back to dependecy-graph for small batches)
    const results = try ctx.executor.executeOrdered(txs);

    // Record receipts for successful transactions
    for (results) |res| {
        if (res.status == .success) {
            const receipt = pipeline.TransactionReceipt{
                .digest = res.digest,
                .status = .executed,
                .gas_used = res.gas_used,
                .sender = res.digest,
            };
            try ctx.txn_history.put(ctx.allocator, res.digest, receipt);
        }
    }

    return results;
}

test "senderChunkCount floors on trailing bytes" {
    try std.testing.expectEqual(@as(usize, 0), senderChunkCount(0));
    try std.testing.expectEqual(@as(usize, 0), senderChunkCount(31));
    try std.testing.expectEqual(@as(usize, 1), senderChunkCount(32));
    try std.testing.expectEqual(@as(usize, 2), senderChunkCount(65));
}
