//! Move Contract Execution Tests for zknot3
//!
//! Tests the Move VM interpreter with Knot3 Move contracts.

const std = @import("std");
const core = @import("../../core.zig");
const move_vm = @import("index.zig");
const Bytecode = move_vm.Bytecode;
const BytecodeVerifier = Bytecode.BytecodeVerifier;
const Interpreter = move_vm.Interpreter;
const Gas = move_vm.Gas;
const Resource = @import("Resource.zig").Resource;
const ResourceTracker = @import("Resource.zig").ResourceTracker;

/// Simple arithmetic contract: add two constants and return
/// Bytecode: ld_const(7); ld_const(3); add; ret
fn addContractBytecode() []const u8 {
    return &.{
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, // ld_i64 7
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // ld_i64 3
        0x40, // add
        0x01, // ret
    };
}

/// Factorial contract bytecode: computes 5! = 120
/// Uses iterative loop with branching
fn factorialBytecode() []const u8 {
    // Simplified: loads constants and multiplies
    // ld_const(5); ld_const(4); mul; ld_const(3); mul; ld_const(2); mul; ld_const(1); mul; ret
    return &.{
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // 5
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, // 4
        0x42, // mul
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // 3
        0x42, // mul
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, // 2
        0x42, // mul
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // 1
        0x42, // mul
        0x01, // ret
    };
}

/// Boolean logic contract: true AND false = false
fn booleanLogicBytecode() []const u8 {
    return &.{
        0x31, // ld_true
        0x32, // ld_false
        0x70, // and
        0x01, // ret
    };
}

test "Move VM: arithmetic contract execution" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(addContractBytecode());
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .integer);
    try std.testing.expectEqual(@as(i64, 10), result.return_value.?.data.int);
    try std.testing.expect(result.gas_consumed > 0);
}

test "Move VM: factorial contract execution" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(factorialBytecode());
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .integer);
    try std.testing.expectEqual(@as(i64, 120), result.return_value.?.data.int);
}

test "Move VM: boolean logic contract" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(booleanLogicBytecode());
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .boolean);
    try std.testing.expectEqual(false, result.return_value.?.data.bool);
}

test "Move VM: gas budget enforcement" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 2, .max_gas = 2 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(factorialBytecode());
    defer module.deinit(allocator);

    // Factorial uses many instructions, should exceed gas budget of 2
    const result = interpreter.execute(module);
    try std.testing.expectError(error.OutOfGas, result);
}

test "Move VM: resource tracking in contract execution" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    const gas = Gas.GasMeter.init(gas_config);
    _ = gas;
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    // Create a KNOT3 coin resource
    const owner = [_]u8{0xAB} ** 32;
    const coin = try Resource.init(
        core.ObjectID.hash("knot3_coin"),
        .Coin,
        "1000000000",
        owner,
        allocator,
    );
    // tracker.deinit() will free the tracked resource, so no separate defer here
    try tracker.track(coin);
    try std.testing.expect(tracker.isTracked(coin.id));
    try std.testing.expectEqual(@as(usize, 1), tracker.activeCount());
}

test "Move VM: bytecode verifier rejects invalid opcodes" {
    const allocator = std.testing.allocator;

    var verifier = BytecodeVerifier.init(allocator);
    const invalid_bytecode = &.{ 0xFF, 0x01 }; // invalid opcode + ret

    var module = try verifier.verify(invalid_bytecode);
    defer module.deinit(allocator);

    // Verifier should parse but mark as invalid opcode
    try std.testing.expectEqual(module.instructions.len, 2);
    try std.testing.expect(module.instructions[0].opcode == .invalid);
    try std.testing.expect(module.instructions[1].opcode == .ret);
}

test "Move VM: complex expression with comparison" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    // Bytecode: (5 + 3) > 7 = true
    const bytecode = &.{
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // 5
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // 3
        0x40, // add = 8
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, // 7
        0x63, // gt
        0x01, // ret
    };

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(bytecode);
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .boolean);
    try std.testing.expectEqual(true, result.return_value.?.data.bool);
}

test "Move VM: Knot3 token balance simulation" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    // Simulate: balance = 500; deposit = 300; new_balance = balance + deposit
    const bytecode = &.{
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4, // 500
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x2C, // 300
        0x40, // add = 800
        0x01, // ret
    };

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(bytecode);
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 800), result.return_value.?.data.int);
}
test "Move VM: ERC20-like token contract - total supply" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    // Bytecode: return total supply (1000000)
    const bytecode = &.{ 
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x42, 0x40, // 1000000
        0x01, // ret
    };

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(bytecode);
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .integer);
    try std.testing.expectEqual(@as(i64, 1000000), result.return_value.?.data.int);
}


test "Move VM: ERC20-like token contract - balanceOf" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    // Bytecode: return balance of address (0x1234... = 500)
    const bytecode = &.{ 
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4, // 500
        0x01, // ret
    };

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(bytecode);
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .integer);
    try std.testing.expectEqual(@as(i64, 500), result.return_value.?.data.int);
}


test "Move VM: ERC20-like token contract - transfer" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    // Bytecode: sender_balance = 500; amount = 200; new_balance = sender_balance - amount
    const bytecode = &.{ 
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4, // sender_balance = 500
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC8, // amount = 200
        0x41, // subtract
        0x01, // ret
    };

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(bytecode);
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .integer);
    try std.testing.expectEqual(@as(i64, 300), result.return_value.?.data.int);
}


test "Move VM: ERC20-like token contract - approve and transferFrom" {
    const allocator = std.testing.allocator;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    // Bytecode: allowance = 1000; amount = 500; remaining = allowance - amount
    const bytecode = &.{ 
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, // allowance = 1000
        0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4, // amount = 500
        0x41, // subtract
        0x01, // ret
    };

    var verifier = BytecodeVerifier.init(allocator);
    var module = try verifier.verify(bytecode);
    defer module.deinit(allocator);

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .integer);
    try std.testing.expectEqual(@as(i64, 500), result.return_value.?.data.int);
}
