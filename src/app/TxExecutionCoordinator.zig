//! TxExecutionCoordinator - single/batch transaction execution coordination
//!
//! Extracts replay protection, sequence checks and receipt bookkeeping from Node.

const std = @import("std");
const pipeline = @import("../pipeline.zig");
const ExecutionResult = @import("../pipeline/Executor.zig").ExecutionResult;

pub const ExecuteError = error{
    TransactionAlreadyExecuted,
    InvalidSequence,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    execution_results: *std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult),
    txn_history: *std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt),
    sender_sequence: *std.AutoArrayHashMapUnmanaged([32]u8, u64),
};

pub fn hasSeenTransaction(ctx: *const Context, digest: [32]u8) bool {
    return ctx.txn_history.contains(digest) or ctx.execution_results.contains(digest);
}

pub fn executeOne(ctx: *Context, tx: pipeline.Transaction) (ExecuteError || std.mem.Allocator.Error)!ExecutionResult {
    const digest = tx.digest();

    if (hasSeenTransaction(ctx, digest)) return error.TransactionAlreadyExecuted;

    const expected_sequence = ctx.sender_sequence.get(tx.sender) orelse 0;
    if (tx.sequence != expected_sequence) return error.InvalidSequence;

    const result = ExecutionResult{
        .digest = digest,
        .status = .success,
        .gas_used = tx.gas_budget / 2,
        .output_objects = &.{},
        .events = &.{},
    };

    try ctx.execution_results.put(ctx.allocator, digest, result);
    try ctx.txn_history.put(ctx.allocator, digest, .{
        .digest = digest,
        .status = .executed,
        .gas_used = result.gas_used,
        .sender = tx.sender,
    });
    try ctx.sender_sequence.put(ctx.allocator, tx.sender, expected_sequence + 1);

    return result;
}

pub fn executeBatch(ctx: *Context, txs: []const pipeline.Transaction) (ExecuteError || std.mem.Allocator.Error)![]ExecutionResult {
    var results = std.ArrayList(ExecutionResult).empty;
    errdefer results.deinit(ctx.allocator);

    for (txs) |tx| {
        const result = try executeOne(ctx, tx);
        try results.append(ctx.allocator, result);
    }
    return results.toOwnedSlice(ctx.allocator);
}

test "TxExecutionCoordinator executeOne updates sequence and history" {
    const allocator = std.testing.allocator;
    var execution_results = std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult).empty;
    defer execution_results.deinit(allocator);
    var txn_history = std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt).empty;
    defer txn_history.deinit(allocator);
    var sender_sequence = std.AutoArrayHashMapUnmanaged([32]u8, u64).empty;
    defer sender_sequence.deinit(allocator);

    var ctx = Context{
        .allocator = allocator,
        .execution_results = &execution_results,
        .txn_history = &txn_history,
        .sender_sequence = &sender_sequence,
    };

    const sender = [_]u8{9} ** 32;
    const tx = pipeline.Transaction{
        .sender = sender,
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 1000,
        .sequence = 0,
        .signature = null,
        .public_key = null,
    };

    const result = try executeOne(&ctx, tx);
    try std.testing.expect(result.status == .success);
    try std.testing.expect(ctx.txn_history.count() == 1);
    try std.testing.expect(ctx.execution_results.count() == 1);
    try std.testing.expectEqual(@as(u64, 1), ctx.sender_sequence.get(sender).?);
}

test "TxExecutionCoordinator rejects replay and invalid sequence" {
    const allocator = std.testing.allocator;
    var execution_results = std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult).empty;
    defer execution_results.deinit(allocator);
    var txn_history = std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt).empty;
    defer txn_history.deinit(allocator);
    var sender_sequence = std.AutoArrayHashMapUnmanaged([32]u8, u64).empty;
    defer sender_sequence.deinit(allocator);

    var ctx = Context{
        .allocator = allocator,
        .execution_results = &execution_results,
        .txn_history = &txn_history,
        .sender_sequence = &sender_sequence,
    };

    const sender = [_]u8{7} ** 32;
    const tx = pipeline.Transaction{
        .sender = sender,
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 1000,
        .sequence = 0,
        .signature = null,
        .public_key = null,
    };
    _ = try executeOne(&ctx, tx);
    try std.testing.expectError(error.TransactionAlreadyExecuted, executeOne(&ctx, tx));

    const sender2 = [_]u8{8} ** 32;
    try sender_sequence.put(allocator, sender2, 3);
    const bad_seq_tx = pipeline.Transaction{
        .sender = sender2,
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null,
        .public_key = null,
    };
    try std.testing.expectError(error.InvalidSequence, executeOne(&ctx, bad_seq_tx));
}

