//! CoinBalance - Coin / Balance / Pay native functions (simplified for Phase 2)
//!
//! Uses integer values to represent balance amounts in the VM stack.
//! A full implementation would use resource structs with id + value.

const std = @import("std");
const Interpreter = @import("Interpreter.zig").Interpreter;
const Value = @import("Interpreter.zig").Value;
const NativeError = @import("NativeFunction.zig").NativeError;

/// Native: sui::balance::value(balance: &Balance<T>) -> u64
/// Simplified: reads an integer value from the stack.
pub fn nativeBalanceValue(_: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;
    const bal = args[0];
    if (bal.tag != .integer) return NativeError.TypeMismatch;
    return Value{ .tag = .integer, .data = .{ .int = bal.data.int } };
}

/// Native: sui::balance::split(balance: &mut Balance<T>, amount: u64) -> Balance<T>
/// Simplified: subtracts amount from balance integer and returns the split amount.
pub fn nativeBalanceSplit(_: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 2) return NativeError.InvalidArgumentCount;
    const bal = args[0];
    const amount = args[1];
    if (bal.tag != .integer or amount.tag != .integer) return NativeError.TypeMismatch;
    if (amount.data.int < 0) return NativeError.TypeMismatch;
    if (bal.data.int < amount.data.int) return NativeError.ResourceNotFound; // insufficient balance
    // Return the split amount as the new balance value
    return Value{ .tag = .integer, .data = .{ .int = amount.data.int } };
}

/// Native: sui::balance::join(balance: &mut Balance<T>, other: Balance<T>)
/// Simplified: returns the sum of two integer balances.
pub fn nativeBalanceJoin(_: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 2) return NativeError.InvalidArgumentCount;
    const a = args[0];
    const b = args[1];
    if (a.tag != .integer or b.tag != .integer) return NativeError.TypeMismatch;
    const sum, const overflow = @addWithOverflow(a.data.int, b.data.int);
    if (overflow != 0) return NativeError.ResourceNotFound;
    return Value{ .tag = .integer, .data = .{ .int = sum } };
}

/// Native: sui::coin::value(coin: &Coin<T>) -> u64
/// Simplified: same as balance::value.
pub fn nativeCoinValue(_: *Interpreter, args: []const Value) NativeError!Value {
    return nativeBalanceValue(undefined, args);
}

/// Native: sui::coin::split(coin: &mut Coin<T>, amount: u64, ctx: &mut TxContext) -> Coin<T>
/// Simplified: returns the split amount as a new integer balance.
pub fn nativeCoinSplit(_: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 3) return NativeError.InvalidArgumentCount;
    const bal = args[0];
    const amount = args[1];
    if (bal.tag != .integer or amount.tag != .integer) return NativeError.TypeMismatch;
    if (amount.data.int < 0) return NativeError.TypeMismatch;
    if (bal.data.int < amount.data.int) return NativeError.ResourceNotFound;
    _ = args[2]; // ctx ignored in simplified model
    return Value{ .tag = .integer, .data = .{ .int = amount.data.int } };
}

/// Native: sui::coin::join(coin: &mut Coin<T>, other: Coin<T>)
/// Simplified: returns the sum.
pub fn nativeCoinJoin(_: *Interpreter, args: []const Value) NativeError!Value {
    return nativeBalanceJoin(undefined, args);
}

/// Native: sui::pay::split(coin: &mut Coin<T>, amount: u64, ctx: &mut TxContext) -> Coin<T>
/// Simplified: same as coin::split.
pub fn nativePaySplit(_: *Interpreter, args: []const Value) NativeError!Value {
    return nativeCoinSplit(undefined, args);
}

/// Native: sui::pay::join_vec(coins: vector<Coin<T>>) -> Coin<T>
/// Simplified: sums all integer values in the vector.
pub fn nativePayJoinVec(_: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 1) return NativeError.InvalidArgumentCount;
    const vec = args[0];
    if (vec.tag != .vector) return NativeError.TypeMismatch;
    var sum: i64 = 0;
    for (vec.data.vector) |v| {
        if (v.tag != .integer) return NativeError.TypeMismatch;
        const s, const overflow = @addWithOverflow(sum, v.data.int);
        if (overflow != 0) return NativeError.ResourceNotFound;
        sum = s;
    }
    return Value{ .tag = .integer, .data = .{ .int = sum } };
}
