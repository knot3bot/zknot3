# zknot3 14-Day Stability Checklist

## Scope

- Minimum topology: 4 validators + 1 fullnode
- Duration: continuous 14 days

## Daily Checks

- [ ] `zig build test` still green on release branch
- [ ] consensus rounds advancing on all validators
- [ ] no repeated crash loop/restart spikes
- [ ] no checksum corruption during replay/restart drills
- [ ] P2P ban spikes investigated (false-positive screening)

## Weekly Drills

- [ ] rolling upgrade rehearsal
- [ ] one-node kill/restart recovery drill
- [ ] one-node network partition and rejoin drill

## Pass Criteria

- No P0/P1 production incidents
- SLOs in `docs/testnet_slo.md` remain within budget
- Recovery drills complete within target times
- Release gate script passes on candidate tag
