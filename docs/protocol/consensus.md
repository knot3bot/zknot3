# Consensus Protocol Specification

## Overview

zknot3 uses **Mysticeti DAG-BFT**, a leaderless consensus protocol adapted from
Sui's Mysticeti. Validators propose blocks into a Directed Acyclic Graph (DAG),
and blocks are committed when they receive sufficient quorum support.

## Node Types

| Type | Participates in Consensus | Stores Full State | Serves RPC |
|------|--------------------------|-------------------|------------|
| **Validator** | Yes (proposes + votes) | Yes | Optional |
| **Full Node** | No (observes only) | Yes | Optional |
| **RPC Node** | No | Optional | Yes |
| **Archive Node** | No | Yes (all history) | No |
| **Light Client** | No | No (proofs only) | No |

## Protocol Lifecycle

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│ PROPOSE  │ →  │  GOSSIP  │ →  │   VOTE   │ →  │  COMMIT  │
│ Build    │    │ Broadcast│    │ Verify & │    │ 2/3-chain│
│ block    │    │ to peers │    │ sign     │    │ finalize │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
```

### 1. Proposal Phase

Any validator can propose a block in any round:
- Block contains: author, round, payload (transactions), parents (prior rounds)
- Block digest = Blake3(author || round || payload)
- Validator self-votes on proposed block
- Block is broadcast to all peers via P2P gossip

### 2. Vote Phase

Validators receive blocks and vote:
- Verify block digest matches author + round + payload
- Check no equivocation (same validator, same round, different block)
- Sign vote with Ed25519 private key
- Broadcast vote to all peers
- Vote stake is tracked per block

### 3. Commit Phase

Two commit rules, auto-selected:

**2-Chain Commit** (≤20 validators):
```
Round N is committed when any block in N+1 has quorum (> 2/3 stake).
Latency: ~2 round intervals.
```

**3-Chain Commit** (>20 validators):
```
A leader block in N is committed when both N+1 AND N+2
have blocks with quorum support that reference it.
Latency: ~3 round intervals.
```

## Block Structure

```
Block {
    author: [32]u8          // Validator identity
    round: Round            // Consensus round number
    payload: []u8           // Serialized transactions
    parents: []Round        // Prior round references (DAG edges)
    votes: map<id, Vote>    // Collected validator votes
    digest: [32]u8          // Blake3(author || round || payload)
    stake_cache: u128       // Running total of vote stake (O(1) quorum check)
}
```

## Vote Structure

```
Vote {
    voter: [32]u8           // Validator identity
    block_digest: [32]u8    // Which block is being voted for
    round: Round            // Consensus round
    stake: u128             // Voter's stake weight
    signature: [96]u8       // Ed25519 signature (padded to 96 bytes)
                            // BLS aggregate signature when use_bls_aggregation
}
```

## Commit Certificate

```
CommitCertificate {
    block_digest: [32]u8    // Committed block
    round: Round            // Committed round
    quorum_stake: u128      // Total stake that voted (> 2/3)
    confidence: f64         // Statistical confidence (Poisson process)
}
```

## Equivocation Detection

If a validator signs two different blocks at the same round:
1. Both votes are recorded as `EquivocationEvidence`
2. The equivocating validator's votes are rejected for that round
3. Evidence is logged for potential slashing (future)
4. No automatic slashing in current version

## Round Timeout

If no block reaches quorum within `round_timeout_secs` (default 5s):
1. `checkRoundTimeout` detects the stall
2. Round is advanced to unblock progress
3. Uncommitted blocks remain in DAG (may be committed later via parent references)

## DAG Pruning

To bound memory, committed rounds beyond `max_committed_blocks` (default 10000)
are pruned from the in-memory DAG. Pruned blocks cannot be referenced by new blocks.
