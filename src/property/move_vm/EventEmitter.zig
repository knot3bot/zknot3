//! EventEmitter - Event collection during Move VM execution
//!
//! Events emitted by native functions are collected into the Interpreter
//! and returned in ExecutionResult for indexing and observability.

const std = @import("std");
const Interpreter = @import("Interpreter.zig").Interpreter;
const Value = @import("Interpreter.zig").Value;
const NativeError = @import("NativeFunction.zig").NativeError;

/// Event emitted during transaction execution
pub const Event = struct {
    /// Event type identifier (e.g. "0x2::coin::Coin")
    event_type: []const u8,
    /// Sender address that emitted the event
    sender: [32]u8,
    /// Opaque event payload (JSON or BCS bytes)
    payload: []const u8,
    /// Monotonic event index within the transaction
    event_index: u64,
};

/// Native: sui::event::emit<T>(event: T)
/// Expects a single argument on the stack: a vector of bytes (serialized event)
pub fn nativeEmit(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;
    const arg = args[0];

    // For now accept either a vector of bytes (serialized payload) or an integer placeholder
    const payload = switch (arg.tag) {
        .vector => blk: {
            // Convert vector of Values (each u8 as integer) into a byte slice
            const vec = arg.data.vector;
            const bytes = interpreter.allocator.alloc(u8, vec.len) catch return NativeError.OutOfMemory;
            for (vec, 0..) |v, i| {
                if (v.tag != .integer) return NativeError.TypeMismatch;
                bytes[i] = @intCast(v.data.int & 0xFF);
            }
            break :blk bytes;
        },
        .integer => &.{}, // placeholder: no payload
        else => return NativeError.TypeMismatch,
    };
    errdefer if (arg.tag == .vector) interpreter.allocator.free(payload);

    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;

    const event = Event{
        .event_type = "sui::event::GenericEvent",
        .sender = ctx.sender,
        .payload = payload,
        .event_index = @intCast(interpreter.events.items.len),
    };

    interpreter.events.append(interpreter.allocator, event) catch return NativeError.OutOfMemory;

    // Return unit (no value)
    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}
