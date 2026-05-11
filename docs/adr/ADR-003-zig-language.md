# ADR-003: Zig as Implementation Language

**Status**: Accepted
**Date**: 2025-03
**Deciders**: zknot3 core team

---

## Context

Blockchain nodes require:
- No garbage collection pauses (deterministic latency)
- Fine-grained memory control (avoid OOM in production)
- C ABI compatibility (link with RocksDB, blst, io_uring)
- Compile-time safety (catch errors before runtime)

Candidates:

| Language | Memory | Safety | Ecosystem | Learning |
|----------|--------|--------|-----------|----------|
| **Rust** | Ownership model | Strong | Large | Steep |
| **Go** | GC | Moderate | Large | Easy |
| **C++** | Manual | Weak | Largest | Steep |
| **Zig** | Manual + defer | Moderate | Growing | Moderate |

## Decision

**Use Zig** (currently 0.16.0).

Zig's unique advantages for blockchain systems:
- `defer`/`errdefer` for deterministic cleanup (no GC pauses)
- Explicit allocator passing (arena, fixed-buffer, page)
- Comptime code generation (zero-cost abstractions)
- `@branchHint(.cold)` for hot-path optimization
- Cross-compilation to any target from any host
- C ABI without bindings (direct `@cImport`)

## Key Patterns Used

```zig
// Allocator awareness — every allocation takes explicit allocator
const buf = try allocator.alloc(u8, size);
defer allocator.free(buf);

// Arena for batch deallocation (transaction execution)
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

// Checked arithmetic (no silent overflow)
const result, const overflow = @addWithOverflow(a, b);
if (overflow != 0) return error.ArithmeticOverflow;

// Comptime dispatch (zero-cost)
if (comptime builtin.os.tag == .linux) {
    // io_uring path
}
```

## Consequences

### Positive
- Predictable latency (no GC)
- Explicit memory ownership (easier to audit)
- Fast compile times (faster iteration than Rust)
- Minimal runtime (no heavy standard library)

### Negative
- Smaller ecosystem than Rust/Go
- Language still evolving (0.16.0, breaking changes between versions)
- Fewer blockchain reference implementations to learn from
- Developer hiring pool is smaller

## Mitigations

- Pinned Zig version in `build.zig.zon` with git hash
- CI matrix tests against current + next Zig version
- Comprehensive `CLAUDE.md` with build instructions and patterns
