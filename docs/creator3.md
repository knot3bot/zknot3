# Creator3

Design note for human and agent co-creation on top of the node. The tables name mechanisms that already exist in the node. They are not a separate product surface.

```
person writes  ->  agent edits  ->  object stored, signed, versioned
```

| Source | What it holds |
|--------|----------------|
| Form | object bytes, P2P, consensus |
| Property | owner, provenance, royalty, license |
| Metric | version, contribution weight, time |

## Provenance

| Record | Where it comes from |
|--------|---------------------|
| Time | checkpoint sequence and block timestamp |
| Author | `Transaction.sender`, Ed25519 |
| Steps | PTB command list |
| Durability | DAG commit and WAL replay |
| Versions | `ObjectStore` causal version (`version.seq` plus causal bytes) |
| Forks | object-id dependency edges |

A person signs with Ed25519. An agent can authenticate with zkLogin (OAuth). Both end up as `Transaction.sender`. The checkpoint records the time.

## Ownership

- `Owned`: one author.
- `Shared`: several authors. Decisions use a BLS aggregate signature (one 96-byte signature).
- `Immutable`: frozen.

| Mechanism | What the node already has |
|-----------|---------------------------|
| Shared object | `Ownership.Shared(context)` |
| Multi-author signature | BLS aggregate |
| Split of value | PTB `SplitCoins` |
| Sponsor pays gas | `payer` distinct from `sender` |
| Add or remove a collaborator | dynamic fields |
| Agent without its own gas | gas-station allowlist |

A sale split is a PTB `SplitCoins` list, for example creator 70%, co-author 20%, platform 10%.

## Agents

| Step | Mechanism |
|------|-----------|
| Agent is the sender, sponsor is the payer | `payer != sender` |
| Simulate before submit | `dryRunTransaction` exists on the node. The RPC method still returns an error. |
| Several commands in one transaction | PTB |
| Verifiable random seed | VRF |
| Index what was created | `Event.emit` |
| Web login for an agent | zkLogin (OAuth/OIDC) |

`dryRunTransaction` in this table is the node function, not `knot3_dryRunTransactionBlock`. That RPC method is not wired.

## License object

Sketch, not a shipped type:

```
Creation {
    id: ObjectID,
    data: bytes,
    license: {
        type: CC0 | CC-BY | CC-BY-SA | MIT | CUSTOM | AllRightsReserved,
        terms: text,
        royalty_bps: 500,  // 5%
        expiration: 0,     // 0 = none
    },
    creator: Address,
    created_at: Epoch,
    version: Version,
    parent_ids: [ObjectID],
}
```

## Queries that are not in the schema

The GraphQL below is a sketch. The live schema is `docs/graphql_contracts_m4.md`. These fields are not resolvers today.

```graphql
query CreationTree($root_id: ObjectID!) {
  creation(id: $root_id) {
    id, creator, created_at, version
    parents { id, creator }
    children { id, creator }
    collaborations { id, role }
    license { type, royalty_bps }
  }
}

query CreatorPortfolio($creator: Address!) {
  creations(creator: $creator, orderBy: created_at_DESC) {
    id, version, license, created_at
    childCount
    forkCount
  }
}
```

## Object life

`Owned` at creation, `Shared` while people edit, fork via parent ids, `Immutable` when frozen. Later objects can still cite it.

Counts worth keeping: stored objects and bytes, owner and license mix, royalty moved, version count, fork count, collaborator count, citation count.

## Status as of this note

| Phase | Work | State in the original note |
|-------|------|----------------------------|
| 1 | signature, timestamp, versions, multi-step PTB | marked done |
| 2 | shared ownership, BLS, sponsor, gas station | marked done |
| 3 | dry-run, VRF, events, gas station | marked done |
| 4 | zkLogin for agents | marked current |
| 5 | license type and automatic royalty | marked current |
| 6 | dependency-graph API and the queries above | marked current |

Phases 4-6 are designs. Do not treat the GraphQL in this file as a live API.
