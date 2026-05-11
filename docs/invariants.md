# zknot3 System Invariants

> **Status**: Living document — any protocol change MUST update this file.
>
> These are the non-negotiable safety properties of the system.
> If any invariant is violated, the node MUST halt (not continue).

---

## Consensus Invariants

### I-1: Finalized Block Immutability
```
Once a block is finalized (committed), its contents MUST NOT change.
A finalized block digest is permanently fixed and cannot be reorg'd.
```
**Enforcement**: `Mysticeti.zig:tryCommit` — committed blocks never removed from DAG.

### I-2: Unique Finalization Per Height
```
At most ONE block can be finalized at any given round/height.
Two conflicting finalized certificates at the same round = chain halt.
```
**Enforcement**: `Mysticeti.zig:tryCommit2Chain/tryCommit3Chain` — single commit per round.

### I-3: Quorum Certificate Validity
```
A commit certificate is valid iff it contains signatures from > 2/3
of total stake. Any certificate below this threshold MUST be rejected.
```
**Enforcement**: `Mysticeti.zig:computeStake` + threshold check.

### I-4: Causal Ordering of Parents
```
A block's parents MUST be from strictly earlier rounds.
A block cannot reference rounds >= its own round.
```
**Enforcement**: `Mysticeti.zig:Block.parents: []const Round` — parents < self.round.

### I-5: No Equivocation (Double-Vote)
```
A validator MUST NOT sign two different blocks at the same round.
Equivocation evidence MUST be detected and logged.
```
**Enforcement**: `Mysticeti.zig:receiveVote` — detects duplicate voter+round.

---

## State Invariants

### S-1: Deterministic State Transition
```
Given the same initial state and the same ordered transactions,
the resulting state root MUST be identical across all validators.
```
**Enforcement**: `Executor.zig:executeWithContext` — deterministic Move VM execution.

### S-2: State Root Coverage
```
The state root MUST commit to all object changes since genesis.
Any object modification not reflected in the state root is invalid.
```
**Enforcement**: `Checkpoint.zig:computeStateRoot` — Merkle over all object changes.

### S-3: Resource Linearity
```
Every Move resource MUST be consumed or moved exactly once.
Resources cannot be duplicated, dropped, or left dangling.
```
**Enforcement**: `Resource.zig:checkLeaks` + `ResourceTracker.validate()`.

### S-4: Gas Conservation
```
Total gas consumed by a transaction MUST NOT exceed its gas budget.
Gas accounting MUST be monotonic (only increases).
```
**Enforcement**: `Gas.zig:consume` — overflow-safe, monotonic.

---

## Network Invariants

### N-1: Signature Verification Before Processing
```
Every received vote, block, and transaction MUST have its signature
verified BEFORE being processed or inserted into any data structure.
```
**Enforcement**: `Mysticeti.zig:receiveVote`, `Ingress.zig:verifyBatchParallel`.

### N-2: Peer Message Rate Limiting
```
No single peer may exceed configured per-peer-per-second message limits.
Violators MUST be banned for the configured ban duration.
```
**Enforcement**: `P2P.zig:PeerManager` — per-peer tracking + ban mechanism.

### N-3: Handshake Nonce Uniqueness
```
Noise handshake nonces MUST NOT be reused.
Each (peer_id, nonce) pair MUST be tracked and rejected on replay.
```
**Enforcement**: `P2PServer.zig:HandshakeNonceTracker`.

---

## Mempool Invariants

### M-1: Transaction Nonce Strict Ordering
```
Transactions from the same sender MUST be executed in strict
nonce/sequence order. Nonce gaps or duplicates are rejected.
```
**Enforcement**: `Node.zig:sender_sequence` tracking.

### M-2: Transaction Deduplication
```
A transaction digest MUST NOT be processed more than once.
Duplicate submissions are silently dropped.
```
**Enforcement**: `Ingress.zig:seen_digests` hashmap.

---

## Storage Invariants

### ST-1: WAL Before MemTable
```
Every mutation MUST be written to the WAL BEFORE being applied
to the MemTable. Recovery replays uncommitted WAL entries.
```
**Enforcement**: `LSMTree.zig:put` — WAL write before MemTable insert.

### ST-2: SSTable Immutability
```
Once an SSTable is written and sealed, its contents MUST NOT change.
New data creates new SSTables; old ones are only deleted after compaction.
```
**Enforcement**: `LSMTree.zig:flushMemtable` — write-once, read-many.

### ST-3: Checkpoint Chain Continuity
```
Each checkpoint MUST reference the previous checkpoint's digest.
A broken checkpoint chain (missing or mismatched previous_digest)
MUST prevent node startup until manually resolved.
```
**Enforcement**: `Checkpoint.zig:verify` — previous_digest chain validation.

---

## Error Taxonomy

| Category | Meaning | Action |
|----------|---------|--------|
| **Fatal** | Irrecoverable state corruption | Node MUST exit immediately |
| **ConsensusViolation** | Invariant broken (fork, double-commit) | Halt consensus, alert operators |
| **Transient** | Temporary failure (network, disk full) | Retry with backoff |
| **PeerFault** | Remote peer misbehavior | Ban peer, log evidence |
| **ByzantineEvidence** | Provable malicious behavior | Record evidence, slash if enabled |
| **InvalidInput** | Client-sent bad data | Reject with error code |
| **ResourceExhausted** | OOM, disk full, fd exhaustion | Graceful degrade or shutdown |
