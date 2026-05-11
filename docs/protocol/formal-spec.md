# zknot3 Formal Protocol Specification

> This document defines the protocol using precise notation.
> In case of any discrepancy between this spec and the implementation,
> this spec is authoritative.

---

## 1. Basic Definitions

### 1.1 Cryptographic Primitives

```
H(x)         Blake3-256 hash of x
H(x) ∈ {0,1}²⁵⁶

Sign(sk, m)  Ed25519 signature of message m under secret key sk
Sign(sk, m) ∈ {0,1}⁵¹²

Verify(pk, m, σ) ∈ {true, false}
  Ed25519 verification of signature σ on message m under public key pk

BLS_Sign(sk, m)   BLS12-381 signature
BLS_Aggregate({σᵢ}) → σ_agg    BLS signature aggregation
BLS_VerifyAgg({pkᵢ}, m, σ_agg) ∈ {true, false}
```

### 1.2 Time Model

```
Round r ∈ ℕ           Consensus rounds, starting from 0
Time t ∈ ℝ⁺           Wall-clock time in seconds
Δ                     Maximum network delay (GST model: Δ finite after GST)
```

### 1.3 Validator Set

```
V = {v₁, ..., vₙ}     Set of n validators
stake(v) ∈ ℕ           Stake of validator v
total_stake = Σᵥ stake(v)
f = ⌊(n-1)/3⌋          Maximum Byzantine validators tolerated

Quorum(v) ≡ stake(v) ≥ ⌊2·total_stake/3⌋ + 1
```

---

## 2. Consensus Formalization

### 2.1 Block

```
Block = (author, round, payload, parents, digest)
  where:
    author ∈ {0,1}²⁵⁶          Validator identifier
    round ∈ ℕ                    Consensus round
    payload ∈ {0,1}*             Serialized transactions
    parents ⊂ ℕ                  Prior round numbers (|parents| ≤ 2)
    digest = H(author || round || payload)

WellFormed(b) ≡
  ∀p ∈ b.parents : p < b.round  ∧
  b.digest = H(b.author || b.round || b.payload)
```

### 2.2 Vote

```
Vote = (voter, block_digest, round, stake, signature)
  where:
    voter ∈ {0,1}²⁵⁶
    block_digest ∈ {0,1}²⁵⁶
    round ∈ ℕ
    stake ∈ ℕ
    signature ∈ {0,1}⁷⁶⁸

ValidVote(v, b) ≡
  v.round = b.round  ∧
  Verify(pk(voter), b.digest, v.signature)  ∧
  v.stake = stake(voter)
```

### 2.3 DAG State

```
DAG = set of (Block, Votes)
  DAG[r] = {blocks at round r}

Blocks(b) ≡ {b' ∈ DAG : b'.round = b.round}
Votes(b) ≡ {v : v.block_digest = b.digest}

Stake(b) ≡ Σ_{v ∈ Votes(b)} v.stake
  (cached as b.stake_cache for O(1) access)
```

### 2.4 Commit Rules

**2-Chain Commit Rule** (used when n ≤ 20):

```
Commit2Chain(b, r) ≡
  b.round = r  ∧  r ≥ 2  ∧
  ∃b' ∈ DAG[r+1] : Stake(b') ≥ Quorum  ∧
  ∃b'' ∈ DAG[r-2] : b''.digest = b.digest
```

If `Commit2Chain(b, r)` holds, block `b` at round `r-2` is finalized.

**3-Chain Commit Rule** (used when n > 20):

```
IsLeader(b) ≡ b.author = H("leader" || b.round) mod |V|

Commit3Chain(b, r) ≡
  b.round = r  ∧  r ≥ 3  ∧  IsLeader(b)  ∧
  ∃b₁ ∈ DAG[r+1] : Stake(b₁) ≥ Quorum  ∧  b ∈ b₁.parents  ∧
  ∃b₂ ∈ DAG[r+2] : Stake(b₂) ≥ Quorum  ∧  ∃b₁' ∈ DAG[r+1] : b₁' ∈ b₂.parents
```

If `Commit3Chain(b, r)` holds, leader block `b` at round `r` is finalized.

### 2.5 Equivocation

```
Equivocating(v, r) ≡
  ∃b₁, b₂ ∈ DAG[r] :
    b₁ ≠ b₂  ∧
    ∃v₁ ∈ Votes(b₁), v₂ ∈ Votes(b₂) :
      v₁.voter = v  ∧  v₂.voter = v

DetectEquivocation(v, r) → EquivocationEvidence(v, r)
```

Equivocation evidence proves Byzantine behavior but does not yet trigger slashing.

### 2.6 Liveness (Round Timeout)

