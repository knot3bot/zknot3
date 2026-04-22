# zknot3 Testnet Operations Runbook

## 1. Pre-Release Gate

1. Ensure validators/fullnode are up.
2. Run:
   - `bash tools/testnet_release_gate.sh`
3. Gate分层解释：
   - 阻塞项（必须通过）：`zig build`、`zig build test`、`tools/p0_mainnet_gate.sh`、`adversarial --case` 三项、`tools/load_test.py`。
   - 观察项（失败需人工评估）：全量 `tools/adversarial_test.py`（会输出 `business_failures` / `environment_failures` 分类）。
4. 若阻塞项失败，禁止发布。

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
- checkpoint 验签失败率 > 0.1%（5 分钟窗口）
- 节点重启恢复时长 > 120s（连续 3 次）

Rollback steps:
1. Stop rollout.
2. Re-deploy previous known-good binary.
3. Restart node and confirm replay/recovery success.
4. Rejoin node and validate consensus round catch-up.

## 5. Canary / Gray Release

1. 灰度比例：10% -> 30% -> 100%。
2. 每阶段至少观察 15 分钟，检查：
   - `/health` 全绿、`consensus_round` 持续推进
   - `knot3_getCheckpointProof` + LightClient 验证成功
   - 无 `environment_failures` 持续告警
3. 任一阻塞阈值触发立即回滚，不进入下一阶段。

## 6. Post-Incident Actions

1. Fill incident template (`docs/testnet_incident_template.md`).
2. Capture logs and metrics snapshot.
3. Add regression test before next release.
