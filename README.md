# zknot3 — Protocol Specification & Reference Implementation

> **Status**: Research-grade prototype → Production hardening
>
> zknot3 is a correctness-first blockchain node. This document defines the
> **protocol**, not the implementation. The Zig codebase is a reference
> implementation of this protocol.

---

## 1. What Problem zknot3 Solves

Existing L1 blockchains trade off correctness for throughput. zknot3 inverts this:

| Problem | zknot3 Approach |
|---------|-----------------|
| Smart contract exploits (reentrancy, double-spend) | Move VM with linear types — resources cannot be duplicated or dropped |
| Non-deterministic execution across validators | Deterministic Move bytecode + checked arithmetic + monotonic gas |
| Silent state corruption on crash | WAL-before-MemTable ordering + checkpoint chain with cryptographic continuity |
| Unbounded memory growth under load | Arena allocation per transaction; LSM-Tree compaction with configurable levels |
| Leader bottleneck in consensus | Leaderless DAG-BFT (Mysticeti) — all validators propose in parallel |

**Performance is a consequence of correct design, not the goal.**

---

## 2. System Model

zknot3 is an **object-centric** blockchain. State is a key-value store of
**objects** (Move resources), not account balances.

```
Global State = { ObjectID → Object }

Object {
    id: ObjectID            // Blake3-256 cryptographic identifier
    owner: [32]u8           // Single owner (fast path) or 0x0 (shared, consensus path)
    type: []u8              // Move module::struct type tag
    data: []u8              // Move resource serialized bytes
    version: Version        // Monotonic sequence number per object
}
```

**Execution model**: Transactions read input objects, execute Move bytecode,
and produce output objects (created, modified, or deleted). State transitions
are deterministic: `execute(state₀, ordered_txs) → state₁` always produces
the same `state₁` on every validator.

---

## 3. Trust Model

| Assumption | Bound |
|-----------|-------|
| Honest validators | > 2/3 of total stake |
| Byzantine validators | < 1/3 of total stake |
| Network synchrony | Partial (timeout-based round advance) |
| Cryptographic assumptions | Blake3 (collision-resistant), Ed25519 (unforgeable), BLS12-381 (aggregate unforgeable) |
| Client trust | Clients trust validator set for state; light clients verify proofs independently |

A validator is **Byzantine** if it: equivocates (signs two blocks at the same round),
proposes invalid blocks, or withholds votes. The protocol detects equivocation;
slashing is planned but not yet implemented.

---

## 4. Consensus Model

**Mysticeti DAG-BFT** — a leaderless, DAG-based Byzantine Fault Tolerant consensus.

```
Round N-2    Round N-1    Round N      Round N+1
  [B1] ←───── [B3] ←───── [B5]
    ↓            ↓            ↓
  [B2] ←───── [B4] ←───── [B6]         ← any validator can propose
       ↓            ↓            ↓
  votes collected per block (stake-weighted)
       ↓
  Commit rule: 2-chain (≤20 vals) or 3-chain (>20 vals)
```

**Key properties**:
- **Leaderless**: No single proposer — any validator can propose in any round
- **Parallel proposal**: Multiple blocks per round, DAG edges define causal order
- **2-chain commit** (≤20 validators): Round N commits when N+1 has quorum → ~2 round latency
- **3-chain commit** (>20 validators): Leader block commits when N+1 and N+2 both support it → ~3 round latency
- **Equivocation detection**: Same validator signing two blocks at same round is detected and logged
- **Round timeout**: If no block reaches quorum within `round_timeout_secs` (5s), round auto-advances

Full specification: [docs/protocol/consensus.md](docs/protocol/consensus.md)

---

## 5. State Transition Model

### Transaction Structure
```
Transaction {
    sender: [32]u8          // Executing party (must sign)
    payer: ?[32]u8          // Optional gas sponsor
    inputs: []ObjectID       // Objects read by this transaction
    program: []u8            // Move bytecode
    gas_budget: u64          // Maximum gas units
    sequence: u64            // Per-sender monotonic nonce
    signature: ?[64]u8       // Ed25519 over digest
    bypass_consensus: bool   // Fast Path eligible
}
```

### Two Execution Paths

**Fast Path** (single-owner transactions, ~80-90% of traffic):
```
Client submit → Sig verify → Owner check → Execute immediately → Return result
Latency: <100ms (no consensus round)
```

