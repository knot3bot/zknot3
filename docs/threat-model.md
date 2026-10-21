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
- TCP accept and dial refuse a new peer when its IPv4 /16 already has `p2p_max_peers_per_16` connections (default 8; 0 disables the cap)
- TCP accept and dial refuse a new peer when its IPv6 /48 already has `p2p_max_peers_per_48` connections (default 8; 0 disables the cap); IPv4-mapped addresses share the IPv4 /16 budget
- Kademlia bucket selection enforces prefix diversity: at most `MAX_PEERS_PER_PREFIX` (default 4) peers per IPv4 /16, IPv6 /48, or the shared unresolved (hostname / unparseable) prefix inside each KBucket (`error.PrefixDiversityLimit`); IPv4-mapped addresses share the IPv4 /16 budget
- Reserved outbound-only slots (`p2p_reserved_outbound_slots`, default 8): inbound accept stops at `max_connections - reserved` so dials can still open recovery peers; outbound dial uses the full `max_connections` budget (0 disables)
- Periodic peer rotation (`p2p_peer_rotation_interval_secs`, default 600): force-disconnect the lowest-quality eligible peer (inbound preferred; quality = `reputation - min(latency_ms/10, 50)`, then oldest `connected_at`; last outbound / bootstrap address-hash protected when bootstrap is configured); zero disables
- Peer quality scoring for rotation preference: live `PeerConnection.reputation` / `latency_ms` (rate-limit drops lower reputation; admitted traffic recovers toward the ceiling)
- Outbound quality-weighted dial: on disconnect, remember `{address, reputation, latency_ms}` (cap 64, LRU); `maintainBootstrapConnections` fills leftover outbound slots by dialing the highest-`peerRotationQuality` remembered peer that is not connected and passes subnet caps; bootstrap list still has dial priority
- Dial / quality-memory hostname resolve: `resolveDialAddress` turns `hostname:port` into canonical `a.b.c.d:port` / `[v6]:port` via DNS when possible so TCP /16·/48 caps and quality-memory keys match numeric peers; Kademlia `PeerManager.addPeer` stores the resolved form when resolve succeeds
- Outbound-only fallback (`p2p_inbound_ratio_limit`, percent 0–100, default 80; 0 disables): the inbound side is published inbound TCP+QUIC peers plus in-flight inbound handshake workers (outbound dials are not included). When that inbound side plus published outbound peers is ≥ 4 and `inbound * 100 > total * limit`, new inbound TCP accepts and QUIC inbound connections are rejected (`error.InboundPaused`). Outbound `dial` still uses the reserved-slot budget, and `maintainBootstrapConnections` keeps dialing bootstrap peers and quality-weighted remembered peers
- Authenticated handshake listen trailer: optional `u16_be len` + UTF-8 `host:port` after the signed response (responder) and ack (initiator) cores (`network.p2p_advertise_address`, else dialable `p2p_address`); outbound dial string wins when both are present. An advertised dial string is quality-remembered only when the signer's Ed25519 public key is in `network.known_validators` (empty list stores none). When that validator's `dial_address` is non-empty, the advertised `host:port` must equal it literally; an empty `dial_address` still allows any signed advertise from that key. A dial string this node opened is remembered on disconnect regardless. Ed25519 covers `listen_commitment = Blake3(advertise_utf8)` (or 32 zero bytes when empty); verifier rebuilds commitment from trailer bytes. Unsigned request does not carry authoritative advertise. Authenticated path context `zknot3_p2p_handshake_v3` (breaking vs v2 signed transcript; unauthenticated handshake unchanged).

**Current Limitations**:
- Hostname dial/subnet now apply after DNS resolve; residual is weaker than before but still present without DNSSEC (spoofed answers can steer peers) and unresolved/unparseable names still share one Kademlia unknown-prefix budget (not geo-diverse)
- Nodes binding `0.0.0.0` without `p2p_advertise_address` still advertise nothing (inbound quality memory stays empty for those peers)
- Handshake-advertised dial strings enter quality memory only when the peer's Ed25519 public key is in `network.known_validators`. An empty set remembers none of them. Arbitrary advertise remains only when that validator has no configured `dial_address` (empty string); a non-empty `dial_address` is remembered only when the advertised `host:port` equals it literally. Addresses this node itself dialed are remembered on disconnect regardless.

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

**Severity**: HIGH (detected and punished on every node that accepts the evidence)

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
- Equivocation evidence is logged and broadcast on the certificate channel.
  Verified payloads are kept in a 16-slot ring and rebroadcast one at a time,
  every 30s by default (`equivocation_rebroadcast_interval_secs = 0` disables it)
- Conflicting votes are both rejected (neither counts toward quorum)
- The observing node slashes current M4 stake on a fixed curve: 10% on the
  first offense, 25% on the second, 50% on the third, 100% after that
- The loss is split pro-rata across that validator's delegations, and the
  resulting stake is copied into the local voting-power pool
- The same evidence digest is applied once
- Gossip on the certificate channel is applied only when both votes are
  Ed25519 signatures by the named voter over different block digests (`k3eq01`)
