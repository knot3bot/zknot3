
## 建议的修复优先级（建议按这个顺序）

1. 先修 **并发数据竞争**（Mysticeti 并行写）与 **重复执行交易**。  
2. 修 **WAL 校验一致性**，补恢复回归测试（断电/截断/脏页场景）。  
3. 补齐 **交易签名校验链路**（HTTP/RPC 入口到执行前）。  
4. 重构 **P2P 握手** 为 challenge-response 双向绑定，加入重放窗口控制。  
5. 再做性能专项（真实 io_uring、批处理、锁分层）。  

## 实施状态（当前分支）

- [x] P0-1 Mysticeti 并发写共享状态（先以串行应用方案消除 data race）
- [x] P0-2 `tryCommitBlocks` 重复执行交易
- [x] P0-3 WAL checksum 前后不一致
- [x] P0-4 交易入口签名校验链路
- [x] P0-5 P2P 握手双向 challenge + 重放窗口
- [x] P1-1 IO 能力边界澄清 + 最小真 io_uring 路径（read/write/fsync，失败自动回退 blocking）
- [x] P1-1.1 WAL/LSM 持久化屏障收口（`WAL.syncBarrier` + `batchCommit` 后 `syncAll`）
- [x] P1-2 Node 减耦第一步（抽取交易准入校验逻辑）
- [x] P1-2.1 Node 减耦第二步（新增 `TxnAdmission` 模块，Node 仅组装上下文调用）
- [x] P1-2.2 Node 减耦第三步（新增 `BlockCommit` 模块，抽离提交编排与裁剪逻辑）
- [x] P1-2.3 Node 减耦第四步（新增 `BlockExecution` 模块，抽离 payload 解析与执行聚合）
- [x] P1-2.4 Node 减耦第五步（新增 `TxExecutionCoordinator`，抽离单笔/批量执行编排）
- [x] P1-2.5 Node 减耦第六步（新增 `NodeStatsCoordinator`，统一统计写入入口）
- [x] P1-2.6 Node 减耦第七步（新增 `ConsensusIngressCoordinator`，抽离区块/投票入口编排）
- [x] P1-2.7 Node 减耦第八步（新增 `NodeLifecycleCoordinator`，抽离启动/恢复生命周期流程）
- [x] P1-2.8 Node 减耦第九步（新增 `NodeMetricsCoordinator`，抽离指标聚合计算逻辑）
- [x] P1-2.9 Node 减耦第十步（新增 `ObjectStoreCoordinator`，抽离对象存储访问透传）
- [x] P1-2.10 Node 减耦第十一步（新增 `NodeInfoCoordinator`，抽离系统/验证者信息查询逻辑）
- [x] P1-2.11 Node 减耦第十二步（新增 `TxnPoolCoordinator`，抽离交易池查询与维护逻辑）
- [x] P1-2.12 Node 减耦第十三步（新增 `CommitCoordinator`，抽离提交主循环编排逻辑）
- [x] P1-2.13 Coordinator 回归测试增强（`CommitCoordinator` 空路径/Quorum/回调/晋升单测）
- [x] P1-2.14 Coordinator 回归测试增强（`NodeLifecycleCoordinator` 与 `NodeInfoCoordinator` 最小闭环单测）
- [x] P1-2.15 Coordinator 回归测试增强（`TxnPoolCoordinator` 与 `ObjectStoreCoordinator` 最小闭环单测）
- [x] P1-3 第一批对抗回归脚手架（交易入口格式/签名输入校验用例）
- [x] P1-3.1 第二批对抗覆盖（握手畸形包负例 + WAL 截断恢复 + `tools/adversarial_test.py` 洪泛/畸形压测）
- [x] P1-3.2 第三批对抗覆盖（`Transport.Message.deserialize` 截断/长度越界负例 + HTTP 慢速客户端 / 超大 `Content-Length` 压测脚本）
- [x] P1-3.3 第四批对抗覆盖（P2P 端口半连接/截断头/超大 payload 长度 + 攻击后 `/health` 活跃性回归）
- [x] P1-3.4 长时稳定性 soak 模式（`tools/adversarial_test.py --soak <hours> [--sample-interval N]`：后台持续 flood + 周期采样 `/metrics`、`docker stats` RSS、`/proc/1/fd` FD，终了比对漂移并 verdict）
- [x] P1-1.2 WAL 持久化屏障链式提交（新增 `AsyncIO.writeAndFsync` 使用 `IOSQE_IO_LINK` 将 WAL write+fsync 合并为单次 `submit_and_wait(2)`；`WAL.appendRecord` / `flushAsync` 统一走 `writeDurable` 包装，非 Linux/回退路径保持原 `pwrite+fsync` 语义）
- [x] P1-1.3 WAL 真 `writev + fsync` 链式提交（新增 `AsyncIO.WriteOp/ReadOp` + `writeBatch/readBatch` 批量原语与 `writevAndFsync` 链式原语；`WAL.appendRecord` 同步路径改走 `writevDurable`，直接 pwritev header/key/value 三段 iovec，消除记录级 memcpy 合并缓冲。新增 `AsyncIO writeBatch + readBatch roundtrip` 与 `AsyncIO writevAndFsync gathered write` 两个单测，全量 `zig build` 与 `IOUring.zig` 9/9 单测通过）
- [x] P1-1.4 共识热点锁分层（`NodeStats` 改为 `std.atomic.Value(u64)`，`NodeStatsCoordinator` 提供 `snapshot`/`txExecuted`/`totalGas`/`blocksCommitted`/`highestRound` lock-free 读路径；`TxnPool` 新增 `metric_received/executed/pool_size/sender_count` 原子镜像 + `metricsSnapshot()`，`TxnPoolCoordinator.getTxnPoolStats/getPendingTxnCount` 改走原子快照；Dashboard/HTTP 度量全部切到快照读。补充 `NodeStatsCoordinator concurrent writers + reader snapshot is torn-free` 与 `TxnPoolCoordinator metricsSnapshot races cleanly vs writer thread` 两个并发单测，`zig build` / `zig build test` 通过）
- [x] P1-1.5 `CommitCoordinator` 主循环自适应批量（新增 `AdaptiveBatchState`（AIMD：双倍增长 / 减半收缩，min=1、max=256）与 `tryCommitBatch` 原语；`Node.tryCommitBlocksBatch` 外包 onQuorumBlock/onOutcome 回调并自动打点 `NodeStatsCoordinator.onBlockCommitted`；`ConsensusIntegration.tryCommit` 改为一次性拉取 `budget` 个 cert，再把实际 drain 数喂回 AIMD，空转时窗口快速缩到 1、突发时几拍扩到 256。`src/main.zig` 主循环改用指数回退（1ms→50ms）替代固定 10ms idle sleep，有活就压回最小值。新增 `AdaptiveBatchState` 增长/收缩/上限与 `tryCommitBatch` 批量 drain 单测，`zig build` / `zig build test` 通过）