**Consensus Path** (shared objects, ~10-20% of traffic):
```
Client submit → Sig verify → Mempool → Consensus ordering → Block exec → Commit
Latency: 2-3 round intervals
```

### State Root
```
state_root = Blake3(serialize(all object changes since genesis))
```
Computed deterministically from ordered transaction execution results.
Every validator must produce the identical state root.

Full specification: [docs/protocol/state-machine.md](docs/protocol/state-machine.md)

---

## 6. Validator Lifecycle

```
JOIN → ACTIVE → (SLASHED | UNSTAKING → EXITED)
```

| Phase | Trigger | Consensus Impact |
|-------|---------|-----------------|
| **Join** | Stake >= `min_validator_stake` | Added to validator set at next epoch boundary |
| **Active** | Participating normally | Proposes blocks, casts votes, collects rewards |
| **Equivocation** | Detected double-vote | Votes rejected for that round; evidence logged |
| **Timeout** | No activity for N rounds | Removed from active set (liveness fault) |
| **Unstaking** | Voluntary withdrawal request | Stake locked for `unstaking_period` (86400s = 1 day) |
| **Exited** | Unstaking period complete | Stake returned; no longer in validator set |

Epoch transitions (default 86400s) re-compute the validator set from the stake pool.
Within an epoch, the validator set is fixed.

---

## 7. Networking Protocol

### Stack
```
Application:  JSON-RPC (HTTP) + Gossip (P2P)
Encryption:   Noise XX (3-message handshake, HKDF key derivation)
Discovery:    Kademlia DHT (256 buckets, k=20, XOR distance)
Transport:    QUIC-style framing over TCP (future: real QUIC/UDP)
```

### Message Types
| Type | Code | Propagation | Purpose |
|------|------|-------------|---------|
| Transaction | 0x10 | Gossip (fanout=3) | New transaction |
| BlockProposal | 0x11 | Broadcast (all peers) | Consensus block |
| Vote | 0x12 | Broadcast (all peers) | Validator vote |
| BlockRequest | 0x20 | Request/Reply (1 peer) | Sync missing block |
| BlockResponse | 0x21 | Request/Reply (1 peer) | Block data |

### Rate Limiting
| Scope | Limit | Default |
|-------|-------|---------|
| Global HTTP | `max_requests_per_second` | 100 |
| Global HTTP connections | `max_concurrent_http_connections` | 256 |
| Per-peer P2P messages | `p2p_max_messages_per_peer_per_second` | 100 |
| Per-message-type | `p2p_max_messages_per_type_per_second` | 50 |
| Consensus messages/tick | `max_messages_per_tick` | 256 |
| Accepts/tick | `max_accepts_per_tick` | 16 |

Violations → ban for `p2p_peer_ban_seconds` (default 86400s = 24h).

### Auth Model
- Non-loopback bind requires `network.admin_token` to be set
- Write endpoints (`POST /tx`, write RPC methods) require `X-Zknot3-Admin-Token` header
- Read endpoints (`GET /health`, `/ready`, `/metrics`, read RPC) are public

Full specification: [docs/protocol/network.md](docs/protocol/network.md)

---

## 8. Storage Model

```
Write Path:
  Transaction → WAL (append + fsync) → MemTable (sorted) → SSTable (immutable)

Read Path:
  Bloom filter → MemTable (binary search) → SSTable[n] (binary search, newest first)

Compaction:
  Level 0 (64MB) → Level 1 (640MB) → Level 2 (6.4GB) ...
  Merge sort + dedup + rewrite → delete old SSTables
```

**Key properties**:
- **WAL-before-MemTable**: Every mutation is WAL-logged before the in-memory write
- **SSTable immutability**: Once written, SSTables are never modified; new data → new SSTable
- **Crash recovery**: On startup, replay WAL entries not yet flushed to SSTable
- **Checkpoint chain**: Each checkpoint's `previous_digest` links to the prior checkpoint
- **Bloom filter**: O(1) negative lookup (key-not-found) without touching SSTable index
- **CRC32 per record**: Corruption detection at the SSTable level

---

## 9. Failure Recovery

