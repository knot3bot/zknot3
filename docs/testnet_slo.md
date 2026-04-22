# zknot3 Public Testnet SLO

## Availability SLO

- Window: rolling 30 days
- Target: RPC `GET /health` availability >= 99.5%
- Error budget: <= 3h 36m / 30 days

## Performance SLO

- `knot3_getLatestCheckpoint` p95 < 500ms
- Transaction submit endpoint p95 < 1s
- Block commit interval p95 < 5s

## Recovery SLO

- Single node crash recovery (restart + replay): < 3 minutes
- Peer rejoin after disconnect: < 30 seconds
- Banlist false positive rate: < 0.1% of healthy peers/day

## Security SLO

- Equivocation detection latency: < 1 round
- Replayed handshake nonce acceptance: 0 tolerated
- Rate-limit bypass acceptance: 0 tolerated in regression suite
