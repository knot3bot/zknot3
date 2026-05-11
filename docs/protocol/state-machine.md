# State Machine Specification

## Overview

zknot3's state machine defines how transactions transition the global state.
State is represented as a collection of **objects** (Move resources) with
deterministic, verifiable transitions.

## State Model

```
Global State = { ObjectID → Object }

Object {
    id: ObjectID            // Blake3-256 hash
    owner: [32]u8           // Owner address (or 0 for shared)
    type: []u8              // Move module::struct type tag
    data: []u8              // Move resource serialized bytes
    version: Version        // Monotonic version counter
}
```

## Transaction Lifecycle

```
┌────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│ SUBMIT │ →  │ VERIFY   │ →  │ EXECUTE  │ →  │  COMMIT  │
│ Client │    │ Sig + Gas│    │ Move VM  │    │ State    │
│ sends  │    │ + Nonce  │    │ Interp.  │    │ root     │
└────────┘    └──────────┘    └──────────┘    └──────────┘
```

### 1. Submission

- Client constructs a `Transaction` with sender, program, gas_budget, sequence
- Transaction is signed with Ed25519 (sender private key)
- Submitted via `POST /tx` (JSON-RPC) or P2P gossip

### 2. Verification (Ingress)

- **Signature**: Ed25519 verify(tx.digest(), sender_public_key)
- **Gas**: gas_budget >= min_gas_price (configurable, default 1000)
- **Nonce**: sequence == current_sender_sequence + 1 (strict ordering)
- **Dedup**: tx.digest() not in seen_digests

### 3. Execution (Executor)

- **Fast Path**: If all inputs are owned by sender, execute immediately (bypass consensus)
- **Consensus Path**: Wait for consensus ordering, then execute in block order
- **Block-STM**: Parallel execution with optimistic read-write-set validation
- **Move VM**: Bytecode verified then interpreted; gas metered per instruction

### 4. State Commitment

- Executed transactions produce: output_objects (new/modified), events
- State root = Merkle root over all object changes since genesis
- Checkpoint written with state root + validator signatures
- WAL entry written before state mutation

## Fast Path (Single-Owner Transactions)

When ALL input objects are owned by the transaction sender:
1. Transaction bypasses consensus ordering
2. Executed immediately upon verification
3. Result is available in <100ms (no round latency)
4. ~80-90% of typical blockchain transactions use this path

## Consensus Path (Shared Objects)

When any input object is shared or owned by a different address:
1. Transaction enters consensus ordering
2. Included in the next proposed block
3. Executed after block commit (2-3 round latency)
4. ~10-20% of transactions (DeFi, auctions, etc.)

## Deterministic Execution Guarantee

```
∀ state₀, ∀ txs[n]:
  execute(state₀, txs) → state₁ is deterministic
```

- Same initial state + same ordered transactions = same final state root
- Move VM bytecode is deterministic (no floating-point, no randomness)
- Gas metering is monotonic and overflow-safe
- Resource tracking ensures linear type safety (no double-spend)

## State Root Computation

```
state_root = Blake3(
    for each object change in checkpoint:
        update(object.id || object.version || object.status)
)
```

Statuses: `created`, `modified`, `deleted`