| Failure | Recovery Mechanism | Guarantee |
|---------|-------------------|-----------|
| Process crash | WAL replay on restart | All committed writes recovered |
| Disk corruption (SSTable) | Per-record CRC32 → skip corrupted record | Partial data loss, node continues |
| Disk corruption (WAL) | CRC32 checksum per entry → truncate at corruption | Loss of un-flushed entries only |
| Checkpoint corruption | `previous_digest` chain validation fails → halt | No silent state divergence |
| Network partition | Round timeout → advance round → re-sync on heal | Liveness preserved |
| OOM | Arena deinit per transaction | No persistent leak |
| FD exhaustion | Connection limit gating + LRU eviction | Graceful reject, no crash |

**Recovery flow on startup**:
```
Node.start()
  → Config.validate()
  → ObjectStore.recover()
    → LSMTree.recover()
      → WAL.replay(uncommitted entries)
      → SSTable index rebuild (if needed)
  → Checkpoint.verify(previous_digest chain)
  → M4 WAL replay (stake/governance/epoch state)
  → Node enters .running state
```

---

## 10. Determinism Guarantees

| Guarantee | Mechanism |
|-----------|-----------|
| Same state + same ordered txs = same state root | Move VM deterministic bytecode; no floating-point; no system time in execution |
| Arithmetic is overflow-safe | `@addWithOverflow` / `@subWithOverflow` etc. — all operations checked |
| Gas computation is deterministic | Static instruction cost table + data-size-dependent charging |
| Resource accounting is deterministic | Linear type tracking — every resource created, moved, or consumed exactly once |
| Signature verification is deterministic | Ed25519 RFC 8032; BLS12-381 standard |

**Anti-guarantees** (things that are NOT deterministic):
- Block proposal order (leaderless — any validator can propose)
- Transaction gossip arrival order (network-dependent)
- Mempool eviction order (gas-price-sorted, ties broken arbitrarily)

These do NOT affect state root because consensus establishes a total order
before execution.

---

## 11. Byzantine Assumptions

**Model**: Up to `f = ⌊(n-1)/3⌋` validators may be Byzantine (arbitrary behavior).

| Attack | Detected? | Mitigation |
|--------|-----------|------------|
| Equivocation (double-vote) | Yes | Votes rejected; evidence logged |
| Invalid block proposal | Yes | Block digest verified before voting |
| Vote withholding | Partial | Round timeout auto-advances |
| Eclipse attack (P2P) | Partial | Kademlia bucket diversity; bootstrap seeds |
| Sybil (validator set) | No | Stake-weighted voting limits influence |
| Long-range attack | No | Light client checkpoint trust model |

**Current limitations**:
- No automatic slashing (evidence logged, penalty not enforced)
- No fork-choice rule beyond "first committed wins"
- Eclipse resistance depends on bootstrap seed configuration

---

## 12. Replay Guarantees

**Full replay**: Given the genesis checkpoint and the ordered sequence of all
committed blocks, any node can reconstruct the identical state.

**Requirements for deterministic replay**:
1. Same genesis state (checkpoint 0)
2. Same ordered blocks (consensus output)
3. Same Move VM version (bytecode interpretation must match)
4. Same gas schedule (instruction costs must match)

**Replay is NOT deterministic if**:
- Blocks are reordered (violates consensus output)
- Move VM is upgraded to a version with different semantics
- Gas costs change between replay attempts

**Snapshot-based fast sync** (future): Download state snapshot at checkpoint N,
verify Merkle proof, then replay only blocks from N+1 onward.

---

## 13. Roadmap

### Completed (v0.13.0)
- [x] Mysticeti DAG-BFT consensus (2-chain + 3-chain, equivocation detection)
- [x] Move VM (40+ opcodes, linear types, bytecode verifier, type abilities)
- [x] Block-STM optimistic parallel execution (8-core default, auto retry)
- [x] LSM-Tree storage (WAL + MemTable + SSTable + compaction + Bloom filter)
- [x] Fast Path (single-owner tx bypass consensus, <100ms latency)
- [x] P2P networking (Kademlia + Noise XX + gossip + QUIC-style framing)
- [x] Concurrent Ed25519 signature verification (8-thread batch verify)
- [x] Production hardening (graceful shutdown draining, error logging, Docker HEALTHCHECK)
- [x] Protocol documentation suite (invariants, ADRs, consensus/state/network specs)

