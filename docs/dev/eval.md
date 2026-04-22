## 再次评估：对照「evaluation1 产品化迭代」计划

下面按波次对照**附件计划**与**当前仓库**，并标出文档与事实是否一致。

---

### 波次 0 — 文档对齐（`evaluation1.md`）

- **WAL / 重放 / slash + 门禁**：文档与 `m4_wal_recovery_test.zig`、`m4_wal_recovery_harness.sh`、`mainnet_release_gate.sh` 的叙述**一致**。
- **Phase D「仍缺」段落与代码有偏差**：同一段里把「重复 `validator_id`、RPC 重放」等仍写在「仍缺」下，但 `m4_adversarial_recovery_test.zig` 里**已有**对应用例（如 `M4 adversarial: duplicate validator_id...`、`M4 RPC replay: ...`）。读者会误以为未做，建议把该段改成「已由 `m4_adversarial_recovery_test.zig` 覆盖 / 仍部分缺」的分项表述。
- **多签配置字段名**：文档写 `Config.m4_checkpoint_signing_keys`，代码里是 **`AuthorityConfig.checkpoint_proof_extra_signing_seeds`**（见 `Config.zig` / `Node.zig`）。这是**明确文档错误**，应改文档或（不推荐）改 API 名以对齐文档。

---

### 波次 A — 对抗 / 恢复

| 计划项 | 现状 |
|--------|------|
| 双签 / 相同 `validator_id` 不抬高 quorum | **有**：`verifyCheckpointProofQuorum` + 重复 `v1.id` 两条签名，期望 `!ok`。 |
| 伪造 / 错绑 equivocation evidence | **部分**：有 `replayWalExtension` **畸形 WAL** 的 `InvalidWalPayload`；计划里「与已落 WAL 不一致的 payload、第二次不重复 slash」的**完整错绑路径**未在同一文件里看到专门用例（若只在 `m4_wal_recovery_test` 里，需单独说明）。 |
| RPC 同一请求体两次 | **有且语义已钉死**：合法体两次均 `accepted`；非法体两次均 `-32602`（与计划「三选一」一致）。 |
| `recoverFromDisk` + `replayMainnetM4Wal` | **有**：恢复后 stake 与提交一致。 |
| `testnet_release_gate.sh` | **有**：`require_pattern` 检查 `m4_adversarial_recovery_test.zig` 含 `M4 adversarial`。 |

---

### 波次 B — GraphQL `!`

- **`m4_gql_nn` + `NonNull`**：M4 mutation 参数与 receipt / `CheckpointProof` 等已在 `GraphQL.zig` 使用 `NonNull`。
- **单测**：`graphql_test.zig` 侧有对 SDL / 类型链的断言（与计划一致）。

---

### 波次 C — Python 收据

- **`generatePython`**：`StakeOperationReceipt` / `GovernanceProposalReceipt` / `CheckpointProof` 的 class 与 `->` 注解及 `ClientSDK` 内单测片段断言**均存在**。

---

### 波次 D — 多验证者签名

- **配置**：`checkpoint_proof_extra_signing_seeds`（非计划草稿里的「validator 列表 + 权重」全量模型，而是**额外种子**扩展多签，足够支撑测试与运维多 key**）。
- **Node**：`buildCheckpointProof` 对主 key + extra seeds 聚合签名。
- **集成测试**：`m4_multi_validator_checkpoint_test.zig`（2-of-3 等路径）+ `tests.zig` 已引入。

---

### 波次 E — `verifyEpochProof`

- **计划 A（最小子集）**：已实现 `allocator` + `next_validators` + `checkpoints_per_epoch`、state_root 重算、`computeValidatorSetHash` 一致、非全零 hash；**未**做 checkpoint 上验证者签名链（与注释 / `evaluation1.md` 一致）。
- **`computeValidatorSetHash`**：使用 `v.stake.votingPower()`，与 `ValidatorStake` 模型一致。

---

### 总体结论

- **计划中的 A–E 技术项在仓库里基本都已落地**，`zig build test` 在上一轮已通过（你若本地要复核，可再跑一次）。
- **主要遗留是文档质量**：`evaluation1.md` 的 Phase D「仍缺」与多签字段名需要与代码对齐，否则对外/对内评审会误判完成度。
- **计划明确排除的项**（Mysticeti 竞态、`/tx` 验签、P2P 等）仍不在本里程碑范围内，无需算作本计划未完成。

若你希望，我可以下一步**只改 `docs/dev/evaluation1.md`**（不动 plan 文件）：修正 `checkpoint_proof_extra_signing_seeds` 命名，并把 Phase D 拆成「已由 adversarial 测试覆盖」与「仍属架构缺口」两栏。