## evaluation1 产品化迭代 — 计划 ↔ 代码对齐（已修订）

> 本版本于 `eval.md` 评估基础上修订：  
> 1. 将 Phase D「仍缺」段落拆成「已由 `m4_adversarial_recovery_test.zig` 覆盖」与「仍属架构缺口」两栏；  
> 2. 统一多签字段命名为代码中的 `AuthorityConfig.checkpoint_proof_extra_signing_seeds`（旧稿使用的 `Config.m4_checkpoint_signing_keys` 属文档错误，已废弃）。

---

### 波次 0 — 文档对齐

| 项 | 状态 | 说明 |
|----|------|------|
| WAL / 重放 / slash + 门禁 | ✅ 一致 | 与 `test/integration/m4_wal_recovery_test.zig`、`tools/m4_wal_recovery_harness.sh`、`tools/mainnet_release_gate.sh` 同步 |
| 多签配置字段名 | ✅ 已统一 | 代码与本文均使用 `AuthorityConfig.checkpoint_proof_extra_signing_seeds`（见 `src/app/Config.zig`、`src/app/Node.zig`）|
| Phase D 覆盖度 | ✅ 已拆分 | 见下方「波次 A」与「架构缺口」两小节 |

---

### 波次 A — 对抗 / 恢复

#### A.1 已由 `m4_adversarial_recovery_test.zig` 覆盖

| 计划项 | 断言点 |
|--------|--------|
| 双签 / 相同 `validator_id` 不抬高 quorum | `verifyCheckpointProofQuorum` + 重复 `v1.id` 两条签名，期望 `!ok` |
| RPC 同一请求体两次 | 合法体两次均 `accepted`；非法体两次均 `-32602`（`InvalidParams`）|
| `recoverFromDisk` + `replayMainnetM4Wal` | 恢复后 stake 与提交一致；`testnet_release_gate.sh` 含 `require_pattern` 检查 |
| P2P 握手重放 | challenge-response + nonce 缓存；重放 handshake 被拒 |
| 畸形 WAL payload | `replayWalExtension` 返回 `InvalidWalPayload` |
| 过大 payload / DoS | 早期拒绝 + 连接计数上限 |

#### A.2 P0 收口状态（2026-04 更新）

| 项 | 当前实现 | 备注 |
|----|------|------|
| Equivocation evidence 错绑完整路径 | 已覆盖畸形 payload + 重放幂等 | 见 `m4_adversarial_recovery_test.zig` |
| Checkpoint BLS 聚合签名验证 | 已接入 `core/crypto/Bls.zig` + proof 字段扩展 | RPC/GraphQL/SDK 已暴露 `bls_signature` / `bls_signer_bitmap` |
| Mainnet M4 WAL + Checkpoint 完整恢复循环 | 已新增 EpochAdvance / ValidatorSetRotate WAL record 与回放测试 | 见 `m4_wal_recovery_test.zig` 新增恢复断言 |

---

### 波次 B — GraphQL NonNull

- `src/app/GraphQL.zig`：M4 mutation 参数、receipt、`CheckpointProof` 已全面使用 `NonNull`；helper `m4_gql_nn` 统一包装。  
- `test/unit/graphql_test.zig`：对 SDL 类型链进行断言，与计划一致。

---

### 波次 C — Python 收据

- `ClientSDK.generatePython`：`StakeOperationReceipt` / `GovernanceProposalReceipt` / `CheckpointProof` 的 class 体与 `->` 返回注解、字段文档、客户端内单测片段均存在。  
- 断言：运行 `zig build test` 可触发 SDK 侧对生成器输出的 golden 断言。

---

### 波次 D — 多验证者签名

- **配置**：`AuthorityConfig.checkpoint_proof_extra_signing_seeds`（额外 Ed25519 种子列表，而非全量 validator+权重模型），足以支撑测试与运维多 key 场景。  
- **Node**：`buildCheckpointProof` 用主 key + extra seeds 产生聚合 Ed25519 签名集合。  
- **验证**：`verifyCheckpointProofQuorum` 对唯一 `validator_id` 去重后做 stake 加权阈值判定。  
- **集成测试**：`test/integration/m4_multi_validator_checkpoint_test.zig` 覆盖 2-of-3、全量、单点失败路径，并登记入 `tests.zig`。

---

### 波次 E — `verifyEpochProof`（最小子集 Plan A）

| 检查项 | 状态 |
|--------|------|
| `allocator` + `next_validators` + `checkpoints_per_epoch` 结构校验 | ✅ |
| state_root 重算一致 | ✅ |
| `computeValidatorSetHash`（使用 `v.stake.votingPower()`）一致 | ✅ |
| state_root / validator_set_hash 非全零 | ✅ |
| Checkpoint 上验证者签名链校验 | ❌ 计划内明确排除，列入 P1 |

---

### 总体结论（含 P0 收口）

- **计划内 A–E 技术项均已落地**；`zig build test` 通过。  
- **文档对齐**：本文修订后与 `Config.zig` / `Node.zig` / `m4_adversarial_recovery_test.zig` 一致。  
- **P0 汇总门禁**：`tools/p0_mainnet_gate.sh` 串联 `p0_tx_admission_gate.sh`、`p0_bls_checkpoint_gate.sh`、`p0_recovery_loop_gate.sh`、`p0_mysticeti_concurrency_gate.sh`、`p0_p2p_async_gate.sh`。  

---

*历史版本：`eval.md` 保留了发现这些差异时的原始评估，保留作为审计记录。本文（`evaluation1.md`）为修订版本，供后续评审与门禁脚本引用。*
