//! TxnAdmission - transaction ingress admission checks
//!
//! Extracts transaction admission policy from Node to reduce coupling.

const std = @import("std");
const pipeline = @import("../pipeline.zig");
const ExecutionResult = @import("../pipeline/Executor.zig").ExecutionResult;

pub const ValidationError = error{
    NotRunning,
    InvalidSignature,
    TransactionAlreadyExecuted,
    NonceTooOld,
    NonceTooNew,
};

pub const SubmitDecision = enum {
    accepted,
    duplicate,
};

pub const Context = struct {
    is_running: bool,
    txn_history: *const std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt),
    execution_results: *const std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult),
    sender_sequence: *const std.AutoArrayHashMapUnmanaged([32]u8, u64),
    max_nonce_ahead: u64 = 32,
};

pub fn hasSeenTransaction(ctx: *const Context, digest: [32]u8) bool {
    return ctx.txn_history.contains(digest) or ctx.execution_results.contains(digest);
}

pub fn validateIncomingTransaction(ctx: *const Context, tx: pipeline.Transaction) ValidationError![32]u8 {
    if (!ctx.is_running) return error.NotRunning;
    if (!tx.verifySignature()) return error.InvalidSignature;
    const expected_nonce = ctx.sender_sequence.get(tx.sender) orelse 0;
    if (tx.sequence < expected_nonce) return error.NonceTooOld;
    if (tx.sequence > expected_nonce + ctx.max_nonce_ahead) return error.NonceTooNew;
    const digest = tx.digest();
    if (hasSeenTransaction(ctx, digest)) return error.TransactionAlreadyExecuted;
    return digest;
}

pub fn validateForSubmit(ctx: *const Context, tx: pipeline.Transaction) ValidationError!SubmitDecision {
    _ = validateIncomingTransaction(ctx, tx) catch |err| switch (err) {
        error.TransactionAlreadyExecuted => return .duplicate,
        else => return err,
    };
    return .accepted;
}

test "TxnAdmission rejects when node is not running" {
    const tx_history = std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt).empty;
    const exec_results = std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult).empty;
    const ctx = Context{
        .is_running = false,
        .txn_history = &tx_history,
        .execution_results = &exec_results,
        .sender_sequence = &std.AutoArrayHashMapUnmanaged([32]u8, u64).empty,
    };
    const tx = pipeline.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 1,
        .sequence = 0,
        .signature = null,
        .public_key = null,
    };
    try std.testing.expectError(error.NotRunning, validateIncomingTransaction(&ctx, tx));
}

test "TxnAdmission classify duplicate transaction as duplicate decision" {
    const tx_history = std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt).empty;
    var exec_results = std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult).empty;
    defer exec_results.deinit(std.testing.allocator);
    const sender_sequence = std.AutoArrayHashMapUnmanaged([32]u8, u64).empty;
    const ctx = Context{
        .is_running = true,
        .txn_history = &tx_history,
        .execution_results = &exec_results,
        .sender_sequence = &sender_sequence,
    };
    var keypair = try @import("../property/crypto/Signature.zig").KeyPair.generate();
    defer keypair.deinit();
    var tx = pipeline.Transaction{
        .sender = [_]u8{3} ** 32,
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 100,
        .sequence = 0,
        .signature = null,
        .public_key = null,
    };
    const digest = tx.digest();
    const sig = try @import("../property/crypto/Signature.zig").sign(&digest, keypair.secret_key, .ed25519);
    tx.signature = sig.bytes;
    tx.public_key = keypair.public_key.bytes;
    try exec_results.put(std.testing.allocator, digest, .{
        .digest = digest,
        .status = .success,
        .gas_used = 10,
        .output_objects = &.{},
    });
    try std.testing.expectEqual(SubmitDecision.duplicate, try validateForSubmit(&ctx, tx));
}

