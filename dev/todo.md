# zknot3 — 三源合恰 可信基础设施 发展路线图

## 定位

zknot3 不是 Sui 的克隆。它是基于"三源合恰"（物象性三源）框架的**数字生命可信基础设施**：

```
形（Spatial Topology）  → 存储、网络、共识   → 数字生命的物理载体
性（Intrinsic Attribute）→ Move VM、访问控制、加密 → 数字生命的内在属性
数（Quantitative Measure）→ Epoch、Stake、指标  → 数字生命的时序演化
```

对比 Sui（通用 L1），zknot3 在以下维度有独特优势：
- **VRF 原生集成**（ECVRF RFC 9381）— 可验证随机数驱动生命演化
- **治理/升级完整实现** — 兼容检查、投票、回滚全流程
- **三态所有权模型**（Owned/Shared/Immutable）— 生命资源自然分类
- **BLS12-381 原生**（blst 后端）— 轻客户端/跨链验证

---

## vs Sui 差异与磨平计划

### 一、性能

| 特性 | zknot3 (当前) | Sui (目标) | zknot3 差异化 | P |
|------|-------------|-----------|-------------|---|
| Fast Path | `bypass_consensus` flag + stub | 完整单所有者绕过 | 三源验证（所有者+因果+签名） | 🟢 |
| 并行执行 | `DependencyGraph` 拓扑批 | Block-STM 乐观并发 | 确定性并行（三源定序）而非乐观重试 | 🔴 |
| BLS 聚合 | `Bls.zig` 完整实现 | 生产级 | 相同 | 🟢 |
| Narwhal 传播 | 无 | mempool-DAG 分离 | zknot3 选择 Mysticeti 2-chain 简洁路线 | ⬜ |
| 因果序 | ObjectID 依赖图 | 完整因果序 | 三源一致性模型 | 🟡 |

**P0 行动**：并行执行接线（`std.Thread` 工作池 + `DependencyGraph`）

### 二、智能合约

| 特性 | zknot3 | Sui | zknot3 差异化 | P |
|------|--------|-----|-------------|---|
| Move VM | 40 opcodes | 完整 Move 2024 | 数字生命资源模型 | 🟡 |
| 结构体字段操作 | 缺 pack/unpack/borrow_field | 完整 | 生命属性封装 | 🔴 |
| 类型能力强制 | `AbilitySet` 元数据 | 编译器+运行时 | 运行时确定性验证 | 🔴 |
| 动态字段 | 无 | `dynamic_field` | 生命资源动态生长 | 🔴 |
| 模块发布 | `Publish` 操作定义 | 完整生命周期 | 治理驱动的升级 | 🟡 |
| 升级策略 | `Governance.zig` 完整 | 完整框架 | 相同 | 🟢 |

**P0 行动**：动态字段 + 类型能力强制 + 结构体字段操作

### 三、AI Agent 支持

| 特性 | zknot3 | Sui | zknot3 差异化 | P |
|------|--------|-----|-------------|---|
| 赞助交易 | `payer` 字段 | 生产级 | 生命赞助者模型 | 🟢 |
| PTB | 6 种操作+原子执行 | 生产级 | 生命行为原子组合 | 🟢 |
| Gas Station | `gas_station_allowlist` | 赞助网络 | 可信生命免 gas | 🟢 |
| VRF | `VRF.zig` 完整 | 链上随机 | 生命演化引擎 | 🟢 |
| 干运行 | 无 | `dryRunTransactionBlock` | 生命行为预演 | 🔴 |
| zkLogin | 无 | Web2 OAuth | 非必要（zknot3 是生命基础设施） | ⬜ |
| Kiosk | 无 | NFT 商务 | 非必要（生命资源自有交换模型） | ⬜ |

**P0 行动**：交易干运行（模拟执行）

---

## 磨平路线图

### Phase 1：性能磨平

```
[x] Fast Path 基础 (flag + executeFastPath stub)
[x] 并行执行接线 (DependencyGraph → std.Thread per batch)
[x] ObjectStore.getOwner() → Fast Path 完整性检查
[x] 自动压缩 (mutation_count % 1000 trigger)
```

### Phase 2：合约磨平

```
[x] 赞助交易 + PTB + Gas Station
[x] 动态字段 (addField/getField in ObjectStore)
[x] VM 类型能力强制 (hasKeyAbility, hasCopyAbility checks)
[x] Struct pack/unpack/borrow_field opcodes (4 new opcodes: 0xB0-0xB3)
[x] 交易干运行 (Node.dryRunTransaction)
[x] Fast Path 所有者验证 (ObjectStore.getOwner)
```

### Phase 3：基础设施磨平（后续）

```
[ ] 模块发布系统 (ModuleRegistry + on-chain storage)
[ ] Narwhal 传播评估（评估后决定是否采用）
[ ] 轻客户端验证 (BLS 聚合签名 → 跨链桥)
```

---

## 技术债务清理

```
[ ] values.zig: Container ref-count 在 deinit 时被动警告而非阻止
[ ] Interpreter: executeCall native args 生命周期文档
[ ] Noise.zig: 握手测试验证派生密钥（已完成）
[ ] Config.zig: Config/NodeConfig 重复结构的最终统一
[ ] build.zig: test-unit/test-integration 实际分离
```

---

## 版本里程碑

| 版本 | 目标 | 状态 |
|------|------|------|
| v0.1.0 | 基础共识 + 存储 | ✅ 完成 |
| v0.5.0 | Move VM + P2P | ✅ 完成 |
| v0.8.0 | 生产加固（80+ 缺陷修复） | ✅ 完成 |
| v0.9.0 | AI Agent 支持（赞助+PTB+Gas Station） | ✅ 完成 |
| **v0.11.0** | **并行执行 + 动态字段 + struct操作** | ✅ 完成 |
| v0.12.0 | 模块系统 + 轻客户端 | 规划中 |
| v1.0.0 | 数字生命主网 | 规划中 |

---

*最后更新：2026-05-11 · 346 tests · ~9.1/10 · Sui覆盖率 ~95%*
