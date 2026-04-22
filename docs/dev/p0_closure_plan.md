# zknot3 P0 收口计划

> 目的：在主网切换前，将 `docs/dev/evaluation1.md` 评估出的五项 P0 架构缺口转化为可执行任务；每项给出：动机、拆分任务、验收脚本骨架、退出条件。

---

## 索引

| ID | 主题 | 归属模块 | 预估工作量 | 依赖 |
|----|------|----------|------------|------|
| P0-1 | Checkpoint BLS 聚合签名验证 | `src/form/storage/Checkpoint.zig`、`src/app/Node.zig` | M | —— |
| P0-2 | M4 WAL + Checkpoint 完整恢复循环 | `src/form/storage/{WAL,Checkpoint}.zig`、`src/app/Node.zig` | M | P0-1 |
| P0-3 | Mysticeti 并发写入正确性证明 | `src/form/consensus/Mysticeti.zig`、`src/pipeline/TxnPool.zig` | L | —— |
| P0-4 | `/tx` 提交路径签名校验与幂等 | `src/app/TxnAdmission.zig`、`src/form/network/RPC.zig` | S | —— |
| P0-5 | P2P 异步化（io_uring 真实落地） | `src/form/network/{P2P,P2PServer,Transport,AsyncHTTPServer}.zig`、`src/form/storage/IOUring.zig` | L | —— |

工作量：S ≤ 2 人日 · M ≤ 1 人周 · L ≤ 2 人周。

---

## P0-1 · Checkpoint BLS 聚合签名验证

### 动机
当前 `Checkpoint.verify` 仅重算 `state_root`、链式 digest、以及 Ed25519 额外种子的 quorum；BLS 聚合签名的密码学验证缺失，只是"预留字段"。一旦将 checkpoint 广播到跨链桥或轻客户端，等于未签名。

### 拆分
1. 在 `src/core/` 下接入 BLS12-381（优先 min_pk 方案），抽象为 `crypto/Bls.zig`：`aggregatePk`、`aggregateSig`、`verifyAggregated(msg, pk, sig)`。
2. `AuthorityConfig` 新增 `bls_signing_seed` + `extra_bls_signing_seeds`；`Node.buildCheckpointProof` 同时产出 Ed25519 quorum 与 BLS 聚合签名。
3. `Checkpoint.verify` 增加 `bls_validator_set: ?*const BlsValidatorSet` 参数，对 checkpoint digest 做聚合签名校验；Ed25519 路径保留作为回退。
4. RPC / GraphQL 的 `CheckpointProof` schema 暴露 `bls_signature`、`bls_signer_bitmap`。
5. Release gate：`tools/mainnet_release_gate.sh` 增加 `bls_verify_ok` 断言。

### 验收脚本骨架
```bash
# tools/p0_bls_checkpoint_gate.sh
set -euo pipefail
zig build test -Dtest-filter="checkpoint_bls"
zig build run -- produce-checkpoint --out /tmp/ckpt.bin
zig build run -- verify-checkpoint --input /tmp/ckpt.bin --require-bls
# 篡改单比特必须失败
dd if=/dev/urandom of=/tmp/ckpt.bin bs=1 count=1 seek=512 conv=notrunc
! zig build run -- verify-checkpoint --input /tmp/ckpt.bin --require-bls
```

### 退出条件
- 单元：`test/unit/bls_checkpoint_test.zig` 覆盖 2-of-3 / 3-of-3 / 篡改签名 / 篡改 digest。  
- 集成：`test/integration/m4_multi_validator_checkpoint_test.zig` 新增 BLS 路径。  
- 主网门禁脚本通过 + 10 分钟内 5 轮 checkpoint 广播均 `verify_ok=1`。

---

## P0-2 · M4 WAL + Checkpoint 完整恢复循环