```
TimedOut(r) ≡
  now() - round_start(r) > timeout_secs  ∧
  ¬∃b ∈ DAG[r] : Stake(b) ≥ Quorum

OnTimeout(r):
  advance to round r+1
  // uncommitted blocks in r remain in DAG for future parent references
```

---

## 3. State Transition Formalization

### 3.1 State Definition

```
State = { ObjectID → Object }

Object = (id, owner, type, data, version)
  where version = (sequence ∈ ℕ)

State₀     Genesis state (empty object set)
```

### 3.2 Transaction Execution

```
Execute(tx, state) → (state', events, gas_used) ∨ Error

Preconditions:
  - tx.gas_budget ≥ min_gas_price              (gas check)
  - tx.sequence = state.sender_seq[tx.sender] + 1  (nonce ordering)
  - ValidSignature(tx)                          (auth check)

Postconditions:
  - gas_used ≤ tx.gas_budget                    (gas conservation)
  - ∀r ∈ Resources : r is consumed OR stored     (resource linearity)
  - state' is deterministic given state and tx   (determinism)
```

### 3.3 Fast Path

```
FastPath(tx, state) ≡
  ∀id ∈ tx.inputs : state[id].owner = tx.sender
  // Sender owns ALL input objects → bypass consensus

FastPathLatency = O(sig_verify + execution) ≈ 100ms
```

### 3.4 Block Execution

```
ExecuteBlock(B, state) → (state', results)
  where B.payload = [tx₁, ..., txₖ]

ExecuteBlock(B, state) =
  ∀i ∈ [1..k] :
    (state_i, results_i) = Execute(tx_i, state_{i-1})
  state' = state_k

Determinism:
  ∀validators v₁, v₂ :
    ExecuteBlock(B, state_{r-1}) at v₁ = ExecuteBlock(B, state_{r-1}) at v₂
```

Block-STM optimizes this by executing transactions in parallel,
validating read-write sets, and re-executing conflicts.

### 3.5 State Root

```
StateRoot(state) = H( serialize( sorted(state.objects) ) )

StateRootTransition:
  StateRoot(state_r) = H(
    StateRoot(state_{r-1}) ||
    serialize( sorted( changes(state_r) ) )
  )
```

---

## 4. Safety Properties

### S1: No Forking

```
∀r ∈ ℕ, ∀b₁, b₂ :
  Committed(b₁, r) ∧ Committed(b₂, r) ⇒ b₁ = b₂
```

At most one block can be committed at any round.

### S2: Chain Continuity

```
∀c ∈ CheckpointChain :
  c.previous_digest = H(c_{i-1})
```

### S3: Deterministic State

```
∀state₀, ∀[tx₁...txₙ] :
  ExecuteBlock([tx₁...txₙ], state₀) is deterministic
```

### S4: Resource Conservation

```
∀tx : ResourcesCreated(tx) + ResourcesConsumed(tx) = ResourcesInput(tx)
```

---

## 5. Liveness Properties

### L1: Eventual Commitment

```
Under partial synchrony (GST model):
  ∀r, eventually ∃b ∈ DAG[r] : Committed(b, r') for some r'
```

Provided > 2/3 validators are honest and the network becomes synchronous.

### L2: Round Progression

```
∀r : if Commit not achieved within timeout, round advances to r+1.
    The system does not deadlock.
```

### L3: Transaction Inclusion

```
∀tx submitted to an honest validator:
  eventually tx is included in a committed block OR rejected with error
```

---

## 6. Complexity

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Block proposal | O(1) | One block per round per validator |
| Vote processing | O(1) | Hashmap insert + cached stake increment |
| Quorum check | O(1) | `stake_cache` field on Block |
| DAG insert | O(1) | Hashmap insert |
| Commit check (2-chain) | O(|DAG[r+1]|) | Scan blocks at next round |
| Commit check (3-chain) | O(|DAG[r+1]| + |DAG[r+2]|) | Scan two rounds |
| State root compute | O(k log k) | k = number of object changes, sorted |
| Transaction execute | O(|bytecode|) | Linear in bytecode length |
| Block-STM validate | O(n²) worst case | n = transactions per block; typically O(n) with low conflict |

---

## 7. References

- Mysticeti: [Low-Latency DAG consensus via consistent broadcast](https://arxiv.org/abs/2310.14821)
- Move: [Move: A Language With Programmable Resources](https://developers.diem.com/papers/diem-move-a-language-with-programmable-resources)
- Block-STM: [Parallel Execution Engine for Smart Contract Transactions](https://arxiv.org/abs/2203.06871)
- Ed25519: [RFC 8032](https://datatracker.ietf.org/doc/html/rfc8032)
- BLS12-381: [IETF BLS Signatures draft](https://datatracker.ietf.org/doc/draft-irtf-cfrg-bls-signature/)
- Noise: [Noise Protocol Framework](https://noiseprotocol.org/noise.html)
