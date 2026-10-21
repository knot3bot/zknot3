# Contracts

The VM runs zknot3 bytecode. It is not a Move binary VM, and there is no Move source compiler. Modules are published as bytecode through PTB `Publish`. Upgrade policy is `immutable`, `compatible`, or `free` (`ModuleRegistry.zig`). Resource tracking follows the Move idea that a resource is moved, not copied. Enforcement is at runtime.

## Pieces

| Piece | File | Role |
|-------|------|------|
| Interpreter | `src/property/move_vm/Interpreter.zig` | stack bytecode |
| Bytecode | `src/property/move_vm/Bytecode.zig` | opcodes and the verifier |
| Gas | `src/property/move_vm/Gas.zig` | budget |
| Resources | `src/property/move_vm/Resource.zig` | linear-resource state at runtime |
| Debugger | `src/property/move_vm/Debugger.zig` | debug hooks |
| Governance | `src/property/move_vm/Governance.zig` | governance calls |

`contract_test.zig` covers arithmetic, boolean ops, gas exhaustion, resource tracking, an ERC-20-shaped token (supply, balance, transfer, approve, transferFrom), and nested expressions.

## Samples

Addition, 7 + 3:

```zig
const bytecode = &.{
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, // 7
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // 3
    0x40, // add
    0x01, // ret
};
```

5! = 120, as a chain of multiplies:

```zig
const bytecode = &.{
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // 5
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, // 4
    0x42, // mul
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // 3
    0x42, // mul
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, // 2
    0x42, // mul
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // 1
    0x42, // mul
    0x01, // ret
};
```

Token-shaped snippets. These return constants or a subtraction. They are not a token implementation.

```zig
// total supply 1000000
const total_supply = &.{
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x40,
    0x01,
};

// balance 500
const balance_of = &.{
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4,
    0x01,
};

// 500 - 200
const transfer = &.{
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4,
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC8,
    0x41, // sub
    0x01,
};
```

## What the interpreter does

Same inputs, same outputs. No hidden randomness. The verifier runs before execution. Each opcode spends gas from a budget. `Resource.zig` rejects use-after-move at runtime. It does not prove that at compile time.

Opcodes include add, sub, mul, div, mod, and, or, not, xor, comparisons, `br` / `br_true` / `br_false`, and `move_to` / `move_from` / `borrow_global`.

## Calling it

```zig
const allocator = std.testing.allocator;

const gas_config: Gas.GasConfig = .{
    .initial_budget = 1000,
    .max_gas = 10000,
};
var gas = Gas.GasMeter.init(gas_config);
var tracker = ResourceTracker.init(allocator);
defer tracker.deinit();

var interpreter = try Interpreter.init(allocator, &gas, &tracker);
defer interpreter.deinit();
```

```zig
var verifier = BytecodeVerifier.init(allocator);
var module = try verifier.verify(bytecode);
defer module.deinit(allocator);

const result = try interpreter.execute(module);
try std.testing.expect(result.success);
```

```zig
if (result.success) {
    if (result.return_value) |ret| {
        switch (ret.tag) {
            .integer => std.debug.print("Result: {d}\n", .{ret.data.int}),
            .boolean => std.debug.print("Result: {}\n", .{ret.data.bool}),
            else => {},
        }
    }
    std.debug.print("Gas consumed: {d}\n", .{result.gas_consumed});
} else {
    std.debug.print("Execution failed: {}\n", .{result.err});
}
```

Tests in the VM cover arithmetic, factorial, boolean ops, gas exhaustion, resource tracking, rejected opcodes, nested expressions, and the token-shaped snippets above.

Not in this tree: a Move source compiler, a Move standard library, and Move-binary compatibility. Sui's VM is a different codebase.
