# zknot3 System Invariants

> **Status**: Living document — any protocol change MUST update this file.
>
> These are the non-negotiable safety properties. Each invariant has a
> formal predicate and a designated enforcement point in the codebase.
> If any invariant is violated at runtime, the node MUST halt.

---

## Consensus Invariants

### I-1: Finalized Block Immutability
```
FORMAL:  ∀b ∈ Committed, ∀b' : b.round = b'.round ⇒ b.digest = b'.digest
PLAIN:   No two different blocks can be committed at the same round.
PROOF:   Theorem 1 (No Forking) in docs/protocol/safety-proofs.md
ENFORCE: Mysticeti.zig:tryCommit2Chain / tryCommit3Chain
```
Once a block is committed, its contents MUST NOT change. A committed block
digest is permanently fixed. There is no reorg mechanism.

### I-2: Quorum Certificate Validity
```
FORMAL:  Committed(b) ⇒ Stake(Votes(b)) ≥ ⌊2·total_stake/3⌋ + 1
PLAIN:   A block is committed iff it has > 2/3 stake-weighted votes.
PROOF:   Lemma 1 (Quorum Intersection)
ENFORCE: Mysticeti.zig:computeStake → b.stake_cache + threshold check
```
A commit certificate with insufficient stake MUST be rejected. The
`stake_cache` field provides O(1) access to the running total.

### I-3: Causal Parent Ordering
```
FORMAL:  ∀b ∈ DAG, ∀p ∈ b.parents : p < b.round
PLAIN:   A block can only reference rounds strictly earlier than its own.
ENFORCE: Mysticeti.zig:Block.create — parents must be < self.round
```
Violation would create a cycle in the DAG, breaking causal order.

### I-4: No Equivocation
```
FORMAL:  ∀v ∈ V, ∀r ∈ ℕ :
          |{b ∈ DAG[r] : ∃vote ∈ Votes(b), vote.voter = v}| ≤ 1
PLAIN:   A validator MUST NOT sign two different blocks at the same round.
ENFORCE: Mysticeti.zig:receiveVote — detects duplicate (voter, round)
```
Equivocation is detectable Byzantine behavior. Evidence is logged.

### I-5: Vote Signature Freshness
```
FORMAL:  ∀v ∈ Vote : ValidVote(v, v.block) = true
         where ValidVote ≡ Verify(pk(v.voter), v.block_digest, v.signature)
PLAIN:   Every vote MUST have a valid Ed25519 signature before insertion.
ENFORCE: Mysticeti.zig:receiveVote — calls vote.verifySignature() first
```
No vote enters the DAG without cryptographic verification.

---

## State Invariants

### S-1: Deterministic State Transition
```
FORMAL:  ∀validators a, b, ∀state₀, ∀[tx₁..txₙ] :
          ExecuteBlockₐ([tx₁..txₙ], state₀) = ExecuteBlock_b([tx₁..txₙ], state₀)
PLAIN:   Same initial state + same ordered txs = identical resulting state.
PROOF:   Theorem 3 (State Determinism)
ENFORCE: Executor.zig:executeWithContext — deterministic Move VM
```
All arithmetic is checked; no floating-point; no system time in execution.

### S-2: State Root Coverage
```
FORMAL:  StateRoot(S) = H(serialize(sorted({(id, obj) ∈ S})))
         ∀checkpoint c : c.state_root = StateRoot(S_c)
PLAIN:   The state root commits to ALL object changes since genesis.
ENFORCE: Checkpoint.zig:computeStateRoot — Merkle over all object changes
```
Object changes not reflected in the state root = invalid checkpoint.

### S-3: Resource Linearity
```
FORMAL:  ∀tx : input_resources(tx) = output_resources(tx) ∪ consumed_resources(tx)
         ∧ output_resources(tx) ∩ consumed_resources(tx) = ∅
PLAIN:   Every resource is created, moved, or consumed exactly once.
PROOF:   Theorem 4 (Resource Conservation)
ENFORCE: Resource.zig:checkLeaks + ResourceTracker.validate()
```
Resources cannot be duplicated (no double-spend), implicitly dropped, or dangle.