## 主网上线前审计修复清单（可执行版）

### P0（必须完成，否则禁止上线）

| 编号 | 问题 | 目标 | 负责人建议 | 预计工期 |
|---|---|---|---|---|
| P0-1 | Mysticeti 并发写共享状态 | 消除 data race，保证共识状态确定性 | 共识模块 owner | 1-2 天 |
| P0-2 | `tryCommitBlocks` 重复执行交易 | 每块只执行一次，杜绝重复副作用 | 执行/节点 owner | 0.5 天 |
| P0-3 | WAL checksum 前后不一致 | 写入与回放同一算法同一数据域 | 存储模块 owner | 1 天 |
| P0-4 | 交易入口缺少签名校验链路 | 未签名/伪造交易必须被拒绝 | 网络+执行 owner | 1 天 |
| P0-5 | P2P 握手防重放不足 | 双向 challenge + 会话绑定 + 时效验证 | 网络模块 owner | 1-2 天 |

### P1（建议上线前完成）

| 编号 | 问题 | 目标 |
|---|---|---|
| P1-1 | `IOUring` 能力名实不符 | 明确能力边界或实现真实异步路径 |
| P1-2 | `Node` 职责过重 | 拆分执行/共识/恢复协调逻辑，降低耦合 |
| P1-3 | 压测与模糊测试覆盖不足 | 补 DoS、畸形包、断电恢复场景 |

