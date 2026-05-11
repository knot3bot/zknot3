# zknot3 Threat Model

> **Security boundary**: zknot3 is safe under ≤ 1/3 Byzantine validators.
> Attacks beyond this threshold are out of scope.

---

## 1. Security Boundaries

```
┌─────────────────────────────────────────────────────────┐
│                    TRUSTED: Validator Node              │
│  ┌─────────┐  ┌──────────┐  ┌────────┐  ┌───────────┐  │
│  │ Storage │  │ Move VM  │  │Consensus│  │Network    │  │
│  │(LSM+WAL)│  │(sandbox) │  │(DAG-BFT)│  │(Noise XX) │  │
│  └─────────┘  └──────────┘  └────────┘  └───────────┘  │
└─────────────────────────────────────────────────────────┘
                          │
              ┌───────────┴───────────┐
              │                       │
    UNTRUSTED: Peer Nodes    UNTRUSTED: Client (RPC)
    (≤ 1/3 Byzantine ok)     (any behavior ok)
```

### Trust Assumptions

| Component | Trust Level | Rationale |
|-----------|-------------|-----------|
| Local disk | Trusted | Physical security assumed |
| Local memory | Trusted | Process isolation |
| Move VM sandbox | Trusted | Bytecode verifier + gas meter |
| Consensus protocol | Trusted up to f Byzantine | Formal safety proof |
| Peer validators | Untrusted | Validate all messages |
| Client (RPC) | Untrusted | Auth required for writes |
| Network (Internet) | Untrusted | Noise XX encryption |

---

## 2. Attack Model

### A1: Eclipse Attack

**Description**: Attacker isolates a victim node from the honest network by
occupying all its peer slots with malicious nodes.

**Severity**: HIGH

**Preconditions**:
- Attacker controls many IP addresses
- Victim's bootstrap peers are not well-configured

**Impact**:
- Victim sees attacker-controlled chain (can be fed false blocks)
- Victim cannot participate in consensus

**Mitigations**:
- Kademlia bucket diversity: 256 buckets, k=20, XOR distance ensures spread
- Bootstrap seed peers: configurable list of trusted initial peers
- `p2p_peer_ban_seconds`: automatic ban for rate-limit violators
- Connection pool reuse: limits churn, makes eclipse harder

**Current Limitations**:
- No peer rotation enforcement (long-lived connections favored)
- No outbound-only connection mode for eclipse recovery
- No IP diversity requirement (attacker with /16 can fill many buckets)

**Planned Mitigations**:
- Periodic peer rotation (force-replace oldest peer every N minutes)
- Outbound-only fallback mode when inbound ratio suspicious
- IP prefix diversity check in Kademlia bucket selection

---

### A2: Replay Attack

**Description**: Attacker captures a valid signed message (transaction, vote,
block) and re-sends it later to cause duplicate processing.

**Severity**: MEDIUM (mostly mitigated)

**Variants**:

| Variant | Target | Mitigation |
|---------|--------|------------|
| Transaction replay | Mempool | `seen_digests` hashmap dedup; sequence nonce rejects re-execution |
| Vote replay | Consensus | `Votes` hashmap per block: `voter` key prevents duplicate counting |
| Block replay | DAG | `block_index` hashmap by digest prevents duplicate insertion |
| Handshake replay | P2P | `HandshakeNonceTracker` rejects reused nonces |

**Residual Risk**: LOW
- Digest-based dedup is computationally infeasible to bypass (Blake3 collision resistance)
- Nonce tracking is strict (monotonic per-sender)

---

### A3: Equivocation Attack

**Description**: A Byzantine validator signs two different blocks (or votes)
at the same round, attempting to create a fork.

**Severity**: HIGH (detected, not yet punished)

**Execution**:
1. Validator V proposes block B₁ at round r, signs and broadcasts
2. Simultaneously, V proposes block B₂ at round r, signs and broadcasts
3. Different parts of the network see different blocks

**Detection**: `Mysticeti.receiveVote()` compares `(voter, round)` against
existing votes. If a different block_digest is found for the same `(voter, round)`:
```
∃ v₁, v₂ ∈ DAG[r] :
  v₁.voter = v₂.voter  ∧  v₁.block_digest ≠ v₂.block_digest
⇒ EquivocationEvidence(V, r)
```

