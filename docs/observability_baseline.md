# zknot3 Observability Baseline

## Structured Log Fields

Consensus-path logs should include these stable keys:

- `consensus_event`: event type (`block_received`, `vote_received`, `commit_success`, `equivocation_detected`)
- `peer_prefix`: first byte of peer id (lightweight peer correlation)
- `round`: consensus round when available
- `quorum_stake`: quorum stake at commit
- `payload_bytes`: inbound payload size for network events
- `drain_budget`: adaptive commit batch budget at commit time

## P2P Abuse-Defense Metrics

P2P rate-limiter exposes:

- `rate_limited_drops_total`: total dropped inbound messages due to per-peer/per-type caps
- `banned_peers_total`: total peer ban events triggered by score threshold

These counters are collected in `P2PServer` and should be exported by runtime metrics endpoint.

## Recovery Integrity Checks

Checkpoint verification must validate all three invariants before accept:

1. state root matches recomputation from object changes
2. previous digest matches previous checkpoint digest
3. sequence continuity (`current.sequence == previous.sequence + 1`)

Regression tests now cover digest mismatch and sequence-gap rejection.
