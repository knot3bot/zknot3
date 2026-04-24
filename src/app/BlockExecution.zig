//! BlockExecution - block payload execution orchestration
//!
//! Keeps Node lean by extracting payload parsing and transaction execution flow.

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

pub fn executePayloadTransactions(ctx: *ExecuteContext, payload: []const u8) ![]ExecutionResult {
    var results = try std.ArrayList(ExecutionResult).initCapacity(ctx.allocator, 16);
    errdefer results.deinit(ctx.allocator);

    const sender_len = 32;
    var offset: usize = 0;
    while (offset + sender_len <= payload.len) : (offset += sender_len) {
        var sender: [32]u8 = undefined;
        @memcpy(&sender, payload[offset .. offset + sender_len]);

        const tx = pipeline.Transaction{
            .sender = sender,
            .inputs = &.{},
            .program = &.{},
            .gas_budget = 1000,
            .sequence = 0,
            .signature = null,
            .public_key = null,
        };

        const result = ctx.executor.execute(tx) catch |err| {
            try results.append(ctx.allocator, .{
                .digest = sender,
                .status = if (err == error.OutOfGas) .out_of_gas else .invalid_bytecode,
                .gas_used = 0,
                .output_objects = &.{},
                .events = &.{},
            });
            continue;
        };

        try results.append(ctx.allocator, result);

        const receipt = pipeline.TransactionReceipt{
            .digest = result.digest,
            .status = if (result.status == .success) .executed else .failed,
            .gas_used = result.gas_used,
            .sender = sender,
        };
        try ctx.txn_history.put(ctx.allocator, result.digest, receipt);
    }

    return try results.toOwnedSlice(ctx.allocator);
}

test "senderChunkCount floors on trailing bytes" {
    try std.testing.expectEqual(@as(usize, 0), senderChunkCount(0));
    try std.testing.expectEqual(@as(usize, 0), senderChunkCount(31));
    try std.testing.expectEqual(@as(usize, 1), senderChunkCount(32));
    try std.testing.expectEqual(@as(usize, 2), senderChunkCount(65));
}

