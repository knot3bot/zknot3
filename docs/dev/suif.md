# zknot3 vs Sui：能力差异对比（面向主网收口）

本文用 **Sui（Move + Object Model）** 作为参照系，梳理 **zknot3** 目前能力边界与差距，帮助你做“主网能力门禁 + Roadmap”。

## 一句话定位

- **Sui**：以 **对象（Object）+ 所有权（Owned/Shared）+ Move 模块化能力** 为中心的生产级公链平台；共识/执行/存储/索引/钱包生态均完备。
- **zknot3**：目前更接近“**具备共识 + 交易执行 + checkpoint proof/轻客户端验证** 的 PoC/测试网形态”，但尚未形成 Sui 那种完整的“对象模型 + Move 运行时能力面”与生态配套。

## 核心能力对标（高层）

### 1) 编程模型与执行环境

- **Sui**
  - **Move 包（Package）**发布与升级机制、模块版本管理
  - **对象模型**：Owned/Shared/Immutable/Child object；以 object 为状态基本单元
  - **类型系统约束**：`key/store/copy/drop` 能力标签；资源安全
  - **事务构造与依赖**：显式输入对象、共享对象冲突控制；并行执行友好
- **zknot3（当前）**
  - Move VM 有一定接入（可执行），但**对象模型/标准框架能力面不足**，更像“链内执行引擎”
  - 交易/状态抽象更偏基础设施层，缺少 Sui Framework 级的“开发者原语”
- **差距/影响**
  - 缺少 Sui 的对象所有权语义与标准模块，意味着 dApp 生态落地门槛更高、可组合性弱
  - 并行执行的关键前提（对象依赖与冲突模型）不完整，吞吐与可预测性受限

### 2) 账户、密钥与身份体系

- **Sui**
  - 标准账户体系、钱包/签名方案、zkLogin（部分场景）
  - 完整的地址派生、验签、交易序列化与通用 SDK
- **zknot3（当前）**
  - 已有 Ed25519、BLS 聚合签名（checkpoint proof）与节点侧签名密钥配置
  - SDK 正在形成（Zig runtime SDK + typed RPC + proof verify）
- **差距/影响**
  - 缺少通用钱包/序列化格式/跨语言 SDK 生态，用户/开发者触达成本高

### 3) 共识与最终性语义

- **Sui**
  - Narwhal/Bullshark 系列演进（历史）与稳定的最终性语义、可观测性、主网运维经验
  - 验证者集管理与 epoch 切换是“第一等能力”
- **zknot3（当前）**
  - 共识/网络/存储完成了多项 P0 硬化（WAL、TSAN、异步 I/O、BLS proof 等）
  - 但 **epoch/validator set** 在缺少 epoch_bridge 时需要 fallback（已补静态 stake）
- **差距/影响**
  - 治理/再配置（validator set 变更）仍偏“工程集成”，不是协议层稳定能力

### 4) 状态存储与数据可用性（DA）

- **Sui**
  - 对象状态与历史查询、索引体系、事件系统、checkpoint/同步工具链完善
- **zknot3（当前）**
  - LSM/WAL/ObjectStore 等基础设施存在，但链上“对象/事件/索引”开发者面尚不完整
  - Dashboard/GraphQL/RPC 已有雏形，但数据模型与查询能力还需要扩展
- **差距/影响**
  - 缺少事件索引与对象历史查询会直接限制生态工具（浏览器、分析、风控）

### 5) 轻客户端与证明

- **Sui**
  - checkpoint + 证明体系成熟，客户端/索引可依赖
- **zknot3（当前）**
  - 已实现 `CheckpointProof`（BLS 聚合签名 + bitmap + stake-weighted quorum）与 SDK 校验
- **差距/影响**
  - 证明能力已经接近“可用”，但需要与“对象/事件/索引”体系一起形成闭环

### 6) 生态与运维（非纯代码能力，但决定主网成败）

- **Sui**
  - 钱包/浏览器/索引器/节点运维/监控/灰度/应急预案成熟
- **zknot3（当前）**
  - 已开始形成 testnet/mainnet runbook、release gates、对抗性测试
