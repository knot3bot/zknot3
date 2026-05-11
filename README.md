# zknot3 — A Correctness-First Blockchain Node in Zig

> **Status**: Research-grade prototype → Production hardening
>
> zknot3 is a blockchain node implementation prioritizing **correctness, determinism,
> and safety** over raw throughput. Built in Zig for predictable latency and explicit
> memory control.

## Why zknot3

Most blockchain projects optimize for TPS first. zknot3 optimizes for:

1. **Determinism** — Same state + same transactions = same state root. Always.
2. **Safety** — Resource linear types prevent double-spend at the VM level.
3. **Recoverability** — WAL + checkpoint chain ensures crash-consistent recovery.
4. **Observability** — Every error logged with context; silent failures are bugs.

Performance is a result of correct design, not the goal.

## Quick Start

```bash
# Prerequisites: Zig 0.16.0
zig build -Doptimize=ReleaseSafe
zig build test                    # 358/361 pass

# Run a dev node
./zig-out/bin/zknot3-node --config ./deploy/config/devnet.toml

# Run a validator
./zig-out/bin/zknot3-node --config ./deploy/config/mainnet.toml --validator
```

## System Architecture

```
P2P (Kademlia + Noise XX)
  ↓
Ingress (sig verify, gas check, nonce ordering)
  ↓
┌─────────────────────────────────────────────┐
│ Fast Path (single-owner)    Consensus Path  │
│ Execute immediately         Mysticeti DAG   │
│ <100ms latency              Propose→Vote→   │
│                             Commit (2-chain)│
└─────────────────────────────────────────────┘
  ↓
Executor (Block-STM parallel, Move VM, gas meter)
  ↓
ObjectStore (LSM-Tree + WAL + Checkpoint)
  ↓
State Root (Merkle over object changes)
```

Full architecture: [docs/architecture/system-overview.md](docs/architecture/system-overview.md)

## Safety Properties

zknot3 enforces these invariants at the protocol level. Violations cause node halt, not silent corruption:

| Invariant | Enforcement |
|-----------|-------------|
| One block per round (no forks) | DAG commit rule |
| Resources cannot be duplicated | Move VM linear types |
| State root is deterministic | `execute(state₀, txs) → state₁` |
| WAL-before-MemTable ordering | LSMTree write path |
| Checkpoint chain continuity | `previous_digest` validation |
| No equivocation (double-vote) | `receiveVote` detection |
| Signature verified before processing | Ingress + Mysticeti gates |

Full invariants: [docs/invariants.md](docs/invariants.md)

## Protocol Documentation

| Document | Contents |
|----------|----------|
| [Consensus Spec](docs/protocol/consensus.md) | Mysticeti DAG-BFT: proposal, voting, commit rules, equivocation |
| [State Machine](docs/protocol/state-machine.md) | Transaction lifecycle, Fast Path, state root computation |
| [Network Protocol](docs/protocol/network.md) | Message types, peer lifecycle, gossip, rate limiting, HTTP API |
| [System Invariants](docs/invariants.md) | Non-negotiable safety properties + error taxonomy |
| [Architecture Overview](docs/architecture/system-overview.md) | Data flow diagram, module map, design decisions |

## Architecture Decision Records

| ADR | Decision | Rationale |
|-----|----------|-----------|
| [ADR-001](docs/adr/ADR-001-move-vm.md) | Move VM over EVM | Resource safety via linear types |
| [ADR-002](docs/adr/ADR-002-dag-bft.md) | DAG-BFT over HotStuff | Leaderless = higher throughput + no censorship vector |
| [ADR-003](docs/adr/ADR-003-zig-language.md) | Zig over Rust/Go | No GC, explicit memory, C ABI, comptime |

## Error Taxonomy

All errors in zknot3 fall into one of these categories:

| Category | Meaning | Node Action |
|----------|---------|-------------|
| `Fatal` | State corruption | Exit immediately |
| `ConsensusViolation` | Fork, double-commit | Halt consensus, alert |
| `Transient` | Network, disk full | Retry with backoff |
| `PeerFault` | Remote misbehavior | Ban peer, log evidence |
| `ByzantineEvidence` | Provable attack | Record, slash (future) |
| `InvalidInput` | Bad client data | Reject with error code |
| `ResourceExhausted` | OOM, fd exhaustion | Graceful degrade |

## Production Readiness

### What's Solid
- **Crash recovery**: WAL replay + checkpoint chain verification
- **Memory safety**: Zig's ownership model + arena allocation per transaction
- **Deterministic execution**: Move VM + checked arithmetic + monotonic gas
- **Operational**: Signal handlers, graceful shutdown draining, health/ready endpoints
- **Security**: Noise XX encryption, Ed25519 signatures, BLS aggregation
- **Rate limiting**: Per-peer + per-message-type + global request caps
- **Soak tested**: 24-hour continuous runs, 13-hour freeze bug identified and fixed

### Known Gaps
- Block author signatures not yet verified (protocol upgrade pending)
- Test coverage at ~60% (property-based tests and Byzantine simulation needed)
- No validator slashing mechanism
- Static gas pricing (market-based pricing planned)

## Key Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| Zig | 0.16.0 | Compiler + standard library |
| blst | git:3f4bcc1 | BLS12-381 signatures |

## License

MIT
