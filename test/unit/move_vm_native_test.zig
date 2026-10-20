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
    @memcpy(payload[2 + module.len ..][0..func.len], func);
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
        .sender = @as([32]u8, @splat(0xAB)),
        .tx_hash = @as([32]u8, @splat(0x00)),
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
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xAB)), &result.return_value.?.data.address);
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
        .sender = @as([32]u8, @splat(0x00)),
        .tx_hash = @as([32]u8, @splat(0x00)),
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

test "tx_context::epoch_timestamp_ms returns the injected epoch time" {
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
        .sender = @as([32]u8, @splat(0x00)),
        .tx_hash = @as([32]u8, @splat(0x00)),
        .epoch = 42,
        .gas_price = 1,
        .gas_budget = 1000,
        .epoch_timestamp_ms = 1_700_000_000_000,
    };
    interpreter.tx_context = &tx_ctx;

    const payload = try buildCallPayload(allocator, "sui", "tx_context::epoch_timestamp_ms", 0);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "epoch_ts_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const first = try interpreter.execute(module);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), first.return_value.?.data.int);
    interpreter.pc = 0;
    const second = try interpreter.execute(module);
    try std.testing.expectEqual(first.return_value.?.data.int, second.return_value.?.data.int);
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
        .sender = @as([32]u8, @splat(0xCD)),
        .tx_hash = @as([32]u8, @splat(0x00)),
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
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xCD)), &result.events[0].sender);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, result.events[0].payload);
}

test "event::emit frees the payload when a vector element is not an integer" {
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
        .sender = @as([32]u8, @splat(0xCD)),
        .tx_hash = @as([32]u8, @splat(0)),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interpreter.tx_context = &tx_ctx;

    const elems = try allocator.alloc(Value, 2);
    elems[0] = .{ .tag = .integer, .data = .{ .int = 1 } };
    elems[1] = .{ .tag = .boolean, .data = .{ .bool = true } };
    try interpreter.stack.append(allocator, .{ .tag = .vector, .data = .{ .vector = elems } });

    const payload = try buildCallPayload(allocator, "sui", "event::emit", 1);
    defer allocator.free(payload);
    const module = Bytecode.VerifiedModule{
        .name = "bad-event",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = payload },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.TypeMismatch, interpreter.execute(module));
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
        .sender = @as([32]u8, @splat(0x00)),
        .tx_hash = @as([32]u8, @splat(0x00)),
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
    try std.testing.expect(!std.mem.eql(u8, &@as([32]u8, @splat(0)), &result.return_value.?.data.address));
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
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 100, 0, 0, 0, 0, 0, 0, 0 } }, // balance=100
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 30, 0, 0, 0, 0, 0, 0, 0 } }, // amount=30
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    // execute() pops the return value off the stack. Interpreter.deinit only
    // frees values still on the stack, so the test owns this vector.
    defer if (result.return_value) |returned| returned.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    const returned = result.return_value.?;
    try std.testing.expect(returned.tag == .vector);
    try std.testing.expectEqual(@as(usize, 2), returned.data.vector.len);
    try std.testing.expect(returned.data.vector[0].tag == .integer);
    try std.testing.expect(returned.data.vector[1].tag == .integer);
    try std.testing.expectEqual(@as(i64, 70), returned.data.vector[0].data.int);
    try std.testing.expectEqual(@as(i64, 30), returned.data.vector[1].data.int);
    try std.testing.expectEqual(@as(i64, 100), returned.data.vector[0].data.int + returned.data.vector[1].data.int);
}

test "balance::split rejects amount above balance" {
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

    const payload = try buildCallPayload(allocator, "sui", "balance::split", 2);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "balance_split_insufficient_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 100, 0, 0, 0, 0, 0, 0, 0 } }, // balance=100
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 101, 0, 0, 0, 0, 0, 0, 0 } }, // amount=101
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    // Failure happens before any vector is allocated, and the integer args
    // stay on the stack until interpreter.deinit().
    try std.testing.expectError(error.ResourceNotFound, interpreter.execute(module));
}

