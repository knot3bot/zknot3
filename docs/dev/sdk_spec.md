---
name: zknot3 Zig Client SDK 需求规格说明书
status: draft
audience:
  - zknot3 应用开发者（Zig）
  - 运维/集成工程师（脚本化调用）
  - 轻客户端/监控集成
non_goals:
  - 共识参与（validator 全流程）
  - 完整状态同步/历史索引
  - Move 合约本地执行器（除非后续单列）
compat:
  node_impl: zknot3 (Zig)
  apis:
    - HTTP (/health, /tx, /metrics)
    - JSON-RPC (knot3_* / m4_*)
    - GraphQL (查询与 proof 字段)
zig:
  minimum: "0.15.0"
---

# zknot3 Zig Client SDK 需求规格说明书

## 1. 背景与目标

### 1.1 背景
zknot3 提供了 HTTP（`/health`、`/tx`、`/metrics`）、JSON-RPC（`knot3_*`）、GraphQL（查询与 proof）三套对外接口。为了让上层应用与工具链能稳定、可观测地集成 zknot3，需要一个**官方 Zig Client SDK**，提供统一的连接管理、请求/响应类型、错误模型、重试/超时策略、以及对关键协议（tx admission、checkpoint proof、BLS 聚合签名）的封装。

### 1.2 目标（本轮）
- **开发者体验**：Zig 原生类型安全 API（请求/响应 struct）、一致的错误码/错误分类、可注入 allocator。
- **生产可用**：连接池/限流/超时/重试、可观测（trace id / metrics hook）、幂等与重放语义可编程。
- **协议对齐**：对 `/tx` 的 nonce/duplicate 语义、对 `CheckpointProof` 的 BLS 字段校验形成闭环（可与 LightClient/Checkpoint 逻辑一致验证）。
- **版本治理**：明确语义化版本、API 兼容策略、与节点协议版本（或能力探测）关系。

## 2. 范围（Scope）

### 2.1 必须支持（P0）
1. **基础连接与健康检查**
   - `GET /health`
   - 可配置 timeout / retry / backoff
2. **交易提交（HTTP /tx）**
   - 构建 tx body（含 nonce 变体：`sender+pk+sig[:nonce]`）
   - 解析响应：accepted / duplicate / invalid_signature / invalid_nonce 等
   - 幂等策略：同一 digest 重发不重复入池（以服务端 `duplicate=true` 为依据）
3. **JSON-RPC 调用**
   - 支持 `knot3_*` 与 M4 扩展方法（按现有 RPC 约定）
   - 统一请求 id、错误码映射、超时与重试
4. **Checkpoint proof 获取与校验**
   - RPC：`knot3_getCheckpointProof`（含 `bls_signature`、`bls_signer_bitmap`）
   - GraphQL：对应 proof 字段
   - 校验：可在 SDK 内对 proof message、bitmap quorum、BLS 聚合验签执行一致验证
5. **错误模型**
   - transport / protocol / application 三层分类
   - 保留原始错误信息与可程序化判断的枚举错误

### 2.2 应该支持（P1）
- **批量请求**：JSON-RPC batch、/tx 并发提交批量
- **观察能力**：抓取 `/metrics`（用于集成侧自检/门禁）
- **GraphQL 客户端**：查询 schema 能力（轻量，至少支持 proof 查询用例）
- **能力探测**：节点 capabilities（通过探测特定方法或版本端点）

### 2.3 暂不做（Non-goals）
- validator 出块/投票/共识参与 API（另开 spec）
- 完整 light-client 同步协议（本轮只做 proof 校验原语）
- Move VM 本地执行与 gas 估算（另开 spec）

## 3. 设计原则

1. **类型安全优先**：请求/响应均以 struct 表达，避免“裸 JSON map”。
2. **可注入资源**：allocator、logger、clock、random、HTTP 传输层均可注入，便于测试与嵌入式使用。
3. **可观测性内建**：每次请求产生 `RequestMeta`（attempt、latency、node、endpoint、error_kind）。
4. **错误可判定**：错误必须可 machine-readable（枚举 + 结构化字段），同时保留字符串详情。
5. **安全默认**：默认启用合理 timeout、限制并发与重试，避免“默认把线上打挂”。

## 4. 对外 API（Zig）

> 命名约定：模块 `sdk`，核心类型 `Client`；每个接口域有子模块：`rpc`、`http`、`graphql`、`proof`、`tx`。

