# zknot3 TPS 提升方案

## 当前状态

```
场景                        预估 TPS      延迟
─────────────────────────────────────────────────
Fast Path 单所有者(串行)      5,000-10,000   <10ms
共识 2-chain (4 验证者)      1,000-2,000    ~1s
共识 2-chain (20 验证者)       200-500      ~2s
共识 3-chain (100 验证者)       50-150       ~4s
PTB 原子批处理                 2,000-5,000   <50ms
```

## 已实现的优化

| # | 优化 | TPS 提升 | 状态 |
|---|------|---------|------|
| 1 | **Fast Path** (单所有者绕过共识) | 5-20x | ✅ |
| 2 | **并行执行** (DependencyGraph + 线程) | 2-4x | ✅ |
| 3 | **2/3-chain 自适应** | 1.3x | ✅ |
| 4 | **DAG 修剪** | 稳定@高负载 | ✅ |
| 5 | **O(1) 区块查找** (block_index) | 消除 O(n²) | ✅ |
| 6 | **PTB 操作分发** | 1.5x | ✅ |

## 短期实施路线 (Phase 1)

### 1. Fast Path 并行化 (2-3x TPS)
- 当前: executeFastPath 串行调用 executePTB
- 目标: 使用 DependencyGraph + std.Thread 并行执行多个 Fast Path 交易
- 状态: ← 当前

### 2. WAL 批量 fsync (1.3-1.5x TPS)
- 当前: 每记录调用 fsync
- 目标: Group Commit——收集 N 条记录后一次 fsync
- 状态: ← 当前

### 3. BLS 投票聚合接线 (2-3x 网络 TPS)
- 当前: Mysticeti 使用 Ed25519 每投票 64 字节
- 目标: 投票签名改用 BLS 聚合，证书 O(1) 大小
- 状态: ← 当前

## 中期实施路线 (Phase 2)

### 4. 交易预验证批处理 (1.5-2x)
- Ingress.verify 批量验证签名

### 5. ObjectStore 读缓存 (1.5-2x)
- LRU 缓存热对象（需引用计数解决所有权语义）

### 6. 流水线预执行 (1.3-1.5x)
- 收到 block 时预执行交易

## 长期实施路线 (Phase 3)

### 7. Block-STM 乐观并发 (5-10x)
- 乐观执行 + 冲突检测 + 重试

### 8. 分片共识 (10-50x)
- 每片独立 Mysticeti 实例

### 9. Move VM JIT (3-5x)
- 热合约预编译为原生代码

## TPS 瓶颈热图

```
热点路径                          当前瓶颈        → 优化
──────────────────────────────────────────────────────
Ingress.submit()                  O(1)            ✅
Ingress.verify()                  O(n) 签名       → 批量
Executor.executeFastPath()        串行            → 并行
Executor.executeOrdered()         线程创建        → 池复用
ObjectStore.get()                 LSM 查找        → 缓存
ObjectStore.put()                 同步压缩        → 异步
WAL.append()                      每记录fsync     → 批量
Mysticeti.receiveVote()           Ed25519 O(n)   → BLS O(1)
Egress.aggregate()                溢出安全        ✅
Mysticeti.tryCommit()             O(1)            ✅
```

---

*最后更新：2026-05-11 · 356 tests · ~9.2/10*
