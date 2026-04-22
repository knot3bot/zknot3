# zknot3 M4 RPC Contracts (Executable v2 Payloads)

These methods are executable protocol interfaces. Parameters are strongly typed
**JSON objects** (not positional arrays) and responses include verifiable proof fields.

## v2 migration (breaking)

- **`params` must be a single JSON object** per method. Array-shaped `params` are rejected with JSON-RPC **`invalid_params` (-32602)**.
- **Hex**: 32-byte fields are **64 lowercase or uppercase hex digits**, optional `0x` / `0X` prefix (see `M4RpcParams.parseHex32Str`).
- **`knot3_getCheckpointProof`**: the object id field name is **`objectId`** (camelCase), matching GraphQL.
- **Checkpoint proof**: `proof` and `signatures` are **lowercase hex**. `signatures` wire format is documented in `ClientSDK.zig` / light client (`k3s1` prefix + little-endian count + repeated `(validator_id_32 || ed25519_sig_64)`).

## JSON-RPC Methods

### `knot3_submitStakeOperation`

- Params:
  - `validator` (hex string, 32 bytes)
  - `delegator` (hex string, 32 bytes)
  - `amount` (u64 > 0)
  - `action` (`stake|unstake|reward|slash`)
  - `metadata` (optional string)
- Result:
```json
{"status":"accepted","operationId":1}
```

### `knot3_submitGovernanceProposal`

- Params:
  - `proposer` (hex string, 32 bytes)
  - `title` (string)
  - `description` (string)
  - `kind` (`parameter_change|chain_upgrade|treasury_action`)
  - `activation_epoch` (optional u64)
- Result:
```json
{"status":"accepted","proposalId":1}
```

### `knot3_getCheckpointProof`

- Params:
  - `sequence` (number)
  - `objectId` (hex string)
- Result:
```json
{"sequence":9,"stateRoot":"<hex32>","proof":"<hex>","signatures":"<hex>"}
```

## Error codes

- **`-32602` `invalid_params`**: missing `params`, not an object, missing required field, bad hex length, `amount == 0`, unknown `action` / `kind`, empty `title` / `description`, or invalid `sequence`.

## Compatibility Notes

- Added to:
  - RPC router (`src/form/network/RPC.zig`)
  - async HTTP `/rpc` dispatcher (`src/form/network/AsyncHTTPServer.zig`)
  - sync HTTP `/rpc` dispatcher (`src/form/network/HTTPServer.zig`)
  - SDK method list (`src/app/ClientSDK.zig`)
  - GraphQL bridge layer (`src/app/GraphQL.zig`) — uses `M4RpcParams` plain-arg parsing for strict parity with RPC
  - Shared parser: `src/form/network/M4RpcParams.zig`
