# ADR-002: DAG-based BFT (Mysticeti) vs HotStuff

**Status**: Accepted
**Date**: 2025-05
**Deciders**: zknot3 core team

---

## Context

Consensus is the foundation of the chain. Two major families:
- **HotStuff/BFT-SMaRt**: Leader-based, linear chain, 3-round commit
- **DAG-BFT (Mysticeti/Narwhal)**: Leaderless DAG, parallel block proposal

## Decision

**Use Mysticeti DAG-BFT** (Sui's consensus model).

Key properties:
- **Leaderless proposal**: Any validator can propose in any round
- **2-chain commit**: Low latency for small validator sets (≤20)
- **3-chain commit**: Higher safety for large validator sets (>20)
- **Auto-select**: Switches between 2-chain/3-chain based on `commit_3chain_threshold`

## Rationale

HotStuff's single-leader model creates a bottleneck:
- Leader failure = view-change overhead
- Leader is a censorship vector
- Throughput limited by leader's bandwidth

DAG-BFT eliminates the leader bottleneck:
- All validators propose in parallel
- Commit rule works on any block with sufficient quorum support
- Natural resilience to validator churn

## Architecture

```
Round N-2    Round N-1    Round N      Round N+1
  [B1] ←───── [B3] ←───── [B5]
    ↓            ↓            ↓
  [B2] ←───── [B4] ←───── [B6] ←── votes for B1..B6
                                    ↓
                            commit B1..B2 (2-chain)
                            commit leader block (3-chain if supported)
```

## Consequences

### Positive
- No leader bottleneck → higher throughput
- Equivocation detection built into the DAG structure
- Natural pipelining via pre_built_block

### Negative
- More complex than linear-chain BFT
- Requires careful DAG pruning to bound memory
- Sub-second rounds require low-latency networking

## Implementation

- `src/form/consensus/Mysticeti.zig` — DAG, block/vote types, commit logic
- `src/form/consensus/Quorum.zig` — stake-weighted quorum calculations
- `src/form/consensus/Validator.zig` — validator set management
- `src/metric/EpochConsensusBridge.zig` — epoch boundary consensus reconfiguration
