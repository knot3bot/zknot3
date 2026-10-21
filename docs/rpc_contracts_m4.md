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

### `knot3_creditGas`

Admin **write** method. Requires header `X-Zknot3-Admin-Token` when `network.admin_token` is set (same gate as other write RPCs / `POST /tx`).

- Params:
  - `address` (hex string, 32 bytes)
  - `amount` (u64; credits the in-memory gas ledger)
- Result:
```json
{"balance":1000}
```

**Semantics (honest scope):** updates the executor’s address→balance map used when `vm.enforce_gas_payment` is true. This is **not** full gas-coin objects. Ledger is in-memory today; durable via per-op `m4_gas_balance` WAL records, plus periodic absolute `m4_gas_snapshot` appends (`storage.gas_snapshot_interval_secs`, default 300s; `0` disables) and a clean-shutdown snapshot — the snapshots shrink crash-recovery replay of long balance tails without replacing per-op durability. Charging on execute is gated by `vm.enforce_gas_payment` (default off). Overflow on credit returns JSON-RPC **`-32603`**.

### `knot3_getHardenedCheckpoint`

Read method (no admin token). `params` may be omitted. An object may carry `sequence` (non-negative integer).

Without `sequence`, returns this node's **local hardened tip** plus the recent ring. With `sequence`, returns only that stored digest when the ring or the `{checkpoint_dir}/hardened.digests` archive still has it. It is **not** a BFT certificate. Light clients still check the digest against a trusted hash.

- Result, no `sequence`:
```json
{"sequence":9,"digest":"<64 lowercase hex digits>","history":[{"sequence":9,"digest":"<64 lowercase hex digits>"}]}
```

`history` is the stored ring, oldest first, at most 8 entries. The tip is included when the ring does not already hold that sequence.

- Result, `{"sequence":1}` when that digest is still stored:
```json
{"sequence":1,"digest":"<64 lowercase hex digits>"}
```

- No hardened marker, a marker with no stored digest, or a `sequence` this node did not keep — JSON-RPC **`-32011`** `knot3_hardened_checkpoint_unavailable`, message `hardened checkpoint unavailable`.
- `params` that is not an object, or a `sequence` that is not a non-negative integer — **`-32602`**.

### `knot3_getGasBalance`

Read method (no admin token).

- Params:
  - `address` (hex string, 32 bytes)
- Result:
```json
{"balance":1000}
```

Unknown addresses return `balance: 0`. Same in-memory / optional `m4_gas_balance` WAL ledger as `knot3_creditGas`; not gas-coin objects.

## Error codes

- **`-32602` `invalid_params`**: missing `params`, not an object, missing required field, bad hex length, `amount == 0` (stake only), unknown `action` / `kind`, empty `title` / `description`, or invalid `sequence`.
- **`-32603` `internal error`**: e.g. `knot3_creditGas` u64 overflow on credit.
- **`-32011` `knot3_hardened_checkpoint_unavailable`**: `knot3_getHardenedCheckpoint` has no stored hardened digest. `-32004` stays `knot3_move_verification_error`.

## Compatibility Notes

- Added to:
  - RPC router (`src/form/network/RPC.zig`)
  - async HTTP `/rpc` dispatcher (`src/form/network/AsyncHTTPServer.zig`)
  - sync HTTP `/rpc` dispatcher (`src/form/network/HTTPServer.zig`)
  - SDK method list (`src/app/ClientSDK.zig`)
  - Shared parser: `src/form/network/M4RpcParams.zig`
- GraphQL bridge (`src/app/GraphQL.zig`) covers stake / governance / checkpoint-proof with `M4RpcParams` plain-arg parsing. **Gas ledger RPCs (`knot3_creditGas` / `knot3_getGasBalance`) are JSON-RPC only** — not in the GraphQL schema yet.
