# AGENTS.md — zknot3 Project

## Project Overview

**zknot3** is a Zig re-implementation of the Sui blockchain, guided by the "三源合恰" (物象性三源) philosophical framework. This repository contains both the design specification in `dev.md` and a full production-ready implementation under `src/`.

**Reference**: Full technical specification in `dev.md`

---

## Technology Stack

- **Language**: Zig 0.15+ (required)
- **Blockchain**: Sui (re-implementation target)
- **VM**: Move VM (Zig interpreter)
- **Consensus**: Mysticeti (DAG-based BFT)
- **Storage**: RocksDB + io_uring (custom LSM-Tree in Zig)
- **Formal Verification**: Coq 8.18+ / Lean 4
- **Fuzzing**: AFL++ with libFuzzer mode

---

## Project Structure (Proposed)

```
sui-zig/
├── build.zig                 # Build system entry
├── src/
│   ├── core/                  # [Taiji Layer] ObjectID, VersionLattice, Ownership
│   ├── form/                  # [Form Layer] storage/, network/, consensus/
│   ├── property/              # [Property Layer] move_vm/, access/, crypto/
│   ├── metric/                # [Metric Layer] Stake, Epoch, Metrics
│   ├── pipeline/              # [Sanjiao Layer] Ingress, Executor, Egress
│   └── app/                   # [Jiugong Layer] GraphQL, Indexer, ClientSDK
├── test/
│   ├── unit/, property/, fuzz/, formal/
└── tools/
    ├── verifier/, profiler/, codegen/
```

---

## Build Commands

```bash
# Full build with formal export
zig build -Doptimize=ReleaseFast -Dexport-formal=true

# Run tri-source metric tests
zig build test -- tri_source.wu_feng    # 物丰: resource efficiency
zig build test -- tri_source.xiang_da  # 象大: knowledge coverage  
zig build test -- tri_source.zi_zai    # 性自在: user satisfaction

# Export formal specs to Coq
zig build export-coq -- --output specs/consensus.v

# Local devnet (4 validators + 1 fullnode)
./build/sui-zig-node --network local --validators 4

# Profiler
./tools/profiler --metrics wu_feng,xiang_da,zi_zai --interval 5s
```

---

## Key Architectural Decisions

1. **Comptime-first verification**: Use Zig's `@compileAssert` for category-theoretic constraints (commutative groups, partial orders, linear types)
2. **io_uring for storage**: Async I/O with fixed buffers, zero-copy to user buffers
3. **Linear type system**: Compile-time enforcement of Move resource semantics (no cloning, no leaks)
4. **Quotient group consensus**: Model voting power as quotient groups for BFT safety proofs
5. **Three-layer metrics**: Always measure and optimize across 物丰/象大/性自在 dimensions

---

## Terminology

| Term | Meaning |
|------|---------|
| 三源合恰 | 物象性三源 — 形·性·数 unified framework |
| 形 | Spatial topology, computational state |
| 性 | Intrinsic attributes, relation contracts |
| 数 | Quantitative measures, ordinal evolution |
| 商集 | Quotient set — equivalence class partitioning for BFT quorums |
| 态射 | Morphism — state transition mapping |

---

## Current Status

This repo contains a **production-ready implementation** of the zknot3 node with all core components complete, tested, and deployable. The implementation includes:

- **Full source code** under `src/` (storage, network, consensus, Move VM, pipeline, app layer)
- **Docker-based devnet** with 4 validators + 1 fullnode (`deploy/docker/docker-compose.yml`)
- **Production stability fixes** applied for 13-hour freeze and double-free memory corruption (see `OPS.md` and `CLAUDE.md`)
- **Soak test monitoring** via `tools/soak_monitor.sh`

### Completed Milestones
1. **Core node bootstrap** — `Node.zig`, `Config.zig`, `ObjectStore.zig`, `LSMTree.zig`, `WAL.zig`
2. **Network layer** — `P2PServer.zig`, `HTTPServer.zig`, `QUIC.zig`, `Kademlia.zig`
3. **Consensus** — `Mysticeti.zig` DAG-based BFT with voting and certificate aggregation
4. **Move VM** — `Interpreter.zig`, `Gas.zig`, `Resource.zig`
5. **Pipeline** — `Ingress.zig`, `Executor.zig`, `Egress.zig`
6. **Production hardening** — socket timeouts, memory safety fixes, Docker deployment, soak testing


## Notes for Agents

- Source files exist under `src/` — when modifying, follow existing patterns and conventions
- When implementing, follow the directory structure in `dev.md` section "一、工程目录结构"
- Prioritize compile-time verification over runtime checks where possible
- The "三源指标" (Three Source Metrics) framework should be embedded in all performance measurements
- **Memory safety**: never call `allocator.destroy(self)` inside a `deinit()` method if the owner also destroys the object (see `PeerConnection` pattern in `P2PServer.zig`)
- **Network I/O**: always set read/write timeouts on sockets to prevent event loop freezes (see `setPeerTimeout` in `P2PServer.zig`)
- **Peer map safety**: re-validate peer pointers after any callback that might mutate the peers map (see `ConsensusIntegration.processPeerMessages`)