### 4.1 顶层模块结构（建议）
```
src/app/ClientSDK.zig            # 现有文件（可扩展或生成）
src/sdk/
  root.zig                       # `pub const Client = ...`
  transport.zig                  # HTTP transport abstraction
  http.zig                       # /health /tx /metrics
  rpc.zig                        # JSON-RPC client + typed methods
  graphql.zig                    # GraphQL client（最小实现）
  tx.zig                         # tx body builder + result parsing
  proof.zig                      # CheckpointProof fetch/verify helpers
  errors.zig                     # error model + mapping
  retry.zig                      # backoff/retry policies
  types.zig                      # shared wire structs
test/sdk_*.zig                   # 单元/集成测试
```

### 4.2 Client 配置

#### 4.2.1 `ClientOptions`
- `endpoints: []const Endpoint`（支持多节点、failover、负载均衡）
- `default_timeout_ms: u32`
- `max_retries: u8`
- `retry_policy: RetryPolicy`（指数退避 + jitter）
- `concurrency_limit: u32`（SDK 侧限流）
- `user_agent: []const u8`
- `allocator: std.mem.Allocator`
- `logger: ?Logger`（可选）

#### 4.2.2 `Endpoint`
- `scheme: enum { http }`（本轮仅 http）
- `host: []const u8`（如 `127.0.0.1`）
- `rpc_port: u16`
- `tags: []const []const u8`（如 `validator`/`fullnode`）

### 4.3 HTTP 域

#### 4.3.1 `health()`
- **输入**：`HealthRequest{ endpoint_selector?, timeout? }`
- **输出**：`HealthResponse{ healthy: bool, consensus_round: u64, peers: u32, ... }`
- **验收**：
  - 可配置重试；遇到 `env_timeout`/`env_connection_reset` 做有限次重试

#### 4.3.2 `submitTx()`
- **输入**：
  - `TxEnvelope`（SDK 生成 body）
  - 或直接传 `[]const u8` body（高级模式）
  - `SubmitOptions{ expect_idempotent: bool, timeout?, retries?, target: EndpointSelector }`
- **输出**：`SubmitResult`（见 5.2）

#### 4.3.3 `metrics()`
- **输入**：`MetricsRequest`
- **输出**：`std.StringHashMap(f64)` 或 typed subset（P1）

### 4.4 JSON-RPC 域

#### 4.4.1 通用调用
- `call(method: []const u8, params: anytype) -> RpcResult(anytype)`
- 支持 request id（u64），支持 batch（P1）

#### 4.4.2 必须封装的方法（P0）
- `knot3_getCheckpointProof(sequence: u64, object_id: [32]u8) -> CheckpointProofWire`
- `knot3_submitStakeOperation(...)`（若作为集成方需要）
- `knot3_submitGovernanceProposal(...)`
- 其余方法可先通过 `call()` 访问，再逐步补 typed wrapper

### 4.5 GraphQL 域（最小）
- `query(query_str: []const u8, variables: anytype) -> GraphQLResponse(anytype)`
- 必须支持拉取含 `CheckpointProof{ blsSignature, blsSignerBitmap }` 字段的查询

## 5. 数据模型（Wire Types）

### 5.1 `CheckpointProofWire`
字段需与 RPC/GraphQL 对齐：
- `sequence: u64`
- `object_id: [32]u8`
- `state_root: [32]u8`
- `proof_bytes: []const u8`（80 bytes，domain + state_root + seq_be + object_id）
- `signatures: []const u8`（Ed25519 多签 list）
- `bls_signature: [96]u8`
- `bls_signer_bitmap: []const u8`

### 5.2 `SubmitResult`
- `status: enum { accepted, duplicate, rejected }`
- `rejection_reason: ?enum { invalid_signature, invalid_nonce, malformed, rate_limited, unknown }`
- `http_status: u16`
- `duplicate: bool`
- `raw_body: []const u8`（可选保留）

### 5.3 错误模型（SDK 错误）

#### 5.3.1 `ErrorKind`
- `env_connection_refused`
- `env_timeout`
- `env_ephemeral_port`
- `env_connection_reset`
- `transport_other`
- `protocol_decode`
- `protocol_invalid_response`
- `rpc_error`（带 code/message）
- `application_rejected`（带 reason）

#### 5.3.2 错误结构
- `SdkError{ kind: ErrorKind, message: []const u8, endpoint: Endpoint, attempt: u8, http_status?: u16, rpc_code?: i64 }`

## 6. Checkpoint Proof 校验规范