### S-4: Monotonic Gas Consumption
```
FORMAL:  ∀tx : 0 ≤ gas_used(tx) ≤ tx.gas_budget
         ∧ gas_used is monotonic (only increases during execution)
PLAIN:   Gas used never exceeds budget; gas accounting is strictly increasing.
ENFORCE: Gas.zig:consume — overflow-safe, @branchHint(.cold) on exhaustion
```
Gas exhaustion returns `error.OutOfGas` and halts execution immediately.

### S-5: Nonce Strict Ordering
```
FORMAL:  ∀sender s, ∀transactions tx₁, tx₂ from s :
          tx₁ executed before tx₂ ⇒ tx₁.sequence < tx₂.sequence
          ∧ tx₁.sequence + 1 = tx₂.sequence
PLAIN:   Transactions from a sender execute in strict nonce order, no gaps.
ENFORCE: Node.zig:sender_sequence: AutoArrayHashMap([32]u8, u64)
```
Nonce gaps or duplicates are rejected.

---

## Network Invariants

### N-1: Authenticated Message Processing
```
FORMAL:  ∀msg ∈ {Vote, Block, Transaction} :
          Processed(msg) ⇒ VerifySignature(msg) = true
PLAIN:   No message is processed before its signature is verified.
ENFORCE: Mysticeti.zig:receiveVote, Ingress.zig:verifyBatchParallel
```
Invalid signatures → message dropped before any state mutation.

### N-2: Per-Peer Rate Limiting
```
FORMAL:  ∀peer p, ∀second t :
          |messages_from(p, t)| ≤ p2p_max_messages_per_peer_per_second
PLAIN:   No peer may exceed the per-second message budget.
ENFORCE: P2P.zig:PeerManager — per-peer counter + ban on violation
```
Violators are banned for `p2p_peer_ban_seconds` (default 86400s).

### N-3: Handshake Nonce Uniqueness
```
FORMAL:  ∀(peer_id, nonce) : accepted_at_most_once(peer_id, nonce)
PLAIN:   Noise handshake nonces MUST NOT be reused.
ENFORCE: P2PServer.zig:HandshakeNonceTracker — tracks and rejects replays
```
Nonce replay = failed handshake = peer not added to routing table.

### N-4: Admin Auth for Write Endpoints
```
FORMAL:  ∀write_request : requireAdmin(request) ∧ ¬isAuthorized(request) ⇒ rejected(401)
PLAIN:   Write endpoints require X-Zknot3-Admin-Token when admin_token is set.
ENFORCE: HTTPServer.zig:687, AsyncHTTPServer.zig:393
```
Non-loopback bind without admin_token → node refuses to start.

---

## Mempool Invariants

### M-1: Transaction Deduplication
```
FORMAL:  ∀tx₁, tx₂ : tx₁.digest = tx₂.digest ⇒ at_most_one_processed(tx₁, tx₂)
PLAIN:   A transaction digest MUST NOT be processed more than once.
ENFORCE: Ingress.zig:seen_digests: AutoArrayHashMap([32]u8, void)
```
Duplicate submissions are silently dropped (dedup hit counter incremented).

### M-2: Mempool Bounded Size
```
FORMAL:  |mempool| ≤ max_pending
PLAIN:   The mempool cannot grow unbounded.
ENFORCE: Ingress.zig:submit — returns error.TooManyPending when full
```
Prevents memory exhaustion under transaction flood.

---

## Storage Invariants

### ST-1: Write-Ahead Logging
```
FORMAL:  ∀write(w, key, value) :
          Committed(w) ⇒ WAL.contains(entry(key, value))
PLAIN:   Every mutation is WAL-logged before or simultaneously with the in-memory write.
ENFORCE: LSMTree.zig:put — WAL append before MemTable insert
```
Crash recovery replays WAL entries not yet flushed to SSTable.