- **差距/影响**
  - 仍缺少成熟的生态组件与长期运行数据（SLO/SLA、攻击面实战）

## 结论：哪些差异是“必须补齐”的？

### 必须补齐（主网门禁级，偏协议/安全/运维）

- **验证者集与 stake 分布**：协议/配置层可追溯、可观测、可回滚；Dashboard/接口一致
- **交易格式与客户端生态最小闭环**：至少有 1~2 种主流语言 SDK + 稳定序列化/签名规则
- **索引/事件最小可用**：让区块浏览器、风控、统计能落地
- **DoS/资源控制**：请求限流、分页、上限、存储增长与修剪策略（你已开始补分页与 gate）

### 可后置（P1/P2，面向生态繁荣）

- 完整 Sui Framework 等价物（coin/balance/pay、table/bag、kiosk、policy/denylist）
- zkLogin / Groth16 等复杂密码学与合规模块

---

## Sui Framework 能力面参考（用于对标）

Sui 公链**无“内置智能合约账户”**，其所有智能合约均以 **Move 包（Package）** 形式发布，核心依赖 **Sui Framework（sui::*）** 与 **Move 标准库（std::*）** 这两套官方原生模块，为链上开发提供底层能力。

### 核心原生模块清单（按功能域）


| 功能域    | 核心模块                                            | 核心能力                                         |
| ------ | ----------------------------------------------- | -------------------------------------------- |
| 代币标准   | `sui::coin`/`sui::balance`/`sui::pay`           | 定义 SUI 与自定义代币，支持铸造、销毁、转账与支付抽象                |
| 对象与所有权 | `sui::object`/`sui::transfer`/`sui::tx_context` | 对象 ID/UID 管理、转移/共享/冻结、交易上下文与发送者地址            |
| 复杂集合   | `sui::bag`/`sui::table`/`sui::vec_map`          | 异构键值对、有序映射、向量映射，适配多样数据组织                     |
| 交易与事件  | `sui::event`                                    | 链上事件发射与索引，供外部系统监听                            |
| 密码学原语  | `sui::hash`/`sui::bls12381`/`sui::ed25519`      | 哈希（Keccak256/Blake2b）、BLS12-381、Ed25519 签名验证 |
| 时间与随机  | `sui::clock`/`sui::random`                      | 链上时间源、安全随机数生成                                |
| 合规与流转  | `sui::deny_list`/`sui::transfer_policy`         | 黑名单控制、转账策略与白名单审批                             |
| 租赁与交易  | `sui::kiosk`                                    | 去中心化、信任less 的 NFT/资产租赁与交易                    |
| 零知识证明  | `sui::groth16`/`sui::zklogin_verified_id`       | Groth16 证明验证、zkLogin 身份验证                    |


### 关键说明

- **模块即合约能力**：开发者通过发布 Move 包导入 `sui::`*/`std::`* 模块，组合实现业务逻辑，无“内置合约实例”概念。
- **隐式导入**：`sui::object`、`sui::transfer`、`sui::tx_context` 等核心模块在 Move 代码中**隐式可用**，无需手动 `use`。
- **标准库分层**：`std::`* 提供通用语言能力（如 `std::vector`、`std::hash`），`sui::`* 提供 Sui 专属链上原语（如对象、转账、代币）。

### 快速使用示例

```move
// 导入核心模块
use sui::coin;
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// 定义自定义代币
struct MY_TOKEN has key, store { id: UID, value: u64 }

// 铸造并转移代币
public entry fun mint(recipient: address, amount: u64, ctx: &mut TxContext) {
    let token = MY_TOKEN { id: object::new(ctx), value: amount };
    transfer::public_transfer(token, recipient);
}
```

### 资源获取

- **官方文档**：Sui Framework 完整模块清单与用法 → [docs.sui.io/references/framework/sui](https://docs.sui.io/references/framework/sui)
- **源码仓库**：Sui 核心框架实现 → [github.com/MystenLabs/sui/tree/main/crates/sui-framework](https://github.com/MystenLabs/sui/tree/main/crates/sui-framework)

