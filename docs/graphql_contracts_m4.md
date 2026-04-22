# zknot3 M4 GraphQL Contracts (Executable Interfaces)

这些字段用于 M4 主网扩展接口预留，当前已接入真实调用链：

- `GraphQL -> Node -> MainnetExtensionHooks`

现阶段为可执行语义：stake/governance 直接进入 M4 状态机，checkpoint proof 返回可验证载荷。

## Schema Surface

### Query

#### `knot3_getCheckpointProof(sequence: Int!, objectId: ID!): CheckpointProof`

- 参数（**全部必填**；缺省/非法 hex / 非法 `sequence` 将失败，与 `M4RpcParams.parseCheckpointProofFromPlainArgs` 一致）
  - `sequence`: 检查点序号（`>= 0` 的整数）
  - `objectId`: 对象 ID（**64 位十六进制**，可选 `0x` / `0X` 前缀；必须为 32 字节）
- 返回类型 `CheckpointProof`
  - `sequence: Int`
  - `stateRoot: String`
  - `proof: String`
  - `signatures: String`

示例：

```graphql
query {
  knot3_getCheckpointProof(sequence: 9, objectId: "0x00") {
    sequence
    stateRoot
    proof
    signatures
  }
}
```

---

### Mutation

#### `knot3_submitStakeOperation(validator: ID!, delegator: ID!, amount: Int!, action: String!, metadata: String!): StakeOperationReceipt`

- 参数（**全部必填**；`metadata` 可为空字符串；`amount` 必须 `> 0`；`action` 必须为枚举之一，否则解析失败）
  - `validator`: 32 字节地址（64 hex，支持 `0x`）
  - `delegator`: 32 字节地址（64 hex，支持 `0x`）
  - `amount`: 操作金额（>0）
  - `action`: `stake|unstake|reward|slash`
  - `metadata`: 文本（允许 `""`）
- 返回类型 `StakeOperationReceipt`
  - `status: String`（当前固定 `"accepted"`）
  - `operationId: Int`（真实递增 ID）

示例：

```graphql
mutation {
  knot3_submitStakeOperation(
    validator: "0x01"
    delegator: "0x02"
    amount: 10
    action: "stake"
    metadata: "bootstrap"
  ) {
    status
    operationId
  }
}
```

#### `knot3_submitGovernanceProposal(proposer: ID!, title: String!, description: String!, kind: String!, activationEpoch: Int): GovernanceProposalReceipt`

- 参数
  - `proposer`: 32 字节地址（64 hex）
  - `title`: 标题（非空）
  - `description`: 描述（非空）
  - `kind`: `parameter_change|chain_upgrade|treasury_action`
  - `activationEpoch`: 可选；省略时不发送该字段（与 JSON-RPC `activation_epoch` 可选语义对齐）
- 返回类型 `GovernanceProposalReceipt`
  - `status: String`（当前固定 `"accepted"`）
  - `proposalId: Int`（真实递增 ID）

示例：

```graphql
mutation {
  knot3_submitGovernanceProposal(
    proposer: "0x09"
    title: "raise-max-connections"
    description: "adjust network safety cap"
    kind: "parameter_change"
    activationEpoch: 128
  ) {
    status
    proposalId
  }
}
```

## 对应代码位置

- GraphQL schema 与 resolver：`src/app/GraphQL.zig`
- Node M4 接口：`src/app/Node.zig`
- Mainnet hooks 管理器：`src/app/MainnetExtensionHooks.zig`
- JSON-RPC 合约文档：`docs/rpc_contracts_m4.md`

## 兼容性说明

- 字段名继续与 `knot3_` RPC 命名保持一致（如 `objectId` camelCase、GraphQL `activationEpoch` → 内部 `activation_epoch` 映射）。
- `proof` / `signatures` 为 **十六进制编码的可验证载荷**（Ed25519 多签清单 + quorum），详见 `docs/rpc_contracts_m4.md` 与 `LightClient.verifyCheckpointProofQuorum`。
- 解析失败时 resolver 返回 `error.InvalidParams`（由 GraphQL 执行层表现为查询/变更失败）；HTTP 网关若桥接 JSON-RPC，请使用 **`-32602`** 映射以保持运维一致性。