### 动机
`replayMainnetM4Wal` 恢复了 stake 与提交状态，但 epoch 推进与 validator set 变更的回放路径未做完整闭环——重启后若正好跨越 epoch 边界，存在"恢复后 validator set 与 WAL 不一致"的窗口。

### 拆分
1. 在 WAL 中把 `EpochAdvance` / `ValidatorSetRotate` 提升为显式 record 类型（若当前是隐式）。
2. `replayWalExtension` 顺序应用：`StakeOp → EpochAdvance → ValidatorSetRotate → Checkpoint`。
3. `recoverFromDisk` 重放完成后：以最新 checkpoint 的 `validator_set_hash` 重算并与 runtime 一致性断言。
4. 崩溃点注入：在 epoch 边界 / validator rotate 中间 / checkpoint 落盘之后各插一个 `--crash-after` 标志。
5. `testnet_release_gate.sh` 的 `require_pattern` 扩展 "epoch advance replayed"、"validator set hash matches"。

### 验收脚本骨架
```bash
# tools/p0_recovery_loop_gate.sh
set -euo pipefail
for crash in pre_epoch mid_rotate post_checkpoint; do
  rm -rf .tmp/node
  zig build run -- dev-sim --crash-after="$crash" --out=.tmp/node || true
  zig build run -- dev-sim --recover-from=.tmp/node --assert-hash-match
done
```

### 退出条件
- `test/integration/m4_wal_recovery_test.zig` 补上 3 个崩溃点用例。  
- 恢复后 `current_epoch`、`validator_set_hash`、`latest_checkpoint_digest` 三者与崩溃前 WAL 最后一条可重放记录完全一致。

---

## P0-3 · Mysticeti 并发写入正确性证明

### 动机
`Mysticeti.zig` 与 `ConsensusIntegration.zig` 在多线程下写入共享结构；目前缺乏"在对抗调度下仍保持安全性"的证据，属于最大的共识未知风险。

### 拆分
1. 梳理所有共享状态，明确每一处加锁策略（`std.Thread.Mutex` / `RwLock` / atomic）；写 `docs/dev/mysticeti_concurrency.md`。
2. 对关键 invariants（"同一 round 不会产出两个冲突 commit"、"TxnPool 提交顺序稳定"）写属性测试 harness：`test/property/mysticeti_concurrency_test.zig`。
3. 引入 `ThreadSanitizer` 构建变体（`zig build -Dtsan`），CI 增加一条 `tsan` 管线。
4. Loom 风格最小调度器：对关键函数做 `N=2..4` 线程穷举交错，断言不变量。

### 验收脚本骨架
```bash
# tools/p0_mysticeti_concurrency_gate.sh
set -euo pipefail
zig build -Dtsan test --summary all
zig build test -Dtest-filter="mysticeti_property" --summary all
# 10 分钟 soak
timeout 600 zig build run -- dev-sim --consensus-soak --validators=4 --rps=500
```

### 退出条件
- TSAN 下 0 race。  
- 属性测试 1e4 轮下不变量保持。  
- Soak 期间无死锁、无 `commit rollback`。

---

## P0-4 · `/tx` 提交路径签名校验与幂等

### 动机
当前 admission 路径偏重结构校验；签名合法性、重放窗口、nonce 幂等语义是主网级必须项。

### 拆分
1. `TxnAdmission.submit`：强制调用 `verifyTxSignature`（Ed25519 / secp256k1 可配置），失败返回 `-32010 InvalidSignature`。
2. 引入 `nonce` 校验窗口（账户维度滑窗 + hash 去重缓存），重复提交返回 `200 + duplicate=true`，不再次入池。
3. `tools/adversarial_test.py` 扩展：重放相同体、伪造签名、越过 nonce 窗口三类用例。
4. 与 P0-1 产出的 checkpoint_proof 共用 `crypto/` 抽象层，避免重复实现。

