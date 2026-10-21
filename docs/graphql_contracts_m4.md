# zknot3 M4 GraphQL Contracts (Executable Interfaces)

M4 calls go through `GraphQL -> Node -> MainnetExtensionHooks`.

Stake and governance mutations enter the M4 state machine. Checkpoint proof returns a payload a light client can check.

## Schema Surface

### Query

#### `knot3_getCheckpointProof(sequence: Int!, objectId: ID!): CheckpointProof`

- Both arguments are required. A missing value, bad hex, or bad `sequence` fails, same as `M4RpcParams.parseCheckpointProofFromPlainArgs`.
  - `sequence`: checkpoint sequence, integer `>= 0`
  - `objectId`: object id, 32 bytes as 64 hex digits, optional `0x` / `0X` prefix
- `CheckpointProof`
  - `sequence: Int`
  - `stateRoot: String`
  - `proof: String`
  - `signatures: String`

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

### Mutation

#### `knot3_submitStakeOperation(validator: ID!, delegator: ID!, amount: Int!, action: String!, metadata: String!): StakeOperationReceipt`

- All arguments are required. `metadata` may be `""`. `amount` must be `> 0`. `action` must be one of the enum values or parsing fails.
  - `validator`: 32-byte address (64 hex, `0x` allowed)
  - `delegator`: 32-byte address (64 hex, `0x` allowed)
  - `amount`: `> 0`
  - `action`: `stake|unstake|reward|slash`
  - `metadata`: text, `""` allowed
- `StakeOperationReceipt`
  - `status: String` (currently always `"accepted"`)
  - `operationId: Int` (monotonic id)

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

- `proposer`: 32-byte address (64 hex)
- `title`: non-empty
- `description`: non-empty
- `kind`: `parameter_change|chain_upgrade|treasury_action`
- `activationEpoch`: optional. Omit the field to match JSON-RPC `activation_epoch`.
- `GovernanceProposalReceipt`
  - `status: String` (currently always `"accepted"`)
  - `proposalId: Int` (monotonic id)

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

## Read queries

Root resolvers read the node or the indexer. Nested fields are taken from that object. A type field queried on its own (`balance`, `status`) is `null`.

### `knot3_getCheckpoint(id: Int): Checkpoint`

- Omitted `id` uses the node's latest checkpoint sequence. A given `id` uses that sequence.
- `sequence` is that number. `digest` is the stored 64-hex digest, or `null` if none is stored.

### `knot3_getObject(id: ID): Knot3Object`

- `id` is 32 bytes of hex. A stored object returns `id` and `version`.
- No node, or no such object: the fields are `null`.

### `knot3_getTransactionBlock(digest: ID): Knot3Transaction`

- `digest` is 32 bytes of hex.
- A receipt returns `digest`, `status`, `gasUsed`, and `sender`. No receipt: the fields are `null`.

### `knot3_queryEvents(query: String): String`

- `query` is an optional event-type filter.
- The result is JSON text with the same shape as JSON-RPC `knot3_queryEvents`: `{"data":[...],"hasNextPage":false}`. No events: `"[]"`.

A nested selection keeps only the named fields. `{ knot3_getCheckpoint(id: 1) { sequence } }` returns an object with `sequence` only.

## Code

- Schema and resolvers: `src/app/GraphQL.zig`
- Node M4 API: `src/app/Node.zig`
- Mainnet hooks: `src/app/MainnetExtensionHooks.zig`
- JSON-RPC contract: `docs/rpc_contracts_m4.md`

## Compatibility

- Field names stay aligned with `knot3_` RPC names (`objectId` is camelCase). GraphQL `activationEpoch` maps to `activation_epoch`.
- `proof` and `signatures` are hex-encoded payloads (Ed25519 signer list plus quorum). See `docs/rpc_contracts_m4.md` and `LightClient.verifyCheckpointProofQuorum`.
- A parse failure returns `error.InvalidParams`. An HTTP gateway that bridges to JSON-RPC should map that to `-32602`.
- `knot3_creditGas` and `knot3_getGasBalance` are JSON-RPC only (`docs/rpc_contracts_m4.md`). GraphQL checkpoint, object, receipt, and event queries call the same node or indexer functions as RPC. Nested fields are projected from the parent object. They are not fixed `0x0`, `1000000`, or `Success`.