**Current Mitigations**:
- Equivocation evidence is logged
- Conflicting votes are both rejected (neither counts toward quorum)
- Honest validators see both votes and can detect

**Current Limitations**:
- No automatic slashing (evidence logged, penalty not enforced)
- No automatic evidence gossip to other validators
- Equivocating validator retains stake and can equivocate again

**Planned Mitigations**:
- Automatic slashing: equivocation evidence → stake penalty
- Evidence gossip: detected equivocation broadcast to all validators
- Equivocation jail: validator banned from consensus for N epochs

---

### A4: Invalid DAG / Structure Attack

**Description**: Attacker submits malformed blocks to corrupt the DAG structure.

**Variants**:

| Attack | Description | Detection | Mitigation |
|--------|-------------|-----------|------------|
| Future parent | Block references round > self.round | `WellFormed(b)` check | Reject block |
| Self-parent | Block references self.round | `∀p ∈ parents : p < round` | Reject block |
| Invalid digest | Block digest ≠ H(author||round||payload) | Digest recomputation | Reject block |
| Payload overflow | Block payload exceeds limits | `max_txs_per_block` check | Reject block |
| Duplicate digest | Same block submitted twice | `block_index` hashmap | Drop duplicate |
| Missing parent | Block references non-existent round | DAG lookup failure | Buffer block, request parent |

**Residual Risk**: LOW — all structural invariants checked at ingress.

---

### A5: Spam / Resource Exhaustion

**Description**: Attacker floods the node with valid-looking messages to exhaust
CPU, memory, disk, or file descriptors.

**Severity**: MEDIUM

**Attack Vectors**:

| Vector | Limit | Default | Overflow Behavior |
|--------|-------|---------|-------------------|
| HTTP requests | `max_requests_per_second` | 100/s | 429 Too Many Requests |
| HTTP connections | `max_concurrent_http_connections` | 256 | 503 Service Unavailable |
| HTTP body size | `max_request_body_size` | 1MB | 413 Payload Too Large |
| P2P messages (per peer) | `p2p_max_messages_per_peer_per_second` | 100/s | Ban for 24h |
| P2P messages (per type) | `p2p_max_messages_per_type_per_second` | 50/s | Ban for 24h |
| Consensus messages/tick | `max_messages_per_tick` | 256 | Drop excess |
| P2P connections | `max_peers` | 50 | Reject new connections |
| P2P accepts/tick | `max_accepts_per_tick` | 16 | Queue, process next tick |
| Mempool | `max_pending` | 10000 | `error.TooManyPending` |
| WAL size | Rotates on checkpoint | — | Truncate after checkpoint save |
| MemTable size | `memtable_size` | 64MB | `error.MemTableFull` → flush to SSTable |
| DAG rounds | `max_committed_blocks` | 10000 | Prune oldest rounds |
| Gossip LRU | 10000 entries per type | — | FIFO eviction |

**Residual Risk**: LOW-MEDIUM
- All resource paths are bounded
- DAG pruning prevents unbounded memory growth
- Gaps: no WAL size-based automatic rotation (only checkpoint-triggered)

---

### A6: Peer Flooding (DDoS)

**Description**: Attacker opens many P2P connections from different IPs to
exhaust the node's connection slots and prevent honest peers from connecting.

**Severity**: MEDIUM

**Mitigations**:
- `max_peers` limit (default 50)
- `max_accepts_per_tick` (16 per event-loop iteration)
- Ban on rate-limit violation (24h default)
- Connection pool reuse (reduces handshake overhead)
- Per-peer message budgets

**Current Limitations**:
- No IP-based connection limits (attacker with many IPs can fill all 50 slots)
- No peer quality scoring (all peers treated equally)
- No inbound/outbound ratio enforcement

**Planned Mitigations**:
- IP prefix diversity requirement (max N peers from same /16)
- Peer quality scoring (uptime, message validity ratio, response time)
- Reserve outbound-only slots for eclipse recovery

---

### A7: State Corruption (Disk)

**Description**: Attacker with filesystem access modifies or corrupts stored state.

**Severity**: LOW (assumes trusted local disk)

**Detection**:
- SSTable per-record CRC32 checksums: corruption detected on read
- WAL entry CRC32: corruption detected on recovery, truncation at bad entry
- Checkpoint `previous_digest` chain: broken chain halts node