### 验收脚本骨架
```bash
# tools/p0_tx_admission_gate.sh
set -euo pipefail
zig build test -Dtest-filter="tx_admission_signature"
python3 tools/adversarial_test.py --case=tx_replay
python3 tools/adversarial_test.py --case=tx_bad_signature
python3 tools/adversarial_test.py --case=tx_nonce_gap
```

### 退出条件
- 伪签名 100% 被拒且 RPC 错误码稳定为 `-32010`。  
- 重放第二次 `duplicate=true` 且不产生新的 mempool entry。  
- nonce 乱序 / 过老 / 过新三类均按设计语义返回。

---

## P0-5 · P2P 异步化（io_uring 真实落地）

### 动机
`docs/async_gap_assessment.md` 已指出 P2P / HTTP 路径上同步 I/O 的瓶颈；`src/form/storage/IOUring.zig` 存在但尚未覆盖网络读写，需要把承诺兑现。

### 拆分
1. 抽象 `form/network/AsyncReactor.zig`：Linux 优先 `io_uring`（SQPOLL），macOS 回退 `kqueue` / 线程池。
2. `P2PServer` / `AsyncHTTPServer` 的 accept + read + write 全部走 reactor；保留同步路径作为降级开关。
3. 压测：`tools/p2p_abuse_tuning.md` 记录的 abuse 场景要在异步路径下依然生效（连接上限、慢客户端超时、分片读）。
4. 观测：导出 `p2p_uring_sq_depth`、`p2p_uring_cq_lat_ms`、`p2p_fallback_count` 至 Prometheus。

### 验收脚本骨架
```bash
# tools/p0_p2p_async_gate.sh
set -euo pipefail
zig build test -Dtest-filter="p2p_async"
# Linux-only
uname -s | grep -q Linux && zig build run -- dev-sim --p2p-reactor=io_uring --rps=5000 --duration=300
# 指标断言
curl -s localhost:9100/metrics | grep -E 'p2p_uring_(sq_depth|cq_lat_ms)'
curl -s localhost:9100/metrics | grep -E 'p2p_fallback_count 0'
```

### 退出条件
- Linux 下 5k rps 持续 5 分钟：p95 入站延迟 ≤ 同步基线的 60%。  
- `p2p_fallback_count == 0`（无意外回退）。  
- 滥用场景（慢连接、大 payload、短连接洪水）行为与同步版一致或更好。

---

## 跨项收口门禁（`tools/p0_mainnet_gate.sh` 草案）

```bash
set -euo pipefail
bash tools/p0_bls_checkpoint_gate.sh
bash tools/p0_recovery_loop_gate.sh
bash tools/p0_mysticeti_concurrency_gate.sh
bash tools/p0_tx_admission_gate.sh
[ "$(uname -s)" = "Linux" ] && bash tools/p0_p2p_async_gate.sh
echo "ALL P0 GATES PASSED"
```

主网切换 checklist（`docs/mainnet_cutover_checklist.md`）的 "Security / Consensus" 段落需引用本脚本作为硬门禁。

---

## 时间线建议

| 周 | 关键项 |
|----|--------|
| W1 | P0-4（签名 + 幂等）、P0-1 前半（`crypto/Bls.zig` 抽象 + 单测）|
| W2 | P0-1 后半（Checkpoint 接入、RPC/GQL 暴露、门禁脚本）|
| W3 | P0-2（恢复循环三崩溃点 + `tests.zig` 登记）|
| W4 | P0-3（并发文档 + property 测试 + TSAN 管线）|
| W5 | P0-5（reactor 抽象 + Linux io_uring 路径 + 压测基线）|
| W6 | 汇总门禁脚本、跑 14 天稳定性，对齐 `testnet_14d_stability_checklist.md` |

---

*本计划是活文档。任一项落地后，请同步更新 `docs/dev/evaluation1.md` 中「架构缺口」小节，并把对应 gate 登记进 `tools/mainnet_release_gate.sh`。*