### In Progress
- [ ] Property-based testing (randomized state transition sequences)
- [ ] Byzantine simulation framework (malicious peer, partition, delayed gossip)
- [ ] Block author Ed25519 signature verification

### Planned
- [ ] Validator slashing (automatic penalty for equivocation)
- [ ] Market-based gas pricing (reference price + surge pricing, per-epoch)
- [ ] Snapshot-based fast sync (state snapshot + Merkle proof + incremental replay)
- [ ] Real QUIC/UDP transport (replace TCP framing with msquic/quiche integration)
- [ ] Narwhal-style data/consensus separation
- [ ] Archive node mode (full history, no pruning)
- [ ] State Merkle proofs for light client verification
- [ ] Validator delegation and reward distribution

---

## 14. Benchmarks

> Benchmarks measure the current implementation, not the protocol's theoretical
> limits. TPS depends on workload characteristics, validator count, and network
> topology.

### Single-Node Performance (8-core, localhost)

| Workload | TPS | Bottleneck |
|----------|-----|------------|
| Simple transfer (Fast Path, 8 threads) | ~90,000 | Ingress signature verification |
| Simple transfer (Fast Path, 4 threads) | ~50,000 | Ingress signature verification |
| Consensus path (1s round, 10K tx/block) | ~5,000 | Round interval |
| Consensus path (0.5s round, 5K tx/block) | ~5,000 | Round interval |

### Latency

| Path | P50 | P95 | P99 |
|------|-----|-----|-----|
| Fast Path (single-owner) | <100ms | <200ms | <500ms |
| Consensus Path (2-chain) | ~2s | ~3s | ~5s |
| Consensus Path (3-chain) | ~3s | ~5s | ~8s |

### Storage

| Metric | Value |
|--------|-------|
| Write amplification (LSM-Tree, level multiplier=10) | ~10x |
| MemTable insert latency (O(1) lazy-sort) | ~2μs |
| SSTable read (Bloom filter hit) | ~50μs |
| WAL append (group commit) | ~100μs |
| Checkpoint size (100K objects) | ~12MB |

### Resource Usage (idle / under load)

| Resource | Idle | 50K TPS |
|----------|------|---------|
| Memory (RSS) | ~200MB | ~2GB |
| CPU (8 cores) | <5% | ~80% |
| Disk I/O (WAL writes) | 0 | ~50MB/s |
| Network (P2P gossip) | <1Mbps | ~100Mbps |
| Open FDs | ~50 | ~500 |

### Build & Test

```bash
zig build -Doptimize=ReleaseSafe    # Clean build
zig build test                       # 358/361 pass
```

---

## Quick Start

```bash
# Prerequisites: Zig 0.17.0
git clone https://github.com/knot3bot/zknot3.git
cd zknot3
zig build -Doptimize=ReleaseSafe

# Development node (single validator, no P2P)
./zig-out/bin/zknot3-node --config ./deploy/config/devnet.toml

# Production validator
./zig-out/bin/zknot3-node --config ./deploy/config/mainnet.toml --validator
```

## Documentation Index

| Document | Contents |
|----------|----------|
| [Formal Specification](docs/protocol/formal-spec.md) | Mathematical protocol definition: primitives, consensus, state transition |
| [Safety & Liveness Proofs](docs/protocol/safety-proofs.md) | 6 theorems + proofs (no fork, determinism, recovery, Byzantine bound) |
| [System Invariants](docs/invariants.md) | 20 invariants with formal predicates + enforcement table |
| [Threat Model](docs/threat-model.md) | 9 attack vectors, security boundaries, mitigations, residual risk |
| [Consensus Spec](docs/protocol/consensus.md) | DAG-BFT: proposal, voting, commit rules, equivocation |
| [State Machine](docs/protocol/state-machine.md) | Transaction lifecycle, Fast Path, state root |
| [Network Protocol](docs/protocol/network.md) | Message types, peer lifecycle, gossip, rate limiting |
| [Architecture Overview](docs/architecture/system-overview.md) | Data flow diagram, module map |
| [ADR-001](docs/adr/ADR-001-move-vm.md) | Why Move VM over EVM |
| [ADR-002](docs/adr/ADR-002-dag-bft.md) | Why DAG-BFT over HotStuff |
| [ADR-003](docs/adr/ADR-003-zig-language.md) | Why Zig over Rust/Go |

## License

MIT
