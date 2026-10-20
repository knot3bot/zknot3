//! ObjectTransfer - Object creation and transfer native functions
//!
//! Mirrors Sui's sui::object and sui::transfer modules.

const std = @import("std");
const core = @import("../../core.zig");
const Interpreter = @import("Interpreter.zig").Interpreter;
const ObjectEffect = @import("Interpreter.zig").ObjectEffect;
const Value = @import("Interpreter.zig").Value;
const NativeError = @import("NativeFunction.zig").NativeError;

fn authorize(interpreter: *Interpreter, id: [32]u8) NativeError!core.ObjectID {
    var oid = core.ObjectID.zero;
    @memcpy(&oid.bytes, &id);
    interpreter.requireSenderOwns(oid, null) catch |err| switch (err) {
        error.MissingSigner => return error.MissingSigner,
        error.NotResourceOwner => return error.NotResourceOwner,
        error.ResourceNotFound => return error.ResourceNotFound,
    };
    return oid;
}

fn finishEffect(
    interpreter: *Interpreter,
    oid: core.ObjectID,
    kind: ObjectEffect.Kind,
    recipient: [32]u8,
) NativeError!Value {
    try interpreter.output_objects.append(interpreter.allocator, oid.bytes);
    try interpreter.object_effects.append(interpreter.allocator, .{
        .kind = kind,
        .object_id = oid.bytes,
        .recipient = recipient,
    });
    interpreter.resource_tracker.recordConsume(oid) catch return error.OutOfMemory;
    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}

/// Native: sui::object::new(ctx: &mut TxContext) -> UID
/// Returns a fresh ObjectID as an address value.
pub fn nativeObjectNew(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    _ = args; // TxContext is implicitly available on the interpreter
    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;
    const id = ctx.freshObjectID() catch return error.ArithmeticOverflow;
    return Value{ .tag = .address, .data = .{ .address = id } };
}

/// Native: sui::transfer::public_transfer<T>(obj: T, recipient: address)
/// The signer must own the object. The recipient is stored on the effect,
/// then the object is consumed so the sender no longer holds it.
pub fn nativePublicTransfer(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 2) return NativeError.InvalidArgumentCount;
    const obj = args[0];
    const recipient = args[1];
    if (obj.tag != .resource) return NativeError.TypeMismatch;
    if (recipient.tag != .address) return NativeError.TypeMismatch;

    const oid = try authorize(interpreter, obj.data.resource.id);
    return finishEffect(interpreter, oid, .transfer, recipient.data.address);
}

/// Native: sui::transfer::share_object<T>(obj: T)
/// Consumes the object and marks it as shared.
pub fn nativeShareObject(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;
    const obj = args[0];
    if (obj.tag != .resource) return NativeError.TypeMismatch;

    const oid = try authorize(interpreter, obj.data.resource.id);
    return finishEffect(interpreter, oid, .share, @as([32]u8, @splat(0)));
}

/// Native: sui::transfer::freeze_object<T>(obj: T)
/// The signer must own the object. The effect records the freeze, then the
/// object is consumed so it can no longer be moved by this transaction.
pub fn nativeFreezeObject(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;
    const obj = args[0];
    if (obj.tag != .resource) return NativeError.TypeMismatch;

    const oid = try authorize(interpreter, obj.data.resource.id);
    return finishEffect(interpreter, oid, .freeze, @as([32]u8, @splat(0)));
}