test "balance::split keeps a zero remainder when amount equals balance" {
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

    const payload = try buildCallPayload(allocator, "sui", "balance::split", 2);
    defer allocator.free(payload);

    const module = Bytecode.VerifiedModule{
        .name = "balance_split_exact_test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 100, 0, 0, 0, 0, 0, 0, 0 } }, // balance=100
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 100, 0, 0, 0, 0, 0, 0, 0 } }, // amount=100
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    defer if (result.return_value) |returned| returned.deinit(allocator);
    try std.testing.expect(result.success);
    const returned = result.return_value.?;
    try std.testing.expect(returned.tag == .vector);
    try std.testing.expectEqual(@as(i64, 0), returned.data.vector[0].data.int);
    try std.testing.expectEqual(@as(i64, 100), returned.data.vector[1].data.int);
    try std.testing.expectEqual(@as(i64, 100), returned.data.vector[0].data.int + returned.data.vector[1].data.int);
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
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 50, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 25, 0, 0, 0, 0, 0, 0, 0 } },
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
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 10, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 20, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 30, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .opcode = .ld_u64, .payload = &[_]u8{ 3, 0, 0, 0, 0, 0, 0, 0 } }, // count=3
            .{ .opcode = .vec_pack, .payload = &[_]u8{ 3, 0, 0, 0 } },
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 60), result.return_value.?.data.int);
}

test "public_transfer requires the owner and records the recipient" {
    const allocator = std.testing.allocator;
    const ObjectID = @import("../../src/core.zig").ObjectID;
    const ObjectEffect = @import("../../src/property/move_vm/Interpreter.zig").ObjectEffect;

    var reg = Registry.init(allocator);
    defer reg.deinit();
    try reg.registerSuiFramework();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 10000, .max_gas = 100000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    const sender: [32]u8 = @splat(0x11);
    const recipient: [32]u8 = @splat(0x33);
    var ctx = TxContext{
        .sender = sender,
        .tx_hash = @splat(4),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 10000,
    };

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;
    interpreter.tx_context = &ctx;

    const foreign_id = ObjectID{ .bytes = @as([32]u8, @splat(0x55)) };
    const foreign = try move_vm.Resource.init(foreign_id, .Coin, "1", @as([32]u8, @splat(0x22)), allocator);
    try tracker.track(foreign);
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = foreign_id.bytes, .type_tag = 1 } },
    });
    try interpreter.stack.append(allocator, .{
        .tag = .address,
        .data = .{ .address = recipient },
    });

    const payload = try buildCallPayload(allocator, "sui", "transfer::public_transfer", 2);
    defer allocator.free(payload);
    const module = Bytecode.VerifiedModule{
        .name = "transfer",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = payload },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.NotResourceOwner, interpreter.execute(module));
    try std.testing.expect(tracker.isTracked(foreign_id));
    interpreter.stack.clearRetainingCapacity();

    const owned_id = ObjectID{ .bytes = @as([32]u8, @splat(0x66)) };
    const owned = try move_vm.Resource.init(owned_id, .Coin, "1", sender, allocator);
    try tracker.track(owned);
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = owned_id.bytes, .type_tag = 1 } },
    });
    try interpreter.stack.append(allocator, .{
        .tag = .address,
        .data = .{ .address = recipient },
    });
    const transferred = try interpreter.execute(module);
    try std.testing.expect(transferred.success);
    try std.testing.expect(tracker.wasConsumed(owned_id));
    try std.testing.expectEqual(@as(usize, 1), transferred.object_effects.len);
    try std.testing.expectEqual(ObjectEffect.Kind.transfer, transferred.object_effects[0].kind);
    try std.testing.expect(std.mem.eql(u8, &transferred.object_effects[0].recipient, &recipient));
    try std.testing.expect(std.mem.eql(u8, &transferred.object_effects[0].object_id, &owned_id.bytes));
}

test "failed native call frees cloned vector arguments" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.registry = &reg;

    const elems = try allocator.alloc(Value, 1);
    elems[0] = .{ .tag = .integer, .data = .{ .int = 7 } };
    try interpreter.stack.append(allocator, .{ .tag = .vector, .data = .{ .vector = elems } });

    const payload = try buildCallPayload(allocator, "sui", "missing::func", 1);
    defer allocator.free(payload);
    const module = Bytecode.VerifiedModule{
        .name = "missing-native",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = payload },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.UnimplementedInstruction, interpreter.execute(module));
}