### 6.1 被签消息
- **必须使用**：`proof_bytes`（80 字节，由 domain `"ZKNOT3CP"` + `state_root` + `sequence_be` + `object_id` 拼接）
- SDK 校验流程：
  1. 重新构造 expected `proof_bytes` 并与返回值逐字节比对
  2. 校验 bitmap 与 validator 集合大小一致性（超长截断、空集合拒绝）
  3. stake-weighted quorum：\(2/3 + 1\)
  4. BLS 聚合验签：对选中公钥聚合后，对 `proof_bytes` 进行 verify

### 6.2 validator 公钥来源
- SDK 接口接受 `[]ValidatorInfo`：
  - `ed25519_pk: [32]u8`
  - `voting_power: u64`
  - `bls_pk: ?[48]u8`（若链上已有）
- 若链上暂未提供 `bls_pk`，允许与当前实现一致：从 `ed25519_pk` 派生 BLS material（或由上层显式传入）

### 6.3 失败模式
- proof_bytes 不一致：`application_rejected/protocol_invalid_response`
- bitmap 不满足 quorum：`application_rejected`
- BLS verify 失败：`application_rejected`

## 7. Tx 提交与幂等/nonce 规范

### 7.1 Tx body 规范（当前）
- `sender_hex(64) + pubkey_hex(64) + signature_hex(128)` 可选追加 `:nonce`

### 7.2 幂等语义
- 服务端返回 `duplicate=true` 表示 **不重复入池**；SDK 应映射为 `SubmitResult.status=duplicate`

### 7.3 nonce 语义
- 若服务端返回 “Invalid transaction nonce”，SDK 映射为 `rejection_reason=invalid_nonce`
- SDK 可提供 `NonceStrategy`：
  - `explicit(nonce)`
  - `auto_local_window`（仅客户端窗口预校验，不保证链上最终一致）

## 8. 可靠性：超时、重试、限流、连接复用

### 8.1 默认超时
- connect: 1s
- request total: 5s
- 允许 per-call override

### 8.2 重试策略
- 仅对 `env_*`/`transport_other` 做重试（默认 2 次）
- 对 `application_rejected` 不重试（除非调用方显式要求）
- 退避：指数退避 + jitter，上限 2s

### 8.3 连接复用
- P0 可以不实现 HTTP keep-alive（简化），但必须保证资源释放
- P1 引入连接池以提升吞吐并降低 TIME_WAIT 压力

### 8.4 并发限制
- SDK 内部 semaphore，防止调用方误用造成自 DoS

## 9. 可观测性

### 9.1 Hook
- `on_request_start(meta)`
- `on_request_end(meta, result)`
- `meta` 最少包含：endpoint、path/method、attempt、latency_ms、error_kind

### 9.2 结构化日志
- 若注入 logger，建议输出 JSON 行（与 `structured=true` 部署一致）

## 10. 兼容性与版本策略

### 10.1 SDK 版本
- SDK 遵循 SemVer：
  - **MAJOR**：breaking API
  - **MINOR**：新增 typed 方法/字段（向后兼容）
  - **PATCH**：bugfix

### 10.2 与节点版本/能力对齐
- SDK 不强绑定节点版本号，但提供：
  - `capabilities.probe()`：探测 method/field 是否存在
  - 若字段缺失则给出明确错误：`protocol_invalid_response`

## 11. 安全要求
- 不在日志中默认打印私钥/seed
- 提供 `Redaction` 选项对 tx body / signature 输出脱敏
- 默认禁用无限重试

## 12. 测试与验收

### 12.1 单元测试（P0）
- wire 编码/解码
- 错误分类（字符串 -> ErrorKind）
- BLS proof 校验正反用例（bitmap quorum、篡改 proof_bytes、篡改签名）

### 12.2 集成测试（P0）
在 devnet/docker 环境：
- `/tx`：accepted/duplicate/invalid_signature/invalid_nonce
- `knot3_getCheckpointProof`：`bls_signature` + `bls_signer_bitmap` 可被 SDK 验过

### 12.3 门禁
- `tools/testnet_release_gate.sh`/`tools/mainnet_release_gate.sh` 的阻塞项必须通过

## 13. 示例（Docs 示例要求）
SDK 必须提供可复制示例（最少 3 个）：
1. health + submitTx
2. getCheckpointProof + verifyProof
3. JSON-RPC 通用 call + typed wrapper

## 14. 交付物
- `docs/dev/sdk_spec.md`（本文档）
- Zig SDK 源码（`src/sdk/*` 或 `src/app/ClientSDK.zig` 规范化拆分）
- 单元/集成测试
- 最小示例程序（`tools/sdk_examples/*` 或 `examples/*`）
