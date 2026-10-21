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

/// Native: `emit(payload)` records `sui::event::GenericEvent`.
/// `emit(type, payload)` records `type` as raw bytes. Both strings are owned
/// by the interpreter event list.
pub fn nativeEmit(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1 and args.len != 2) return NativeError.InvalidArgumentCount;
    const arg = args[args.len - 1];

    const payload = switch (arg.tag) {
        .vector => try ownedBytes(interpreter, arg),
        .integer => &.{},
        else => return NativeError.TypeMismatch,
    };
    errdefer if (arg.tag == .vector) interpreter.allocator.free(payload);

    const event_type = if (args.len == 2) blk: {
        const name = try ownedBytes(interpreter, args[0]);
        if (name.len == 0) {
            interpreter.allocator.free(name);
            return NativeError.TypeMismatch;
        }
        break :blk name;
    } else interpreter.allocator.dupe(u8, "sui::event::GenericEvent") catch return NativeError.OutOfMemory;
    errdefer interpreter.allocator.free(event_type);

    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;

    const event = Event{
        .event_type = event_type,
        .sender = ctx.sender,
        .payload = payload,
        .event_index = @intCast(interpreter.events.items.len),
    };

    interpreter.events.append(interpreter.allocator, event) catch return NativeError.OutOfMemory;
    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}

fn ownedBytes(interpreter: *Interpreter, arg: Value) NativeError![]u8 {
    if (arg.tag != .vector) return NativeError.TypeMismatch;
    const vec = arg.data.vector;
    const bytes = interpreter.allocator.alloc(u8, vec.len) catch return NativeError.OutOfMemory;
    for (vec, 0..) |v, i| {
        if (v.tag != .integer) {
            interpreter.allocator.free(bytes);
            return NativeError.TypeMismatch;
        }
        bytes[i] = @intCast(v.data.int & 0xFF);
    }
    return bytes;
}
