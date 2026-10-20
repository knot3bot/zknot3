//! CoinBalance - integer conservation under the pop-all-args calling convention
//!
//! Interpreter.executeCall pops every native argument and pushes the single
//! returned Value. These natives conserve integer amounts inside that one
//! return value. They are not Move resource coins.
//!
//! split returns a two-integer vector: index 0 is the remainder
//! (balance - amount), index 1 is the amount taken. join and pay::join_vec
//! still return a single summed integer.

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

/// One returned vector so both halves survive executeCall's pop-all-args.
/// Index 0 is the remainder, index 1 is the amount taken. The slice is
/// allocated with `interpreter.allocator` and owned by the returned Value.
fn splitConserved(interpreter: *Interpreter, balance: i64, amount: i64) NativeError!Value {
    if (amount < 0) return NativeError.TypeMismatch;
    if (amount > balance) return NativeError.ResourceNotFound;
    const parts = try interpreter.allocator.alloc(Value, 2);
    parts[0] = Value{ .tag = .integer, .data = .{ .int = balance - amount } };
    parts[1] = Value{ .tag = .integer, .data = .{ .int = amount } };
    return Value{ .tag = .vector, .data = .{ .vector = parts } };
}

/// Native: sui::balance::split(balance, amount) -> vector<u64>
/// Returns [balance - amount, amount]. amount < 0 is TypeMismatch;
/// amount > balance is ResourceNotFound. amount == balance yields remainder 0.
pub fn nativeBalanceSplit(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 2) return NativeError.InvalidArgumentCount;
    const bal = args[0];
    const amount = args[1];
    if (bal.tag != .integer or amount.tag != .integer) return NativeError.TypeMismatch;
    return splitConserved(interpreter, bal.data.int, amount.data.int);
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

/// Native: sui::coin::split(coin, amount, ctx) -> vector<u64>
/// Same conserved pair as balance::split. The ctx argument is ignored.
pub fn nativeCoinSplit(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 3) return NativeError.InvalidArgumentCount;
    const bal = args[0];
    const amount = args[1];
    if (bal.tag != .integer or amount.tag != .integer) return NativeError.TypeMismatch;
    _ = args[2]; // ctx ignored; value is an integer pair, not a resource coin
    return splitConserved(interpreter, bal.data.int, amount.data.int);
}

/// Native: sui::coin::join(coin: &mut Coin<T>, other: Coin<T>)
/// Simplified: returns the sum.
pub fn nativeCoinJoin(_: *Interpreter, args: []const Value) NativeError!Value {
    return nativeBalanceJoin(undefined, args);
}

/// Native: sui::pay::split(coin, amount, ctx) -> vector<u64>
/// Delegates to coin::split, including the same interpreter allocator.
pub fn nativePaySplit(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    return nativeCoinSplit(interpreter, args);
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