- After a slash the validator is jailed for 2 epochs on the first offense,
  3 on the second, and 5 after that. While jailed, its stake leaves both the
  active total and the quorum total, so the >2/3 threshold can still be met.
  Jail state is stored in the M4 snapshot tail (`m4jl`) and rebuilt when a
  slash record is replayed

**Current Limitations**:
- Recent evidence is rebroadcast, and a restart reloads the same 16-slot ring from `{data_dir}/m4_state.equiv.ring`. A node that never connects still cannot slash
- The slash is not a separately finalized cross-validator transaction

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
- IPv4 /16 cap on TCP accept and dial (`p2p_max_peers_per_16`, default 8)
- IPv6 /48 cap on TCP accept and dial (`p2p_max_peers_per_48`, default 8); IPv4-mapped addresses share the IPv4 /16 budget
- Reserved outbound-only slots (`p2p_reserved_outbound_slots`, default 8) so inbound flood cannot exhaust the peer table
- Periodic peer rotation (`p2p_peer_rotation_interval_secs`, default 600) force-replaces the lowest-quality eligible peer (`reputation - min(latency_ms/10, 50)`, age tiebreak) so surplus long-lived / low-quality inbound slots churn
- Peer quality scoring feeds rotation preference and outbound quality-weighted redial of remembered peers
- Handshake-advertised listen dial string (signature-bound trailer on authenticated response/ack via Blake3 listen_commitment) enters quality memory only when the peer public key is in the configured known-validator set, and only at that validator's `dial_address` when the operator set one (`advertise_address` / dialable `p2p_address` is what this node advertises)
- Outbound-only fallback when the inbound share (published inbound peers plus in-flight inbound handshakes) exceeds `p2p_inbound_ratio_limit` (default 80, minimum 4 peers; 0 disables): inbound TCP/QUIC accepts return `error.InboundPaused` while outbound dial, bootstrap maintenance, and quality redial continue

**Current Limitations**:
- After DNS resolve, hostname peers hit the same TCP /16·/48 and Kademlia IP-prefix caps as numeric peers; unresolved names still share one unknown-prefix budget. Residual: no DNSSEC, so poisoned DNS can still cluster peers
- Quality redial remembers a signed listen advertise only for peers in the configured known-validator set (empty set: advertised addresses are not remembered). Arbitrary advertise remains only when that validator has no configured `dial_address`; a non-empty `dial_address` pins the remembered `host:port` to that literal string. Outbound dials this node initiated stay rememberable. Set a real public `p2p_advertise_address` so known peers can redial this node.

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
- Signer check on `move_to_sender`, `move_from`, `borrow_global`, `delete_resource`, `public_transfer`, `share_object`, and `freeze_object`: a resource with an owner must belong to `TxContext.sender`, and a load of an unowned resource is refused unless the storage address is the signer. A transfer records the recipient on the execution result
- Stack depth limit: `max_depth` prevents stack overflow
- Locals bound: maximum 256 locals per function
- Vector size limit: `MAX_VEC_PACK = 4096`
- Zig memory safety: no buffer overflows, checked arithmetic

**Current Limitations**:
- No formal verification of the Move VM implementation
- Bytecode fuzz is a bounded in-process suite (`test/fuzz/interpreter_fuzz.zig`), not a continuous AFL/libFuzzer job
- Bytecode verifier is worklist-based (has not been formally proven correct)
- Unknown opcodes are rejected before the enum cast, so a hole in the opcode space does not panic the process

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
- Hardened sequence is recorded after quorum verify. Recent hardened digests are stored with that marker; this is still not a certificate chain, and light clients still pin a trusted hash.
- Light clients must be configured with a trusted checkpoint hash

---

## 3. Threat Summary Matrix

| Attack | Severity | Detected | Mitigated | Residual Risk |
|--------|----------|----------|-----------|---------------|
| Eclipse | HIGH | Partial | Partial | **MEDIUM** — TCP /16+/48 + reserved outbound slots + inbound-ratio outbound-only fallback (`p2p_inbound_ratio_limit` default 80, min 4 peers) + Kademlia prefix diversity + quality-aware rotation/redial incl. signature-bound listen trailer remembered only for configured known validators; hostname dial/subnet after DNS resolve (residual: no DNSSEC / unresolved unknown-prefix) |
| Replay | MEDIUM | Yes | Yes | LOW |
| Equivocation | HIGH | Yes | Yes, on every node that verifies the evidence | **MEDIUM** — recent evidence is rebroadcast; a node that never connects still cannot slash |
| Invalid DAG | MEDIUM | Yes | Yes | LOW |
| Spam/Resource | MEDIUM | Yes | Yes | LOW-MEDIUM |
| Peer Flooding | MEDIUM | Yes | Partial | **LOW-MEDIUM** — TCP /16+/48 + reserved outbound slots + inbound-ratio outbound-only fallback (`p2p_inbound_ratio_limit` default 80, min 4 peers) + Kademlia prefix/unresolved caps + quality-aware rotation/redial incl. signature-bound listen trailer remembered only for configured known validators; hostname dial/subnet after DNS resolve (residual: no DNSSEC / unresolved unknown-prefix) |
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
