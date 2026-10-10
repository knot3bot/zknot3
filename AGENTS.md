# AGENTS.md — zknot3 Project

## Project Overview

**zknot3** is a Zig re-implementation of the Knot3 blockchain, guided by the "三源合恰" (物象性三源) philosophical framework. This repository contains both the design specification in `dev.md` and a full production-ready implementation under `src/`.

**Reference**: Full technical specification in `dev.md`

---

## Technology Stack

- **Language**: Zig 0.17.0 (stable; `minimum_zig_version` pinned in `build.zig.zon`)
- **Blockchain**: Knot3 (re-implementation target)
- **VM**: Move VM (Zig interpreter)
- **Consensus**: Mysticeti (DAG-based BFT)
- **Storage**: io_uring + custom LSM-Tree (in Zig). No RocksDB — the LSM-Tree
  is implemented from scratch in `src/form/storage/LSMTree.zig`.
- **Formal Verification**: Coq 8.18+ / Lean 4
- **Fuzzing**: AFL++ with libFuzzer mode (harness present; not yet run in CI)

> **Verification honesty note**: the codebase has **no `@compileAssert`**. Earlier
> revisions of this file claimed "comptime-first verification" of category-theoretic
> constraints (commutative groups, partial orders, linear types). That was not
> implemented and the claim has been removed. What exists today is documented
> under "Key Architectural Decisions" below, item by item.

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
# Full build (ReleaseSafe recommended for long-running nodes)
zig build -Doptimize=ReleaseSafe

# Test suites
zig build test-unit          # fast unit tests (no I/O)
zig build test-integration   # full suite: unit + integration + e2e + Byzantine simulation (385 tests)
zig build test-formal        # 5 executable exhaustive proofs (quorum intersection, BFT bound, …)
zig build benchmark          # unit tests in ReleaseFast (throughput measurement)

# Formal specifications (machine-checked, fail-closed gates)
bash tools/formal/coq_gate.sh    # Rocq/Coq: 8 Qed theorems
bash tools/formal/lean_gate.sh   # Lean 4: 10 theorems, no sorry

# Formal spec export (prints the generated Coq source to stdout)
zig build export-coq

# Local devnet (4 validators + 1 fullnode, Docker)
cd deploy/docker && cp .env.example .env && docker compose up -d
bash tools/wan_emulation_gate.sh   # netem latency/loss/partition/healing gate

# Profiler (three-source metrics; binary lands in zig-out/bin)
zig build && ./zig-out/bin/zknot3-profiler -m wu_feng,xiang_da,zi_zai
```

CI pins Zig 0.17.0 stable (`minimum_zig_version = "0.17.0"` in `build.zig.zon`);
see `.github/workflows/ci.yml`.

---

## Key Architectural Decisions

Status legend: **done** = implemented and exercised by tests; **partial** =
implemented but narrower than the wording suggests; **planned** = not implemented.

1. **io_uring for storage** — **done**. `src/form/storage/IOUring.zig` (623 lines)
   with graceful fallback when io_uring is unavailable (restricted containers).
2. **Linear resource semantics** — **partial**. `src/property/move_vm/Resource.zig`
   tracks use-after-move at *runtime* via a `ResourceState` state machine; there is
   **no compile-time** enforcement. Its header comment claiming "compile-time
   verification" is inaccurate.
3. **Three-layer metrics** — **done**. 物丰/象大/性自在 measured in `src/metric/`
   and exposed on `/metrics`.
4. **Object-centric state with version lattice** — **done**. `src/core/VersionLattice.zig`,
   `src/core/Ownership.zig`.
5. **Single-source quorum threshold** — **done**. `src/form/consensus/QuorumConfig.zig`
   owns the only quorum formula in the tree; all call sites reference it.
6. **Compile-time category-theoretic constraints** — **planned, not implemented**.
   The `comptime` block in `Quorum.zig:244` only asserts that two methods *exist*;
   it does not verify any algebraic law.
7. **Quotient-group voting-power model** — **planned, not implemented**. "Quotient set"
   currently appears only in documentation comments, not as an algebraic structure.

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
3. **Consensus** — `Mysticeti.zig` DAG-based BFT: 2-chain/3-chain auto-selecting commit with elected-leader verification, BLS aggregate QuorumCertificate (signature + signer bitmap), view change via f+1 TimeoutVotes/TimeoutCertificate, equivocation evidence
4. **Move-style VM** — `Interpreter.zig`, `Gas.zig`, `Resource.zig` (zknot3-native bytecode; NOT Move-binary compatible) + `ModuleRegistry.zig` publish/upgrade lifecycle with immutable/compatible policies
5. **Pipeline** — `Ingress.zig`, `Executor.zig` (incl. PTB Publish handling), `Egress.zig`
6. **Production hardening** — socket timeouts, memory safety fixes, Docker deployment, soak testing
7. **Verification** — 385-test zig suite (unit+integration+e2e+Byzantine simulation, `zig build test-integration`), 10-test TypeScript SDK suite (`cd sdk/typescript && npm test`), executable formal proofs (`zig build test-formal`), machine-checked Coq (`tools/formal/coq_gate.sh`) and Lean 4 (`tools/formal/lean_gate.sh`) specifications


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

- `build.zig.zon` 声明 `minimum_zig_version` 为 `0.17.0`（2026-10-05 起，Zig 0.17.0 stable 发布即适配）；讨论异步能力时仍会对照较新 Zig 版本的语言级 async/await 与当前代码路径的差异。
- 存储层 `Checkpoint.digest()` 与 `signingCommitment()` 已统一为 Blake3(serialize())；Ed25519 验证路径逐签名者校验签名字节并按 stake 加权（2026-09-26 核实）。
- M4 状态恢复闭环已实现：`Node.recoverFromDisk → replayMainnetM4Wal` 重放 m4_* WAL 记录，`test/integration/m4_wal_recovery_test.zig` 覆盖重启重放、幂等、证据去重、截断 fail-closed、epoch 轮换。
- `Mysticeti.Block.computeDigest` 是唯一的块摘要公式（create 与 addBlock 共用）；digest 覆盖 author+round+payload+parents。
- TS SDK 依赖 `@noble/hashes`（纯 JS Blake3），测试用 node:test（`npm test`），不需要 jest。
- P2P 未认证握手由 `Config.allow_unauthenticated_p2p` 与 `P2PServerConfig.allow_unauthenticated_handshake` 控制，默认关闭；`Config.development()` 与 CLI `--dev` 会打开以便本地或旧 peer 兼容。
- 面向公网负载时，主循环与共识侧倾向于：限制每轮 `accept` 批量、对多 peer 合并 `poll`、对每轮消息处理设全局限额并做轮转扫描，以降低单连接饥饿与突发连接对共识处理的挤占。

