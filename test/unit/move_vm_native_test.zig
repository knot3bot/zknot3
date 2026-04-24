//! Move VM Native Function + TxContext + Event System Tests

const std = @import("std");
const move_vm = @import("../../src/property/move_vm/index.zig");
const Interpreter = move_vm.Interpreter;
const Value = @import("../../src/property/move_vm/Interpreter.zig").Value;
const Bytecode = move_vm.Bytecode;
const Gas = move_vm.Gas;
const ResourceTracker = move_vm.ResourceTracker;
const Registry = move_vm.Registry;
const TxContext = move_vm.TxContext;
const Event = move_vm.Event;
const NativeError = @import("../../src/property/move_vm/NativeFunction.zig").NativeError;

/// Helper: build a call instruction payload from module, function, arg_count
fn buildCallPayload(allocator: std.mem.Allocator, module: []const u8, func: []const u8, arg_count: u8) ![]u8 {
    const payload = try allocator.alloc(u8, 1 + module.len + 1 + func.len + 1);
    payload[0] = @intCast(module.len);
    @memcpy(payload[1..][0..module.len], module);
    payload[1 + module.len] = @intCast(func.len);
    @memcpy(payload[2 + module.len..][0..func.len], func);
    payload[2 + module.len + func.len] = arg_count;
    return payload;
}

test "native function call returns value" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const answerFn: @import("../../src/property/move_vm/NativeFunction.zig").NativeFunction = struct {
        fn f(_: *Interpreter, args: []const Value) NativeError!Value {
            _ = args;
            return Value{ .tag = .integer, .data = .{ .int = 42 } };
        }
    }.f;
    try reg.register("test", "answer", answerFn);

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    const payload = try buildCallPayload(allocator, "test", "answer", 0);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "native_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .integer);
    try std.testing.expectEqual(@as(i64, 42), result.return_value.?.data.int);
}

test "tx_context::sender returns injected sender" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    try reg.registerSuiFramework();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    var tx_ctx = TxContext{
        .sender = [_]u8{0xAB} ** 32,
        .tx_hash = [_]u8{0x00} ** 32,
        .epoch = 7,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interpreter.tx_context = &tx_ctx;

    const payload = try buildCallPayload(allocator, "sui", "tx_context::sender", 0);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "txctx_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .address);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xAB} ** 32, &result.return_value.?.data.address);
}

test "tx_context::epoch returns injected epoch" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    try reg.registerSuiFramework();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    var tx_ctx = TxContext{
        .sender = [_]u8{0x00} ** 32,
        .tx_hash = [_]u8{0x00} ** 32,
        .epoch = 42,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interpreter.tx_context = &tx_ctx;

    const payload = try buildCallPayload(allocator, "sui", "tx_context::epoch", 0);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "epoch_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 42), result.return_value.?.data.int);
}

test "event::emit collects events into ExecutionResult" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    try reg.registerSuiFramework();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    var tx_ctx = TxContext{
        .sender = [_]u8{0xCD} ** 32,
        .tx_hash = [_]u8{0x00} ** 32,
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interpreter.tx_context = &tx_ctx;

    // Build a vector of bytes [0x01, 0x02, 0x03] as event payload.
    // Keep payload backing storage stable (no loop-local literals).
    var vec_instrs: [7]Bytecode.Instruction = .{
        .{ .opcode = .ld_u8, .payload = &[_]u8{0x01} },
        .{ .opcode = .ld_u8, .payload = &[_]u8{0x02} },
        .{ .opcode = .ld_u8, .payload = &[_]u8{0x03} },
        .{ .opcode = .ld_u64, .payload = &[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } }, // count=3
        .{ .opcode = .vec_pack, .payload = &[_]u8{ 0x03, 0x00, 0x00, 0x00 } }, // pack 3 elements
        undefined,
        undefined,
    };

    const call_payload = try buildCallPayload(allocator, "sui", "event::emit", 1);
    defer allocator.free(call_payload);
    vec_instrs[5] = .{ .opcode = .call, .payload = call_payload };
    vec_instrs[6] = .{ .opcode = .ret, .payload = &.{} };

    const module = Bytecode.VerifiedModule{
        .name = "event_test",
        .instructions = &vec_instrs,
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.events.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xCD} ** 32, &result.events[0].sender);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01, 0x02, 0x03}, result.events[0].payload);
}


test "object::new returns fresh ObjectID via tx_context" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    try reg.registerSuiFramework();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    var tx_ctx = TxContext{
        .sender = [_]u8{0x00} ** 32,
        .tx_hash = [_]u8{0x00} ** 32,
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interpreter.tx_context = &tx_ctx;

    const payload = try buildCallPayload(allocator, "sui", "object::new", 0);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "object_new_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expect(result.return_value.?.tag == .address);
    // Fresh ID should not be all zeros
    try std.testing.expect(!std.mem.eql(u8, &[_]u8{0} ** 32, &result.return_value.?.data.address));
}

test "balance::split returns split amount" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    try reg.registerSuiFramework();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    // Stack: balance=100, amount=30
    const payload = try buildCallPayload(allocator, "sui", "balance::split", 2);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "balance_split_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &[_]u8{100, 0, 0, 0, 0, 0, 0, 0} }, // balance=100
            .{ .opcode = .ld_u64, .payload = &[_]u8{30, 0, 0, 0, 0, 0, 0, 0} },  // amount=30
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 30), result.return_value.?.data.int);
}

test "balance::join sums two balances" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    try reg.registerSuiFramework();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    const payload = try buildCallPayload(allocator, "sui", "balance::join", 2);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "balance_join_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &[_]u8{50, 0, 0, 0, 0, 0, 0, 0} },
            .{ .opcode = .ld_u64, .payload = &[_]u8{25, 0, 0, 0, 0, 0, 0, 0} },
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 75), result.return_value.?.data.int);
}

test "pay::join_vec sums vector of balances" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    try reg.registerSuiFramework();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    const payload = try buildCallPayload(allocator, "sui", "pay::join_vec", 1);
    defer allocator.free(payload);

    // Build vector [10, 20, 30]
    const module = Bytecode.VerifiedModule{
        .name = "pay_join_vec_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &[_]u8{10, 0, 0, 0, 0, 0, 0, 0} },
            .{ .opcode = .ld_u64, .payload = &[_]u8{20, 0, 0, 0, 0, 0, 0, 0} },
            .{ .opcode = .ld_u64, .payload = &[_]u8{30, 0, 0, 0, 0, 0, 0, 0} },
            .{ .opcode = .ld_u64, .payload = &[_]u8{3, 0, 0, 0, 0, 0, 0, 0} }, // count=3
            .{ .opcode = .vec_pack, .payload = &[_]u8{3, 0, 0, 0} },
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 60), result.return_value.?.data.int);
}
