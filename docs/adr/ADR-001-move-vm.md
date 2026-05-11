# ADR-001: Move VM as Execution Engine

**Status**: Accepted
**Date**: 2025-04
**Deciders**: zknot3 core team

---

## Context

zknot3 needs a safe, deterministic execution environment for smart contracts.
Candidates evaluated:

| VM | Pros | Cons |
|----|------|------|
| **EVM** | Largest ecosystem | No resource safety; reentrancy-prone; 256-bit only |
| **WASM** | General-purpose | Not asset-oriented; no native linear types |
| **Move VM** | Resource-oriented; linear types; bytecode verifier | Smaller ecosystem; newer tooling |
| **Lua VM** | Simple, embeddable | No type safety; garbage-collected |

## Decision

**Use Move VM** (resource-oriented programming model).

Move's linear type system provides compile-time guarantees that resources:
- Cannot be duplicated (no double-spend)
- Cannot be implicitly dropped (no lost assets)
- Must be explicitly moved or stored

This aligns with zknot3's design goal: **correctness over maximum compatibility**.

## Consequences

### Positive
- Resource safety prevents entire classes of smart contract bugs
- Bytecode verifier catches errors before execution
- Deterministic execution (same inputs → same state root)
- Gas metering prevents infinite loops

### Negative
- Smaller developer ecosystem than EVM
- Requires Move-specific tooling (compiler, SDK)
- Learning curve for developers familiar with Solidity

## Implementation

- `src/property/move_vm/Interpreter.zig` — stack-based bytecode interpreter (40+ opcodes)
- `src/property/move_vm/Bytecode.zig` — verifier with stack height + type checking
- `src/property/move_vm/Resource.zig` — linear type tracker
- `src/property/move_vm/Gas.zig` — monotonic gas metering
- `src/property/move_vm/values.zig` — value system with Container ref-counting