---

## 逐项改动点与验收标准

### P0-1 Mysticeti 并发写共享状态

**改动点**
- 禁止在 worker 线程直接写 `dag`/`votes`。
- 方案 A（推荐）：worker 只做预处理，主线程串行应用 `processVote/receiveVote`。
- 方案 B：对 `dag` 和每轮 `votes` 引入锁（需要严格锁顺序，避免死锁）。

**验收标准**
- TSAN/并发压测中无 data race 报告。
- 同一输入回放 100 次，区块提交结果完全一致（digest 序列一致）。

### P0-2 交易重复执行

**改动点**
- `Node.tryCommitBlocks()` 中移除第二次 `executeBlockTransactions` 调用。
- 统一执行结果生命周期：只分配/释放一次。
- 增加防回归断言：同一 block digest 在同一提交路径只能执行一次。

**验收标准**
- 单元测试验证每次提交仅一次执行。
- 压测下 gas 与 tx 统计不再翻倍。

### P0-3 WAL 校验一致性

**改动点**
- 抽出统一函数 `computeRecordChecksum(header_without_checksum, key, value)`，写入和回放共用。
- 回放时按完整记录（header[4..] + key + value）重算 checksum。
- 对 `skip_corrupted` 逻辑补边界：截断、长度溢出、类型非法。

**验收标准**
- 正常 WAL 回放 100% 成功，无误判损坏。
- 人工篡改 WAL 字节后能稳定识别坏记录并按策略处理。

### P0-4 交易签名校验链路

**改动点**
- `Node.submitTransaction` 增加 `tx.verifySignature()` 检查（生产默认强制）。
- HTTP/RPC `/tx` 路径必须提交 `signature + public_key`，否则 4xx。
- 交易 digest 与签名字段保持一致定义，避免“签名对象”和“执行对象”不一致。

**验收标准**
- 未签名、错签名、重放签名全部拒绝。
- 合法签名交易可入池并执行。

### P0-5 P2P 握手防重放

**改动点**
- 握手改为双向 challenge：A 发 `nonce_a`，B 回复 `sign(nonce_a, nonce_b, context)`，A 再确认。
- `context` 至少绑定：协议版本、连接方向、时间窗、对端公钥。
- 增加 nonce 缓存与过期窗口（例如 30-60 秒）防重放。

**验收标准**
- 抓包重放旧握手包无法建立连接。
- 错误时钟、重复 nonce、跨连接重放均被拒绝。

---

## 测试用例模板（可直接复制）

### 模板 A：功能正确性

```text
[用例名称]
前置条件:
输入:
步骤:
预期结果:
失败判定:
日志关键字:
```

### 模板 B：安全对抗

```text
[攻击场景]
攻击向量: (重放/伪造/畸形包/洪泛)
测试步骤:
防护预期:
观测指标: (拒绝率/断连数/CPU/内存/错误码)
通过标准:
```

### 模板 C：性能回归

```text
[性能基线项]
场景: (TPS/延迟/恢复时长/连接数)
基线值:
当前值:
允许回退阈值:
结论: PASS/FAIL
```

---

## 最小回归测试矩阵（建议）

| 维度 | 最小集 |
|---|---|
| 共识一致性 | 4/7/13 节点，单分叉与双分叉场景 |
| 网络攻击 | 畸形包、握手重放、交易洪泛、慢连接 |
| 存储恢复 | 正常退出、kill -9、WAL 截断、WAL 篡改 |
| 性能 | 低/中/高负载下 TPS、P99、CPU、内存 |

---

## 上线闸门（Go/No-Go）

### 必须满足（全部）
- P0 项全部完成并通过回归。
- 72 小时压测无共识分叉、无崩溃、无不可恢复 WAL 错误。
- 安全对抗用例通过率 >= 99%（允许非关键告警，不允许关键绕过）。
- 关键指标未劣化超过阈值（TPS、P99、恢复时长）。

### 一票否决
- 任一 data race 未关闭。
- 任一未授权交易可入池/执行。
- 任一可复现握手重放成功案例。
- 任一 WAL 恢复误判导致数据不可用。