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
    /// Gas price for this transaction
    gas_price: u64,
    /// Gas budget (max gas)
    gas_budget: u64,
    /// Monotonic counter for fresh UID generation
    id_counter: u64 = 0,

    pub fn freshObjectID(self: *Self) [32]u8 {
        var out: [32]u8 = undefined;
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&self.tx_hash);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, self.id_counter, .big);
        hasher.update(&buf);
        hasher.final(&out);
        self.id_counter += 1;
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
    return Value{ .tag = .integer, .data = .{ .int = @intCast(ctx.epoch) } };
}

/// Native: sui::tx_context::epoch_timestamp_ms() -> u64
pub fn nativeEpochTimestampMs(_: *Interpreter, args: []const Value) NativeError!Value {
    _ = args;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const ms = @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
    return Value{ .tag = .integer, .data = .{ .int = @intCast(ms) } };
}

/// Native: sui::tx_context::fresh_id() -> address (ObjectID)
pub fn nativeFreshId(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    _ = args;
    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;
    const id = ctx.freshObjectID();
    return Value{ .tag = .address, .data = .{ .address = id } };
}
