# Mysticeti 并发模型与不变量

## 目标
- 明确 `Mysticeti` / 共识入口相关共享状态的访问边界。
- 给出在高并发调度下必须保持的不变量，并与测试对应。

## 共享状态分层
- `Node.pending_blocks` / `Node.committed_blocks`：由共识入口与提交协调器读写。
- `Mysticeti.dag` / `Mysticeti.committed_rounds`：共识线程拥有，外部通过协调器访问。
- `TxnPool.priority_queue` / `TxnPool.by_sender`：单写者（执行/入口环），指标线程只读原子镜像。

## 加锁/同步策略
- `TxnPool`：结构体容器不跨线程共享写；并发观测仅通过原子计数器 (`metric_*`)。
- `NodeStatsCoordinator`：统计走原子快照，避免指标端与提交路径发生数据竞争。
- 共识入口：对重复 vote / block 做幂等处理，避免重复插入导致状态漂移。

## 关键不变量
- 同一 `voter + round + block_digest` 不应生成 equivocation 证据。
- 同一 `voter + round` 若指向不同 `block_digest`，必须生成 equivocation 证据。
- TxnPool 不允许 `sender + sequence` 重复进入待执行集合。

## 对应测试
- `test/property/mysticeti_concurrency_test.zig`
  - `mysticeti_property: same voter+round with same digest is never equivocation`
  - `mysticeti_property: same voter+round with different digest always yields evidence`
- `src/pipeline/TxnPool.zig` 现有 `TxnPool rejects duplicate`

## TSAN 运行约定
- 命令：`zig build -Dtsan=true test --summary all`
- 目的：在 sanitizer 构建中执行同一组测试，辅助发现潜在数据竞争。
