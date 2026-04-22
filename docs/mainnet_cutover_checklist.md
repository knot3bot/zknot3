# zknot3 Mainnet Cutover Checklist

## T-7d

- [ ] Freeze protocol version and config profile
- [ ] Run `tools/mainnet_release_gate.sh` on release candidate
- [ ] Run `tools/p0_mainnet_gate.sh` and archive logs
- [ ] 确认阻塞项/观察项边界：阻塞项失败立即停止；观察项失败需出具人工评估结论
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
- [ ] Verify `/tx` replay returns `duplicate=true` (no second入池)
- [ ] Verify M4 endpoints:
  - [ ] `knot3_submitStakeOperation`
  - [ ] `knot3_submitGovernanceProposal`
  - [ ] `knot3_getCheckpointProof`
- [ ] Verify light-client proof check passes on sampled checkpoint
- [ ] 灰度策略执行：10% 节点 -> 30% 节点 -> 全量

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
- Critical proof verification failures（阈值：checkpoint 验签失败率 > 0.1% / 5 分钟）
- Uncontrolled peer churn or ban storms
- Node recovery exceeds 120s for 3 consecutive restarts

## Blocking vs Observe

- Blocking（必须通过）:
  - `tools/p0_mainnet_gate.sh`
  - `tools/mainnet_release_gate.sh` 阻塞阶段（build/test/WAL recovery/tx语义）
  - `knot3_getCheckpointProof` 的 `bls_signature` / `bls_signer_bitmap` 可被 LightClient 一致验过
- Observe（可灰度继续，但需人工确认）:
  - 全量 adversarial 套件中的已知非阻塞项告警
  - 长稳趋势与压力冗余指标（p95、ban rate、fallback 计数）

## Rollback Steps

1. Halt new validator joins.
2. Switch traffic to previous stable network snapshot.
3. Restore from verified backup.
4. Re-run release gate before next attempt.