### ST-2: SSTable Immutability
```
FORMAL:  ∀sstable s : once_sealed(s) ⇒ s.content = constant
PLAIN:   Once written and sealed, an SSTable's contents never change.
ENFORCE: LSMTree.zig:flushMemtable — write-once, read-many
```
New data → new SSTable. Old SSTables deleted only after compaction merges them.

### ST-3: Checkpoint Chain Continuity
```
FORMAL:  ∀checkpoint c_i (i > 0) : c_i.previous_digest = H(c_{i-1})
PLAIN:   Each checkpoint cryptographically links to its predecessor.
ENFORCE: Checkpoint.zig:verify — previous_digest chain validation
```
Broken chain → node refuses to start until manually resolved.

### ST-4: WAL Corruption Detection
```
FORMAL:  ∀wal_entry e : CRC32(e.data) = e.checksum
PLAIN:   Every WAL entry has a CRC32 checksum for corruption detection.
ENFORCE: WAL.zig:append — CRC32 computed on write, verified on read
```
Corrupted entry → truncation at that point during recovery.

---

## Invariant Enforcement Summary

| # | Invariant | Type | Proof | Detection | Recovery |
|---|-----------|------|-------|-----------|----------|
| I-1 | No fork | Safety | Theorem 1 | Commit rule | N/A (prevented) |
| I-2 | Quorum validity | Safety | Lemma 1 | Threshold check | Reject certificate |
| I-3 | Causal parents | Safety | DAG property | Block.create | Reject block |
| I-4 | No equivocation | Safety | Detectable | receiveVote | Log evidence |
| I-5 | Vote authenticated | Safety | Ed25519 | verifySignature | Drop vote |
| S-1 | Deterministic state | Safety | Theorem 3 | Checked arithmetic | N/A (guaranteed) |
| S-2 | State root coverage | Safety | Hash function | computeStateRoot | Recompute root |
| S-3 | Resource linearity | Safety | Theorem 4 | checkLeaks | error.ResourceError |
| S-4 | Monotonic gas | Safety | Arithmetic | Gas.consume | error.OutOfGas |
| S-5 | Nonce ordering | Safety | Sequence | sender_sequence | Reject tx |
| N-1 | Msg authenticated | Safety | Ed25519 | verifySignature | Drop message |
| N-2 | Rate limiting | Liveness | Counter | Per-peer check | Ban peer |
| N-3 | Nonce unique | Safety | Tracker | HandshakeNonce | Reject handshake |
| N-4 | Admin auth | Safety | Token check | requireAdmin | 401 Unauthorized |
| M-1 | Tx dedup | Safety | Digest hash | seen_digests | Drop duplicate |
| M-2 | Mempool bounded | Liveness | Capacity | max_pending | Reject tx |
| ST-1 | WAL ordering | Safety | WAL property | LSMTree.put | WAL replay |
| ST-2 | SSTable immutable | Safety | Write-once | flushMemtable | N/A (design) |
| ST-3 | Checkpoint chain | Safety | Hash chain | verify | Halt node |
| ST-4 | WAL integrity | Safety | CRC32 | WAL.append | Truncate |

---

## Error Taxonomy

Every error in zknot3 falls into one of these categories:

| Category | Meaning | Invariant Risk | Node Action |
|----------|---------|----------------|-------------|
| **Fatal** | Irrecoverable state corruption | I-1, S-2, ST-3 | Exit immediately |
| **ConsensusViolation** | Fork, double-commit, invalid cert | I-1, I-2, I-4 | Halt consensus, alert operators |
| **Transient** | Network timeout, disk full, lock contention | None (temporary) | Retry with exponential backoff |
| **PeerFault** | Remote node sent invalid data | N-1, N-2 | Ban peer, log evidence |
| **ByzantineEvidence** | Provable equivocation or double-sign | I-4 | Record evidence, future slash |
| **InvalidInput** | Client-sent malformed tx or request | S-5, M-1 | Reject with error code |
| **ResourceExhausted** | OOM, fd limit, disk full | M-2, ST-1 | Graceful degrade or shutdown |
