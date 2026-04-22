# zknot3 P2P Abuse Tuning Baseline

## Goal

Provide a safe baseline for public testnet/mainnet rollout under adversarial
traffic, while preserving consensus liveness.

## Baseline Profiles

- **balanced**
  - `max_messages_per_tick = 256`
  - `max_vote_messages_per_tick = 128`
  - `max_transaction_messages_per_tick = 32`
  - `per_peer_batch_limit = 4`
- **conservative**
  - `max_messages_per_tick = 192`
  - `max_vote_messages_per_tick = 96`
  - `max_transaction_messages_per_tick = 12`
  - `per_peer_batch_limit = 3`
- **throughput**
  - `max_messages_per_tick = 320`
  - `max_vote_messages_per_tick = 120`
  - `max_transaction_messages_per_tick = 104`
  - `per_peer_batch_limit = 6`

## Abuse Defense Signals

Track at minimum:

- `rate_limited_drops_total`
- `banned_peers_total`
- `consensus_event=equivocation_detected`
- commit drain behavior (`last_commit_drain`, adaptive batch window)

## Tuning Playbook

1. If tx backlog grows while votes/certs are healthy:
   - increase `max_transaction_messages_per_tick`
   - increase `high_tx_budget_boost`
2. If round advancement stalls:
   - increase vote/certificate budgets
   - lower transaction boost
3. If abusive peers dominate ingress:
   - lower `per_peer_batch_limit`
   - raise ban sensitivity (lower rate limits)
4. Re-validate with 2h soak:
   - no crash
   - no unbounded memory growth
   - quorum latency within SLO
