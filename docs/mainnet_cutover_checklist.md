# zknot3 Mainnet Cutover Checklist

## T-7d

- [ ] Freeze protocol version and config profile
- [ ] Run `tools/mainnet_release_gate.sh` on release candidate
- [ ] Run `tools/p0_mainnet_gate.sh` and archive logs
- [ ] Blocking failures stop the cutover. Observe failures need a written decision before continuing.
- [ ] Verify validator key injection procedure in staging
- [ ] Confirm incident commander/on-call roster

## T-24h

- [ ] Final snapshot + backup
- [ ] Confirm all validators have non-null signing key and non-zero stake
- [ ] Confirm `logging.structured = true` in deployed profile
- [ ] Confirm metrics/log pipeline health

## T-0h (Cutover Window)

- [ ] Start seed validators
- [ ] Verify peer mesh convergence
- [ ] Verify first checkpoint progression
- [ ] Verify `/tx` replay returns `duplicate=true` (the transaction is not admitted again)
- [ ] Verify M4 endpoints:
  - [ ] `knot3_submitStakeOperation`
  - [ ] `knot3_submitGovernanceProposal`
  - [ ] `knot3_getCheckpointProof`
  - [ ] `knot3_creditGas` / `knot3_getGasBalance` (admin token and a ledger read; this is not a gas coin)
- [ ] Verify light-client proof check passes on sampled checkpoint
- [ ] Roll out 10% of nodes, then 30%, then the rest

## T+2h

- [ ] Review error budget burn rate
- [ ] Review ban/rate-limit counters for anomalies
- [ ] Review `p2p_uring_sq_depth` / `p2p_uring_cq_lat_ms` / `p2p_fallback_count`
- [ ] Review equivocation/slash events
- [ ] Publish cutover report

## Rollback Criteria

Rollback immediately if any occurs:

- Checkpoint progression stalls for > 2 epochs
- Repeated consensus safety alarms
- Critical proof verification failures (checkpoint signature failures above 0.1% in a 5-minute window)
- Uncontrolled peer churn or ban storms
- Node recovery exceeds 120s for 3 consecutive restarts

## Blocking vs Observe

- Blocking (must pass):
  - `tools/p0_mainnet_gate.sh`
  - Blocking stages of `tools/mainnet_release_gate.sh` (build, test, WAL recovery, tx semantics)
  - LightClient accepts `bls_signature` / `bls_signer_bitmap` from `knot3_getCheckpointProof`
- Observe (rollout can continue after a person signs off):
  - Known non-blocking alerts from the full adversarial suite
  - Soak and load figures (p95, ban rate, fallback count)

## Rollback Steps

1. Halt new validator joins.
2. Switch traffic to previous stable network snapshot.
3. Restore from verified backup.
4. Re-run release gate before next attempt.
