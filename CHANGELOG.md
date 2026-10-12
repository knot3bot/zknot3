# Changelog

All notable changes to zknot3 are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Devnet validators never connected** — three independent defects stacked, so
  every node reported `peers: 0` and the "4-validator devnet" was really four
  isolated nodes each proposing and voting for itself:
  1. `docker-compose-testnet.yml` (the stack `wan_emulation_gate.sh` runs) pinned
     no static IPs, while `configs/validator-*.json` hard-code
     `172.20.0.2-.5` as bootstrap peers, so nodes dialled the wrong containers.
  2. `performHandshake` blocks on three socket round-trips and ran inline in the
     accept/dial path. Both peers blocked inside their own main loop waiting on
     the other, so every handshake timed out with `HandshakeFailed`. Inbound and
     outbound handshakes now run on worker threads, with the shared nonce
     tracker behind a mutex and workers joined in `stop()`.
  3. `processPeerMessages` treated *any* read error other than `WouldBlock` as a
     dead peer. Zig collapses unrecognised errnos into `error.Unexpected`, so
     healthy peers were evicted on the first transient socket hiccup. Reads are
     now classified: transient errors retry, only `EndOfStream` / `BrokenPipe` /
     `ConnectionResetByPeer` evict.

  Validators now hold 2-3 peers each with consensus rounds and committed-block
  counts advancing in step, and the WAN gate's commit progression roughly
  doubled (0 -> 16 -> 29 -> 44 before, 0 -> 29 -> 54 -> 87 after).

- **Commit quorum counted ballots, not stake** — `BlockCommit.hasQuorum` was
  `block.votes.count() >= vote_quorum`, so four validators holding 1% each
  cleared the same bar as one holding 90% and the BFT safety argument did not
  hold on the commit path. It now tallies stake against `QuorumConfig`
  (`> 2/3 of total`), keeping `vote_quorum` as a floor on distinct voters so a
  single holder cannot commit alone on an under-populated stake table. A missing
  stake table fails closed. `CommitCertificate.quorum_stake` reports the stake
  that actually gathered instead of `votes.count() * 1000`.

- **A vote's weight was whatever the sender claimed** — `Vote.stake` travels on
  the wire and is covered by the vote signature, which proves only *who* sent it,
  not *how much* they are worth. Any peer could claim an arbitrary weight and
  manufacture a quorum alone. `receiveVote` now discards the wire value and
  substitutes the local stake pool's weight for that validator, dropping votes
  from validators it has no stake for.

- **Validator identity did not match the stake table** — `known_validators[i]
  .public_key_hex` keys `stake_pool`, but the consensus identity was derived
  from `authority.signing_key`, so a node's own id was never in the pool: its
  weight read as zero and it refused to vote. `Node.selfValidatorId` now takes
  the identity from the genesis table (falling back to the derived key when no
  genesis table is configured), and the devnet configs list the public keys
  their signing keys actually derive. The fullnode's `bootstrap_peers` also used
  Docker service names, which `P2PServer.dial` cannot resolve — it resolves IP
  literals only — so the fullnode had never dialled anyone; it now uses the
  pinned addresses.

  Devnet validators now hold 2-3 peers each with committed-block counts tracking
  each other, and the fullnode holds 4.

- **WAN gate could not detect a disconnected cluster** — every phase asserted on
  a single validator's `blocks_committed_total`, which kept advancing even when
  `peers` was 0 (each node proposed and voted for itself). The gate therefore
  stayed green through all three peer-liveness defects above. It now asserts the
  cluster is actually meshed: a `wait_peers` precondition after the health check,
  a re-check after WAN impairment (latency/loss must not sever the mesh), a
  majority-only check during the partition, and a reconnect check after healing
  so catch-up is proven over a real network rather than in isolation.
  Verified by reverting the fixes: the gate now fails at phase 1.5 with
  `validator-1=0`.

- **`ConsensusIntegration.zig` had no tests at all** — it was never referenced
  from `tests_unit.zig`, so 600+ lines of peer-liveness logic went unverified.
  It is now compiled into the unit suite and carries a regression test for the
  error classification above.

- **Toolchain pins moved to Zig 0.17.0 stable** — CI (`.github/workflows/ci.yml`,
  3 jobs) and `deploy/docker/Dockerfile` still pulled the `0.17.0-dev.2307+392b17125`
  nightly from `ziglang.org/builds/`. Both now use stable `0.17.0` from
  `ziglang.org/download/`, matching `minimum_zig_version` in `build.zig.zon` and
  the installer. No source changes were required: the codebase already compiled
  and tested clean on stable. Verified locally — 271/271 unit, 385/385
  integration, 5/5 formal proofs, 10/10 TS SDK, plus `zig fmt --check` and
  `-Doptimize=ReleaseSafe`.

## [0.18.0] — 2026-10-05

Zig 0.17.0 stable adaptation release. The project now compiles, tests, and
ships against the stable 0.17.0 toolchain (`minimum_zig_version = "0.17.0"`).

### Added

- **Zig 0.17.0 stable support** — `build.zig.zon` gains
  `minimum_zig_version = "0.17.0"` and the package version is bumped to
  0.18.0. Full suite: 385 tests green under `zig build test-integration`,
  `zig build -Doptimize=ReleaseFast` verified.
- **AI framework native primitives** (`knot3::ai_framework`) — Move-VM native
  functions for on-chain AI inference, with inference event observability.
- **One-line installer script** (`deploy/install.sh`) for node deployment.
- **P2P abuse-defense Prometheus counters** — `zknot3_p2p_rate_limited_drops_total`,
  `zknot3_p2p_banned_peers_total`, `zknot3_p2p_io_fallback_total`, merged with
  the existing tri-source (物丰/象大/性自在) metrics on `/metrics`.
- **WAN emulation CI gate** — multi-container devnet validated under
  netem latency/loss/partition/healing, decoupled from the docker job.
- **Portable HTTP server fallback** — serves via direct posix socket I/O when
  io_uring is denied (containers with restricted seccomp), selected at `start()`.

### Changed

- Merged 33 upstream commits (docs accuracy audit, WAN gate, Docker host-arch
  build, HTTP portability, CI fixes) with local work. Two merge conflicts
  resolved: `HTTPServer.zig` metrics endpoint (unified P2P + tri-source
  counters) and `tools/formal/export.zig` (Coq/Lean quorum threshold restored
  to `(2 * total / 3) + 1`, matching the runtime `Stake.quorumThreshold` and
  the machine-checked `specs/consensus.v` `3 * q > 2 * total` semantics).
- `AGENTS.md` toolchain note updated: 0.17.0 stable replaces the nightly pin.

### Fixed

- `tools/formal/export.zig` quorum threshold formula (`(2 * total / 3) + 1`,
  was `2 * total / 3`) so generated Coq/Lean matches the verified spec.
- Double-free in `Response`/`Egress`/`Ingress` teardown paths and TxnPool
  `min_gas_price` default (1000) test alignment; integration suites
  (`indexing_end_to_end`, `epoch_advance`) isolated per-test with temp data
  dirs and `sequence = 0` first-transaction semantics.

[0.18.0]: https://github.com/knot3bot/zknot3/releases/tag/v0.18.0
