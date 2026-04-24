//! NativeFunction - Native function registry for Move VM
//!
//! Provides a dispatch table from module::function name to Zig-native
//! implementations. This is the bridge between Move bytecode and the
//! zknot3 runtime (tx_context, object, transfer, coin, event).

const std = @import("std");
const Interpreter = @import("Interpreter.zig").Interpreter;
const Value = @import("Interpreter.zig").Value;

/// Errors raised by native functions
pub const NativeError = error{
    InvalidArgumentCount,
    TypeMismatch,
    ResourceNotFound,
    OutOfMemory,
    UnimplementedNative,
};

/// Signature of a native function callable from the Move VM
pub const NativeFunction = *const fn (
    interpreter: *Interpreter,
    args: []const Value,
) NativeError!Value;

/// Registry of native functions keyed by "module::function"
pub const Registry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    functions: std.StringHashMapUnmanaged(NativeFunction),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .functions = std.StringHashMapUnmanaged(NativeFunction).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.functions.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.functions.deinit(self.allocator);
    }

    /// Register a native function under module::name
    pub fn register(
        self: *Self,
        module: []const u8,
        name: []const u8,
        func: NativeFunction,
    ) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ module, name });
        errdefer self.allocator.free(key);
        const gop = try self.functions.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            gop.value_ptr.* = func;
        } else {
            gop.value_ptr.* = func;
        }
    }

    /// Look up a native function by module::name
    pub fn resolve(self: Self, module: []const u8, name: []const u8) ?NativeFunction {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}::{s}", .{ module, name }) catch return null;
        return self.functions.get(key);
    }

    /// Convenience: register all standard sui framework natives
    pub fn registerSuiFramework(self: *Self) !void {
        const TxContext = @import("TxContext.zig");
        try self.register("sui", "tx_context::sender", TxContext.nativeSender);
        try self.register("sui", "tx_context::epoch", TxContext.nativeEpoch);
        try self.register("sui", "tx_context::epoch_timestamp_ms", TxContext.nativeEpochTimestampMs);
        try self.register("sui", "tx_context::fresh_id", TxContext.nativeFreshId);

        const EventEmitter = @import("EventEmitter.zig");
        try self.register("sui", "event::emit", EventEmitter.nativeEmit);

        const ObjectTransfer = @import("ObjectTransfer.zig");
        try self.register("sui", "object::new", ObjectTransfer.nativeObjectNew);
        try self.register("sui", "transfer::public_transfer", ObjectTransfer.nativePublicTransfer);
        try self.register("sui", "transfer::share_object", ObjectTransfer.nativeShareObject);
        try self.register("sui", "transfer::freeze_object", ObjectTransfer.nativeFreezeObject);

        const CoinBalance = @import("CoinBalance.zig");
        try self.register("sui", "balance::value", CoinBalance.nativeBalanceValue);
        try self.register("sui", "balance::split", CoinBalance.nativeBalanceSplit);
        try self.register("sui", "balance::join", CoinBalance.nativeBalanceJoin);
        try self.register("sui", "coin::value", CoinBalance.nativeCoinValue);
        try self.register("sui", "coin::split", CoinBalance.nativeCoinSplit);
        try self.register("sui", "coin::join", CoinBalance.nativeCoinJoin);
        try self.register("sui", "pay::split", CoinBalance.nativePaySplit);
        try self.register("sui", "pay::join_vec", CoinBalance.nativePayJoinVec);
    }
};

test "Registry register and resolve" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const dummyFn: NativeFunction = struct {
        fn f(_: *Interpreter, _: []const Value) NativeError!Value {
            return Value{ .tag = .integer, .data = .{ .int = 42 } };
        }
    }.f;

    try reg.register("test", "answer", dummyFn);
    const resolved = reg.resolve("test", "answer");
    try std.testing.expect(resolved != null);
}

test "Registry resolve missing returns null" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const resolved = reg.resolve("missing", "func");
    try std.testing.expect(resolved == null);
}
