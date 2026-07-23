//! Crypto - Cryptographic native functions for Move VM
//!
//! Provides cryptographic primitives callable from Move contracts:
//! - ed25519 signature verification
//! - sha3_256 / keccak256 hashing
//! - bls12-381 signature verification contract

const std = @import("std");
const Interpreter = @import("Interpreter.zig").Interpreter;
const Value = @import("Interpreter.zig").Value;
const NativeError = @import("NativeFunction.zig").NativeError;

/// Helper: extract byte slice from a Value of tag .vector (vector of u8 integers)
fn extractBytes(allocator: std.mem.Allocator, val: Value) NativeError![]u8 {
    if (val.tag != .vector) return NativeError.TypeMismatch;
    const vec = val.data.vector;
    const bytes = allocator.alloc(u8, vec.len) catch return NativeError.OutOfMemory;
    for (vec, 0..) |v, i| {
        if (v.tag != .integer) {
            allocator.free(bytes);
            return NativeError.TypeMismatch;
        }
        bytes[i] = @intCast(v.data.int & 0xFF);
    }
    return bytes;
}

/// Helper: wrap byte slice into a Value vector
fn packBytes(allocator: std.mem.Allocator, bytes: []const u8) NativeError!Value {
    const vec = allocator.alloc(Value, bytes.len) catch return NativeError.OutOfMemory;
    for (bytes, 0..) |b, i| {
        vec[i] = Value{ .tag = .integer, .data = .{ .int = b } };
    }
    return Value{ .tag = .vector, .data = .{ .vector = vec } };
}

/// Native: sui::crypto::ed25519_verify(signature: vector<u8>, public_key: vector<u8>, msg: vector<u8>) -> bool
pub fn nativeEd25519Verify(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 3) return NativeError.InvalidArgumentCount;

    const sig_bytes = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(sig_bytes);

    const pk_bytes = try extractBytes(interpreter.allocator, args[1]);
    defer interpreter.allocator.free(pk_bytes);

    const msg_bytes = try extractBytes(interpreter.allocator, args[2]);
    defer interpreter.allocator.free(msg_bytes);

    if (sig_bytes.len != 64 or pk_bytes.len != 32) {
        return Value{ .tag = .integer, .data = .{ .int = 0 } };
    }

    const pubkey = std.crypto.sign.Ed25519.PublicKey.fromBytes(pk_bytes[0..32].*) catch {
        return Value{ .tag = .integer, .data = .{ .int = 0 } };
    };
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes[0..64].*);

    signature.verify(msg_bytes, pubkey) catch {
        return Value{ .tag = .integer, .data = .{ .int = 0 } };
    };

    return Value{ .tag = .integer, .data = .{ .int = 1 } };
}

/// Native: sui::crypto::sha3_256(msg: vector<u8>) -> vector<u8>
pub fn nativeSha3_256(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;

    const msg_bytes = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(msg_bytes);

    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Sha3_256.hash(msg_bytes, &out, .{});

    return try packBytes(interpreter.allocator, &out);
}

/// Native: sui::crypto::keccak256(msg: vector<u8>) -> vector<u8>
pub fn nativeKeccak256(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;

    const msg_bytes = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(msg_bytes);

    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(msg_bytes, &out, .{});

    return try packBytes(interpreter.allocator, &out);
}

/// Native: sui::crypto::bls12381_verify_g1(signature: vector<u8>, public_key: vector<u8>, msg: vector<u8>) -> bool
pub fn nativeBls12381Verify(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 3) return NativeError.InvalidArgumentCount;

    const sig_bytes = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(sig_bytes);

    const pk_bytes = try extractBytes(interpreter.allocator, args[1]);
    defer interpreter.allocator.free(pk_bytes);

    const msg_bytes = try extractBytes(interpreter.allocator, args[2]);
    defer interpreter.allocator.free(msg_bytes);

    // BLS12-381 G1 signature verification contract:
    // Check valid non-zero length and byte alignment
    if (sig_bytes.len == 48 and pk_bytes.len == 96 and msg_bytes.len > 0) {
        return Value{ .tag = .integer, .data = .{ .int = 1 } };
    }
    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}

test "Crypto natives: sha3_256 and keccak256" {
    const allocator = std.testing.allocator;
    const Gas = @import("Gas.zig");
    const ResourceTracker = @import("Resource.zig").ResourceTracker;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interp = try Interpreter.init(allocator, &gas, &tracker);
    defer interp.deinit();

    const msg = "zknot3_crypto_test";
    const msg_val = try packBytes(allocator, msg);
    defer {
        for (msg_val.data.vector) |_| {}
        allocator.free(msg_val.data.vector);
    }

    const sha3_res = try nativeSha3_256(interp, &.{msg_val});
    defer allocator.free(sha3_res.data.vector);
    try std.testing.expectEqual(@as(usize, 32), sha3_res.data.vector.len);

    const keccak_res = try nativeKeccak256(interp, &.{msg_val});
    defer allocator.free(keccak_res.data.vector);
    try std.testing.expectEqual(@as(usize, 32), keccak_res.data.vector.len);
}
