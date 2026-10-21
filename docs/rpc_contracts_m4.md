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
{"sequence":9,"stateRoot":"<hex32>","proof":"<hex>","signatures":"<hex>","bls_signature":"<hex>","bls_signer_bitmap":"<hex>"}
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

## Dispatch

`POST /rpc` on both `HTTPServer` and `AsyncHTTPServer` calls `RPC.RPCServer.dispatch`. Method names and the admin-write bit live in `builtin_methods` in `src/form/network/RPC.zig`. HTTP only reads the body, checks `X-Zknot3-Admin-Token` for `write: true` methods, and sends the bytes `dispatch` returns.

Write methods today: `knot3_submitStakeOperation`, `knot3_submitGovernanceProposal`, `knot3_creditGas`. A body that is not a JSON object, or that has no string `method`, is treated as a write. An unknown method name is not a write.

JSON-RPC client errors (invalid JSON, missing method, unknown method, invalid params, handler errors) are a JSON-RPC error object with **HTTP 200**. `id` is echoed and escaped. Error `message` strings are escaped (`JsonRpc.formatJsonString`).

## Read methods

These read node or indexer state when `dispatch` is given a node. They are not admin writes. A missing node returns the empty or zero result named under each method, except `knot3_getTransactionBlock` and `knot3_getObject`, which return the errors listed there.

### `knot3_getEpochInfo`

No params. Result:

```json
{"epoch":0,"total_stake":0,"validator_count":0,"quorum_threshold":0,"validators":{"active_validators":{"data":[]}},"initial_epoch_version":0}
```

`epoch`, `total_stake`, `validator_count`, and `quorum_threshold` come from `Node.getEpochInfo()`. `validators.active_validators.data` stays empty.

### `knot3_syncEpochState`

No params. Result: `{"epoch":<epoch_number>,"protocolVersion":1}`.

### `knot3_getLatestCheckpointSequenceNumber`

No params. Result is a JSON number: the node's `checkpoint_sequence`, or `0` when no node is attached.

### `knot3_getCheckpoint`

- Params: omitted, or `{"id": <non-negative integer>}`.
- Result: `{"sequence":<n>,"digest":"<64 lowercase hex>"|null,"timestamp":<unix seconds>}`.
- `id` selects the sequence. Omitted `id` uses the node's latest checkpoint sequence.
- `digest` is the digest stored for that sequence. It is JSON `null` when none is stored. This method does not invent a digest.

### `knot3_getTransactionBlock`

- Params: a hex string, or `{"digest":"<hex>"}`. 64 hex digits, optional `0x`.
- Result: `{"digest":"<hex>","status":"<tag>","gasUsed":<n>,"sender":"<hex>"}` from `Node.getTransactionReceipt`.
- No node: **`-32603`**, message `Node not initialized`.
- Missing or bad digest: **`-32602`**.
- No receipt: **`-32001`**, message `Transaction not found`.

### `knot3_getObject`

- Params: a hex string, or `{"id":"<hex>"}`.
- Result when the object store has that id: `{"object_id":"<hex>","version":<seq>,"type_tag":<n>}`.
- No node, or the id is absent: **`-32001`**, message `Object not found`.
- Bad id: **`-32602`**. Object store unavailable: **`-32603`**, message `Object store unavailable`.

### `knot3_queryEvents` and `knot3_getEvents`

Both names call the indexer. Params may be omitted, a string (event type), or an object:

- `query` or `eventType` (string, optional)
- `digest` (32-byte hex, optional)
- `limit` or `first` (integer 1..100, default 50)
- `cursor` (non-negative integer, optional; exclusive event index)

Result:

```json
{"data":[{"digest":"<hex>","type":"<text>","contents":"<text>","timestamp":9,"eventIndex":0}],"hasNextPage":false}
```

`type` and `contents` are JSON strings. No node or no indexer: `{"data":[],"hasNextPage":false}`.

### `knot3_getOwnedObjects`

- Params: a 32-byte hex string, or `{"owner":"<hex>","query":"<object type>"}`. `query` is an optional type filter.
- Result: `{"data":["<object id hex>"],"hasNextPage":false}` from the indexer.
- No node or no indexer: empty `data`.
- A node with a missing or bad `owner`: **`-32602`**.

### Still empty or unavailable

- `knot3_getCoins` returns `{"data":[]}`. There is no coin index.
- `knot3_getEpochs` returns `{"data":[]}`.
- `knot3_dryRunTransactionBlock` returns **`-32603`**, message `dry run is not available`. It does not return a simulated success.
- `knot3_executeTransactionBlock` returns **`-32603`**, message `Node not initialized`. It does not submit a transaction.

## Error codes

- **`-32602` `invalid_params`**: missing `params`, not an object, missing required field, bad hex length, `amount == 0` (stake only), unknown `action` / `kind`, empty `title` / `description`, or invalid `sequence`.
- **`-32601` `method_not_found`**: the method is not in `builtin_methods` and was not `register`ed on that server.
- **`-32603` `internal error`**: e.g. `knot3_creditGas` u64 overflow on credit, dry-run unavailable, or object store unavailable.
- **`-32001` `knot3_object_not_found`**: `knot3_getObject` or `knot3_getTransactionBlock` has no matching record.
- **`-32011` `knot3_hardened_checkpoint_unavailable`**: `knot3_getHardenedCheckpoint` has no stored hardened digest. `-32004` stays `knot3_move_verification_error`.

## Compatibility Notes

- One method table: `builtin_methods` in `src/form/network/RPC.zig`. Both HTTP servers call `RPCServer.dispatch`. Do not add a second `/rpc` switch in `HTTPServer.zig` or `AsyncHTTPServer.zig`.
- A new **write** method sets `write: true` on that table entry. `RPCServer.bodyRequiresAdmin` is what HTTP auth reads.
- Id and string escaping: `src/form/network/JsonRpc.zig`.
- SDK method list: `src/app/ClientSDK.zig`. Shared M4 parsers: `src/form/network/M4RpcParams.zig`.
- GraphQL (`src/app/GraphQL.zig`) calls the same node hooks for stake, governance, checkpoint proof, checkpoint, object, transaction receipt, and indexer events. **Gas ledger RPCs (`knot3_creditGas` / `knot3_getGasBalance`) are JSON-RPC only.** Nested GraphQL selections are copied from the parent object the root resolver built. See `docs/graphql_contracts_m4.md`.