**Impact**:
- CRC32 mismatch → skip corrupted record (SSTable) or truncate (WAL)
- Checkpoint chain break → node refuses to start (requires manual recovery)

---

### A8: Move VM Sandbox Escape

**Description**: Attacker crafts Move bytecode that escapes the VM sandbox
(memory corruption, arbitrary code execution).

**Severity**: CRITICAL (if possible)

**Mitigations**:
- Bytecode verifier: all code verified before execution (opcode validity, stack height, type checking)
- Gas metering: every instruction costs gas, preventing infinite loops
- Resource linearity: resources cannot be leaked across transaction boundaries
- Stack depth limit: `max_depth` prevents stack overflow
- Locals bound: maximum 256 locals per function
- Vector size limit: `MAX_VEC_PACK = 4096`
- Zig memory safety: no buffer overflows, checked arithmetic

**Current Limitations**:
- No formal verification of the Move VM implementation
- No fuzzing harness for the bytecode interpreter
- Bytecode verifier is worklist-based (has not been formally proven correct)

**Planned Mitigations**:
- Differential fuzzing against reference Move VM (diem/aptos)
- Formal verification of safety-critical opcodes (move_resource, borrow_field)
- Sandbox process isolation (run VM in separate process with seccomp)

---

### A9: Long-Range Attack

**Description**: Attacker creates a fork from an old checkpoint, builds a longer
alternative chain, and presents it to new nodes.

**Severity**: LOW (requires > 2/3 stake + checkpoint trust model)

**Mitigations**:
- Checkpoint chain continuity: `previous_digest` links prevent silent reorg
- Light client checkpoint trust: clients pin to a recent trusted checkpoint
- Stake-weighted voting: attacker needs > 2/3 stake to finalize

**Current Limitations**:
- No checkpoint finality gadget (no "hardened" checkpoints)
- Light clients must be configured with a trusted checkpoint hash

---

## 3. Threat Summary Matrix

| Attack | Severity | Detected | Mitigated | Residual Risk |
|--------|----------|----------|-----------|---------------|
| Eclipse | HIGH | Partial | Partial | **MEDIUM** — IP diversity needed |
| Replay | MEDIUM | Yes | Yes | LOW |
| Equivocation | HIGH | Yes | Partial | **MEDIUM** — slashing not enforced |
| Invalid DAG | MEDIUM | Yes | Yes | LOW |
| Spam/Resource | MEDIUM | Yes | Yes | LOW-MEDIUM |
| Peer Flooding | MEDIUM | Yes | Partial | **MEDIUM** — no IP diversity |
| State Corruption | LOW | Yes | Yes | LOW |
| VM Sandbox Escape | CRITICAL | Partial | Partial | **LOW** — defense in depth |
| Long-Range | LOW | N/A | Partial | LOW |

---

## 4. Security Guarantees (Formal Boundaries)

```
G1: CONSENSUS SAFETY
    Under ≤ ⌊(n-1)/3⌋ Byzantine validators:
    No two honest validators commit different blocks at the same round.

G2: STATE DETERMINISM
    Under any validator behavior:
    Honest validators produce identical state roots for the same ordered blocks.

G3: RESOURCE CONSERVATION
    Under any transaction:
    Resources are never duplicated, implicitly dropped, or double-spent.

G4: SIGNATURE NON-REPUDIATION
    Under Ed25519 unforgeability:
    A valid signature proves the signer authorized the message.

G5: REPLAY RESISTANCE
    Under any network adversary:
    Replayed messages cannot cause duplicate state transitions.

G6: CRASH RECOVERY
    Under crash-stop failures (not disk corruption):
    All committed state is recoverable from WAL + checkpoint.
```

---

## 5. Out-of-Scope Threats

These threats are explicitly NOT mitigated by the current protocol:

- **> 1/3 Byzantine validators**: Safety may break (fork possible)
- **Physical access to node**: Attacker can read private keys, modify disk
- **Compiler backdoor**: Trust the Zig compiler and blst library
- **Side-channel attacks**: Timing, power analysis on Ed25519 signing
- **Quantum attacks**: Ed25519 and BLS12-381 are not post-quantum secure
- **Network-level DDoS**: Volumetric attacks must be mitigated at infrastructure level
