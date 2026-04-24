//! ObjectTransfer - Object creation and transfer native functions
//!
//! Mirrors Sui's sui::object and sui::transfer modules.

const std = @import("std");
const Interpreter = @import("Interpreter.zig").Interpreter;
const Value = @import("Interpreter.zig").Value;
const NativeError = @import("NativeFunction.zig").NativeError;

/// Native: sui::object::new(ctx: &mut TxContext) -> UID
/// Returns a fresh ObjectID as an address value.
pub fn nativeObjectNew(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    _ = args; // TxContext is implicitly available on the interpreter
    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;
    const id = ctx.freshObjectID();
    return Value{ .tag = .address, .data = .{ .address = id } };
}

/// Native: sui::transfer::public_transfer<T>(obj: T, recipient: address)
/// Consumes the object (removes from stack) and records the transfer intent.
/// Returns unit.
pub fn nativePublicTransfer(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 2) return NativeError.InvalidArgumentCount;
    const obj = args[0];
    const recipient = args[1];
    if (obj.tag != .resource) return NativeError.TypeMismatch;
    if (recipient.tag != .address) return NativeError.TypeMismatch;

    // Record the transferred object ID for effects
    try interpreter.output_objects.append(interpreter.allocator, obj.data.resource.id);

    // Mark resource as consumed in tracker
    var oid = @import("../../core.zig").ObjectID.zero;
    @memcpy(&oid.bytes, &obj.data.resource.id);
    interpreter.resource_tracker.recordConsume(oid) catch return NativeError.ResourceNotFound;

    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}

/// Native: sui::transfer::share_object<T>(obj: T)
/// Consumes the object and marks it as shared.
pub fn nativeShareObject(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;
    const obj = args[0];
    if (obj.tag != .resource) return NativeError.TypeMismatch;

    try interpreter.output_objects.append(interpreter.allocator, obj.data.resource.id);

    var oid = @import("../../core.zig").ObjectID.zero;
    @memcpy(&oid.bytes, &obj.data.resource.id);
    interpreter.resource_tracker.recordConsume(oid) catch return NativeError.ResourceNotFound;

    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}

/// Native: sui::transfer::freeze_object<T>(obj: T)
/// Consumes the object and marks it as immutable.
pub fn nativeFreezeObject(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;
    const obj = args[0];
    if (obj.tag != .resource) return NativeError.TypeMismatch;

    try interpreter.output_objects.append(interpreter.allocator, obj.data.resource.id);

    var oid = @import("../../core.zig").ObjectID.zero;
    @memcpy(&oid.bytes, &obj.data.resource.id);
    interpreter.resource_tracker.recordConsume(oid) catch return NativeError.ResourceNotFound;

    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}
