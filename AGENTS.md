# AGENTS.md — zknot3 Project

## Project Overview

**zknot3** is a Zig re-implementation of the Knot3 blockchain, guided by the "三源合恰" (物象性三源) philosophical framework. This repository contains both the design specification in `dev.md` and a full production-ready implementation under `src/`.

**Reference**: Full technical specification in `dev.md`

---

## Technology Stack

- **Language**: Zig 0.15+ (required)
- **Blockchain**: Knot3 (re-implementation target)
- **VM**: Move VM (Zig interpreter)
- **Consensus**: Mysticeti (DAG-based BFT)
- **Storage**: RocksDB + io_uring (custom LSM-Tree in Zig)
- **Formal Verification**: Coq 8.18+ / Lean 4
- **Fuzzing**: AFL++ with libFuzzer mode

---

## Project Structure (Proposed)

```
zknot3/
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
./build/zknot3-node --network local --validators 4

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

## Learned User Preferences

- 使用中文撰写面向用户的技术说明、审计结论与变更摘要。

## Learned Workspace Facts

- `package.zig.zon` 声明 `minimum_zig_version` 为 `0.15.0`；讨论异步能力时仍会对照较新 Zig 版本的语言级 async/await 与当前代码路径的差异。
- 存储层 `Checkpoint.verify` 在简化路径下可按 stake 对签名者计数，但不校验 BLS 签名字节；`digest()` 与 `serialize()` 的承诺范围不一致，接入真实共识签名前需统一 canonical commitment。
- M4 `MainnetExtensionHooks` 的 slash、governance、evidence 等状态主要在内存；`Node.recoverFromDisk` 仅走 `ObjectStore.recover()`，`checkpoint_store` 与 `Config.checkpoint_store_path` 尚未形成 M4 状态的 WAL+checkpoint 恢复闭环。
- P2P 未认证握手由 `Config.allow_unauthenticated_p2p` 与 `P2PServerConfig.allow_unauthenticated_handshake` 控制，默认关闭；`Config.development()` 与 CLI `--dev` 会打开以便本地或旧 peer 兼容。
- 面向公网负载时，主循环与共识侧倾向于：限制每轮 `accept` 批量、对多 peer 合并 `poll`、对每轮消息处理设全局限额并做轮转扫描，以降低单连接饥饿与突发连接对共识处理的挤占。

