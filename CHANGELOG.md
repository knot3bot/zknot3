# Changelog

All notable changes to zknot3 are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
