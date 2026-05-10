# Creator³ — 人机共创进化网络

## 定位

Creator³ 是构建在 zknot3 三源合恰可信基础设施之上的**人机共创进化网络**。

```
人类表达创意 ──→ AI机器协同创作 ──→ 三源合恰永久存储/溯源/演化
```

### 三源映射

```
形 (Spatial Topology)  → 创作存储、P2P 传播、共识确认
性 (Intrinsic Attribute) → 所有权、溯源、版税、许可
数 (Quantitative Measure) → 创作版本、贡献权重、演化时间线
```

---

## 一、创作溯源（Provenance）

每一创作在链上拥有完整的溯源链：

| 能力 | 实现 |
|------|------|
| **创作时间戳** | Checkpoint 序列号 + Block 时间戳 |
| **创作者身份** | Transaction.sender Ed25519 签名（不可否认） |
| **贡献图谱** | PTB 原子操作链——可追踪每一步创作操作 |
| **不可篡改记录** | DAG 共识 + WAL 崩溃恢复——创作不被篡改 |
| **版本演进** | ObjectStore Causal Versioning（version.seq + causal 向量） |
| **创作分支** | ObjectID 依赖图——支持 Fork/Merge/Rebase 创作 |

### 创作者身份验证

```
┌─────────────────────────────────────────────┐
│  人类创作者                AI 创作代理       │
│      │                        │              │
│  Ed25519 密钥签名        zkLogin (OAuth)    │
│      │                        │              │
│      └────────┬───────────────┘              │
│               │                               │
│     Transaction.sender 不可否认               │
│               │                               │
│     Checkpoint 时间戳 + 区块号                │
└─────────────────────────────────────────────┘
```

---

## 二、协作所有权

### 三态所有权模型

```
Owned   (个人创作)     → 创作者拥有完全控制权
Shared  (协作创作)     → 多人/多AI 共同拥有，BLS多签决策
Immutable (公共创作)   → 永久冻结，人类公共数字遗产
```

### 协作机制

| 能力 | 实现 |
|------|------|
| **共享对象** | Ownership.Shared(context) —— 多人共享一个创作 |
| **多签创作** | BLS 聚合签名——N 个创作者只需 1 个 96 字节签名 |
| **版税分配** | PTB SplitCoins——自动按比例分账 |
| **赞助创作** | payer ≠ sender——赞助方支付 gas，创作者专注创作 |
| **动态协作者** | Dynamic Fields——动态添加/移除协作者 |
| **AI Agent 参与** | Gas Station 白名单——信任的 AI Agent 免 gas 创作 |

### 版税流

```
创作销售
    │
    ▼
PTB SplitCoins([creator:70%, co-creator:20%, platform:10%])
    │
    ├──→ 创作者地址 (70%)
    ├──→ 协作者地址 (20%)
    └──→ 平台地址 (10%)
```

---

## 三、AI 机器协同

### AI 创作代理

| 能力 | 实现 |
|------|------|
| **AI 自主创作** | payer ≠ sender → AI Agent 是 sender，赞助方是 payer |
| **创作预演** | dryRunTransaction → 创作前模拟所有操作效果 |
| **原子多步创作** | PTB 6 操作类型——MoveCall + TransferObjects + SplitCoins 一步完成 |
| **随机创意种子** | VRF 确定性随机数 → AI 生成艺术的可验证随机性 |
| **创作事件流** | Event.emit → 创作活动实时索引、AI 可订阅创作事件 |
| **AI 身份桥接** | zkLogin (OAuth/OIDC) → AI Agent 用 Web2 身份认证 |

### AI 协同流程

```
人类 (创意表达)
    │
    │ "生成 100 幅赛博朋克风格作品，色调偏蓝"
    │
    ▼
AI Agent (GPT/Claude/Stable Diffusion)
    │
    ├─→ 调用 VRF 生成随机种子
    ├─→ 批量生成 100 幅作品
    ├─→ PTB: [Publish(100 works), TransferObjects(creator, 100)]
    ├─→ dryRunTransaction 检查
    └─→ 提交 PTB → 链上永久存储
         │
         ▼
    创作者获得 100 个 ObjectID
    ObjectStore 永久存储创作内容 + 元数据
    Indexer 索引创作事件 → 可搜索
```

---

## 四、许可编程模型

创作自动附带许可信息：

```
Creation object {
    id: ObjectID,
    data: <创作内容>,
    license: License {
        type: CC0 | CC-BY | CC-BY-SA | MIT | CUSTOM | AllRightsReserved,
        terms: "可用于商业用途，需署名原作者",
        royalty_bps: 500,  // 5% 版税 (基点)
        expiration: 0,     // 0 = 永久
    },
    creator: Address,
    created_at: Epoch,
    version: Version,
    parent_ids: [ObjectID],  // 衍生创作的源创作
}
```

---

## 五、创作引用图 API

### GraphQL 查询

```graphql
# 查询创作的演化树
query CreationTree($root_id: ObjectID!) {
  creation(id: $root_id) {
    id, creator, created_at, version
    parents { id, creator }      # 从哪里派生
    children { id, creator }     # 谁派生了我
    collaborations { id, role }  # 谁协作了这个创作
    license { type, royalty_bps }
  }
}

# 查询创作者的完整作品集
query CreatorPortfolio($creator: Address!) {
  creations(creator: $creator, orderBy: created_at_DESC) {
    id, version, license, created_at
    childCount    # 有多少衍生作品
    forkCount     # 被分叉了多少次
  }
}
```

---

## 六、数字生命演化

```
创作生命期:

Birth    →  Owned(创作者)         + 许可声明
Grow     →  Shared(协作者)        + 动态协作者 + 版本迭代
Evolve   →  衍生创作(Fork)        + 引用父创作
Mature   →  Immutable(公共遗产)   + 永久冻结
Legacy   →  被引用、被衍生         + 不可篡改的创作链
```

### 三源度量

```
形 (存储) → ObjectStore 中的创作数量和大小
性 (属性) → 所有权分布、许可类型分布、版税流动
数 (演化) → 创作版本数、Fork 数、协作数、引用数
```

---

## 实施路线图

| Phase | 内容 | 状态 |
|-------|------|------|
| **Phase 1: 基础创作** | 签名+时间戳+版本化+PTB 多步创作 | ✅ 完成 |
| **Phase 2: 协作** | Shared 所有权+BLS 多签+赞助+AIGasStation | ✅ 完成 |
| **Phase 3: AI 协同** | dryRun+VRF+Event.emit+Gas Station | ✅ 完成 |
| **Phase 4: 身份** | zkLogin (OAuth/OIDC) → AI Agent Web2 桥接 | ← 当前 |
| **Phase 5: 许可** | License 类型系统 + 自动版税 | ← 当前 |
| **Phase 6: 引用图** | ObjectID 依赖图 API + GraphQL 查询 | ← 当前 |

---

*Creator³ — 三源合恰，人机共创，数字生命演化*
