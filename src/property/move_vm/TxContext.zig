//! TxContext - Transaction context injected into Move VM execution
//!
//! Mirrors Sui's `TxContext` with sender, tx_hash, epoch, and gas info.

const std = @import("std");
const Interpreter = @import("Interpreter.zig").Interpreter;
const Value = @import("Interpreter.zig").Value;
const NativeError = @import("NativeFunction.zig").NativeError;

/// Transaction context available to native functions
pub const TxContext = struct {
    const Self = @This();

    /// Transaction sender (32-byte address)
    sender: [32]u8,
    /// Transaction digest / hash
    tx_hash: [32]u8,
    /// Current epoch number
    epoch: u64,
    /// Epoch start agreed by consensus, in milliseconds. Not the local clock.
    epoch_timestamp_ms: u64 = 0,
    /// Gas price for this transaction
    gas_price: u64,
    /// Gas budget (max gas)
    gas_budget: u64,
    /// Monotonic counter for fresh UID generation
    id_counter: u64 = 0,

    pub fn freshObjectID(self: *Self) error{ArithmeticOverflow}![32]u8 {
        const seq = self.id_counter;
        self.id_counter = std.math.add(u64, seq, 1) catch return error.ArithmeticOverflow;
        var out: [32]u8 = undefined;
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&self.tx_hash);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, seq, .big);
        hasher.update(&buf);
        hasher.final(&out);
        return out;
    }
};

/// Native: sui::tx_context::sender() -> address
pub fn nativeSender(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    _ = args;
    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;
    return Value{ .tag = .address, .data = .{ .address = ctx.sender } };
}

/// Native: sui::tx_context::epoch() -> u64
pub fn nativeEpoch(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    _ = args;
    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;
    const epoch: i64 = if (ctx.epoch > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(ctx.epoch);
    return Value{ .tag = .integer, .data = .{ .int = epoch } };
}

/// Native: sui::tx_context::epoch_timestamp_ms() -> u64
/// Returns the epoch timestamp injected into `TxContext`. A missing context
/// fails closed so two validators cannot observe different clocks.
pub fn nativeEpochTimestampMs(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    _ = args;
    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;
    const ms = ctx.epoch_timestamp_ms;
    const as_i64: i64 = if (ms > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(ms);
    return Value{ .tag = .integer, .data = .{ .int = as_i64 } };
}

/// Native: sui::tx_context::fresh_id() -> address (ObjectID)
pub fn nativeFreshId(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    _ = args;
    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;
    const id = ctx.freshObjectID() catch return error.ArithmeticOverflow;
    return Value{ .tag = .address, .data = .{ .address = id } };
}

test "nativeEpoch saturates above the signed integer limit" {
    const allocator = std.testing.allocator;
    const Gas = @import("Gas.zig");
    const ResourceTracker = @import("Resource.zig").ResourceTracker;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interp = try Interpreter.init(allocator, &gas, &tracker);
    defer interp.deinit();

    var ctx = TxContext{
        .sender = @splat(1),
        .tx_hash = @splat(2),
        .epoch = std.math.maxInt(u64),
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interp.tx_context = &ctx;
    const saturated = try nativeEpoch(interp, &.{});
    try std.testing.expectEqual(std.math.maxInt(i64), saturated.data.int);

    ctx.epoch = 7;
    const exact = try nativeEpoch(interp, &.{});
    try std.testing.expectEqual(@as(i64, 7), exact.data.int);
}

test "freshObjectID refuses to wrap the id counter" {
    var ctx = TxContext{
        .sender = @splat(1),
        .tx_hash = @splat(2),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
        .id_counter = std.math.maxInt(u64) - 1,
    };
    const id = try ctx.freshObjectID();
    try std.testing.expectEqual(@as(usize, 32), id.len);
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.id_counter);
    try std.testing.expectError(error.ArithmeticOverflow, ctx.freshObjectID());
    try std.testing.expectEqual(std.math.maxInt(u64), ctx.id_counter);
}
