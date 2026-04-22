# zknot3 Mainnet Go-Live Gate

This document defines hard release gates for mainnet deployment.
If any item fails, release is blocked.

## 1) Validator Safety Gates

- Production profile must not run validator role by accident.
  - `validator_enabled` default in production configs must remain `false`.
- If validator role is enabled by operator override, all of the following are required:
  - `authority.signing_key` is configured (not null).
  - `authority.stake` is greater than `0`.
  - `network.p2p_enabled` is `true`.

## 2) Observability Gates

- Production configs must set `logging.structured = true`.
- Node startup logs must include machine-parsable key/value events for:
  - consensus events
  - P2P abuse events
  - checkpoint/proof events

## 3) Crash-Safety Gates

- Known hot-path `unreachable` sites must be removed or guarded by explicit error checks.
- `zig build` and `zig build test` must pass in CI before release tag.

## 4) Protocol Readiness Gates

- M4 interfaces must not return reserved placeholders in production mode:
  - `knot3_submitStakeOperation`
  - `knot3_submitGovernanceProposal`
  - `knot3_getCheckpointProof`
- Checkpoint proof path must produce verifiable artifacts (not `reserved` strings).
- JSON-RPC **M4 v2**: `params` is a **single JSON object** per method; invalid payloads return **`-32602` `invalid_params`**. GraphQL uses the same strict parsing (`M4RpcParams` + plain args); see `docs/rpc_contracts_m4.md` / `docs/graphql_contracts_m4.md`.

## 5) Operational Gates

- Runbook and incident template must be updated:
  - `docs/testnet_runbook.md`
  - `docs/testnet_incident_template.md`
- Cutover checklist must be completed and archived:
  - `docs/mainnet_cutover_checklist.md`

## 6) Gate Execution

- Execute: `tools/mainnet_release_gate.sh`
- Any non-zero exit code blocks release.
