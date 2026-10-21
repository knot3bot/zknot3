# zknot3 Testnet Operations Runbook

## 1. Pre-Release Gate

1. Ensure validators/fullnode are up.
2. Run:
   - `bash tools/testnet_release_gate.sh`
3. Gate split:
   - Blocking (must pass): `zig build`, `zig build test`, `tools/p0_mainnet_gate.sh`, the three `adversarial --case` runs, `tools/load_test.py`.
   - Observe (a person decides): the full `tools/adversarial_test.py` run, which prints `business_failures` and `environment_failures`.
4. Do not release if a blocking item fails.

## 2. Rolling Upgrade SOP

1. Upgrade one validator at a time.
2. For each node:
   - drain ingress (stop external traffic)
   - stop process
   - deploy new binary/config
   - restart and wait for `state=running`
   - verify round advancement and peer count recovery
3. Upgrade fullnode after validators.

## 3. Health Checks

- RPC health: `GET /health`
- Consensus progress: `consensus_round` increases
- P2P sanity: peer count stable, no ban spikes
- Storage sanity: restart/recover path completes without checksum errors

## 4. Rollback

Trigger rollback when any of:
- sustained commit stalls (> 2 round intervals)
- repeated node crash loops
- severe RPC error spike violating SLO
- checkpoint signature failures above 0.1% in a 5-minute window
- node recovery above 120s, three times in a row

Rollback steps:
1. Stop rollout.
2. Re-deploy previous known-good binary.
3. Restart node and confirm replay/recovery success.
4. Rejoin node and validate consensus round catch-up.

## 5. Canary / Gray Release

1. Canary: 10%, then 30%, then 100%.
2. Watch each stage for at least 15 minutes:
   - `/health` stays up and `consensus_round` keeps moving
   - `knot3_getCheckpointProof` passes LightClient
   - `environment_failures` is not a standing alert
3. A blocking threshold rolls the stage back. Do not advance.

## 6. Post-Incident Actions

1. Fill incident template (`docs/testnet_incident_template.md`).
2. Capture logs and metrics snapshot.
3. Add regression test before next release.
