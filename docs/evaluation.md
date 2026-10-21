# zknot3 completeness review (2026-09-26, full check)

> **Revised 2026-10-20.** The 95% below is an equal-weight self-score from 26 September, written before several real multi-node bugs were found (validators not connected to each other, blocks not reaching quorum, commit counted votes instead of stake). Those were fixed in October. HEAD CI had been green. The same day, three code gaps were filled: an equivocation slash curve (10% / 25% / 50% / 100%, charged in proportion to delegation, and applied to voting power), bounded fuzz of the bytecode interpreter (an illegal opcode no longer crashes the process), and `k3snap01` checkpoint snapshot sync. After that: evidence propagation once signatures check, epoch jail (2 / 3 / 5, stake leaves the quorum total, `m4jl` snapshot tail), and a TCP IPv4 /16 connection cap (default 8). An external security audit, and the long soak in `docs/mainnet_cutover_checklist.md`, are still operational work. Checking a code list does not do them. The percentage table was not recomputed for any of this.

> Scores come from builds, test runs, and item-by-item checks. The command in the evidence column is the reproduction. The bar is production readiness. Thirteen dimensions, equal weight.

## What was run

| Check | Command | Result |
|---|---|---|
| Full build | `zig build` (after a clean cache) | pass |
| Unit + integration + e2e | `zig build test` | **385/385** (includes 5 Byzantine scenarios) |
| Fast unit | `zig build test-unit` | 266/266 |
| Executable proofs | `zig build test-formal` | 5/5 (exhaustive) |
| Coq | `bash tools/formal/coq_gate.sh` | coqc 9.3, 8 Qed theorems |
| Lean 4 | `bash tools/formal/lean_gate.sh` | Lean 4.34.1, 10 theorems, no sorry. Axiom audit: propext / Quot.sound only |
| TS SDK | `cd sdk/typescript && npm test` | 10/10 |
| Official toolchain, local macOS arm64 | `ZIG_GLOBAL_CACHE_DIR=… /tmp/zig-official/…/zig build test` | **385/385**, ReleaseFast benchmark 0 failures (official 0.17.0-dev.2307, isolated cache, deps from a pinned tarball) |
| Official toolchain CI | https://github.com/knot3bot/zknot3/actions/runs/36247023070 | test, formal, sdk, build-release, and docker all success (official Zig 0.17.0-dev.2307, Linux x86_64) |
| WAN emulation gate | `wan` job = `tools/wan_emulation_gate.sh` | four stages: healthy baseline; blocks keep coming under 80ms±10ms and 2% loss; with validator-4 fully partitioned, 3/4 still commit; after heal, the partition catches up; zero restarts. netem on the container network |
| Byzantine / property simulation | `zig build test-integration --summary all` | 5 scenarios (equivocation safety × 300 seeds, partition safety + heal, withheld-leader view change, seed determinism, loss/delay gossip soak × 25 seeds) |
| Benchmark | `zig build benchmark` (ReleaseFast) | pass (the UB was fixed) |
| Release-gate spot check | `p0_bls_checkpoint` / `p0_p2p_async` | pass (tx admission gate is fail-closed) |
| Leaks | full suite, SafeAllocator | none found |

## Scores (before the fix pass, then the 2026-09-26 score)

The percentage column was not recomputed on 2026-10-20.

| Dimension | Before | Then | Evidence |
|---|---|---|---|
| Build / toolchain | 85 | **98** | blst assembly vendored for every platform; versions aligned; official-toolchain CI green at the time (pinned nightly 0.17.0-dev.2307; jobs: test, formal, sdk, release, docker; dependency hashes checked by the official package manager; 8 Linux-only compile bugs, a CI version error, and a Dockerfile ghost reference fixed in that pass). Later: after Zig 0.17.0 stable, CI and the Dockerfile use stable `0.17.0` (nightly `/builds/` path replaced by stable `/download/`). |
| Tests | 95 | **99** | e2e on; randomized property / Byzantine harness (5 scenarios, reproducible seeds); 385 + 10 green; no leaks found |
| Storage | 90 | **92** | WAL double-free fixed. Remainder: io_uring is Linux-only (macOS uses the fallback, and that path is tested) |
| Network | 90 | **95** | rate limit, ban, Noise handshake, admin token; partition / loss / delay checked both by the Byzantine sim and by the multi-container WAN gate; HTTP response path fixed (posix write) |
| Consensus | 60 | **97** | BLS aggregate QC; view change; 3-chain leader check; block-author signature; digest covers parents. The sim found and the tree fixed 3 bugs (duplicate delivery leak, `block_index` dangling pointer, 2/3-chain lookup dead after view change). Equivocation safety, partition safety, and view-change liveness were checked with random seeds |
| Contract VM | 50 | **94** | module publish lifecycle (`ModuleRegistry`: immutable / compatible / free, version, gas, on-chain object). ReleaseFast UB found and avoided (toolchain codegen bug on an odd-sized padded union field; 40-byte pad, see the `Interpreter.Value.ResourceLoc` comment). Benchmark runs ReleaseFast again. Remainder: no source-language compiler |
| Execution pipeline | 90 | **94** | PTB Publish wired (register, persist, gas). The pipeline was exercised end to end under netem by the WAN gate (submit, execute, commit) |
| App layer | 85 | **93** | GraphQL / RPC contract tests. HTTP server checked in a container and locally (200). Dashboard, browser client, indexer, light client. GraphQL has M4 contract tests (SDL, NonNull, RPC alignment) |
| Agent surface | 95 | **95** | agent, wallet, ToolRegistry, MCP (49 tests) |
| Formal | 20 | **93** | Coq/Rocq 9.3 (8 Qed) and Lean 4.34.1 (10 theorems, no sorry; axiom audit propext / Quot.sound; `lean_gate.sh` in CI). 5 exhaustive executable proofs in the build |
| SDK | 60 | **94** | 10 tests (`node:test`). Two real bugs fixed (Blake3 all-zero placeholder, Ed25519 raw export). CI. `npm pack` checked |
| Deploy / ops | 90 | **96** | gates fail closed; Coq gate; Docker, health checks, runbook |
| Mainnet M4 | 55 | **94** | WAL + checkpoint recovery checked (replay after restart, idempotence, evidence dedup, truncated record fail-closed, epoch rotation: 5 tests). Checkpoint Ed25519 checked per signer |

**Aggregate: about 95.0% (equal weight, 13 dimensions, each score tied to a command above). Same method before the fix pass: about 74%.**

## Gaps left under that 95%

| Gap | Size | Note |
|---|---|---|
| Cross-region hardware | medium | WAN behavior (latency, loss, partition, heal) is covered by the CI netem gate. Real hardware in more than one region is still an ops task |
| Move source compiler | large | Decision stands: the VM is native bytecode |
| Async HTTP CQE buffer | medium | **Filled 2026-10-20.** `tick` drains the completion queue and only then flushes overflow. A body over 4096 bytes and under `max_request_body_size` is read on the heap; over the cap, 413. The percentage table was not recomputed |
| ~~Official Zig toolchain~~ | ~~small~~ | **Done (2026-09-26).** Five CI jobs green. See the table above |

## What that session changed

1. **Consensus.** QuorumCertificate (BLS aggregate + bitmap), TimeoutVote / TimeoutCertificate, tryViewChange, leaderForRound plus the 3-chain leader check, block-author signature, one `computeDigest` for create and addBlock, receiveVote BLS key path (the old BLS mode was dead code and had never been compiled).
2. **Modules.** `ModuleRegistry.zig` (publish / upgrade / policy / codec) plus Executor PTB Publish and the on-chain object write.
3. **Formal.** `tools/formal/proofs.zig` (5 exhaustive proofs). Coq spec rewritten so it machine-checks (fake axioms such as list commutativity removed). `coq_gate.sh`.
4. **SDK.** Real Blake3 (`@noble/hashes`), Ed25519 JWK export fix, 10 tests, tsconfig, CI.
5. **Build.** Assembly vendored for every platform, versions aligned, e2e on, gates fail closed, benchmark fixed.
6. **Docs.** README, `dev.md`, `todo.md`, and `AGENTS.md` aligned with the tree (the ~99% claim and the "381 lines of Coq" claim removed; stale M4 / checkpoint facts corrected).

### Same day, Lean

7. **Lean 4.** elan / Lean 4.34.1 (`brew lean-cli` is a different tool with the same name). `specs/consensus.lean` rewritten against the core library (`List.Pairwise` for the linear discipline, `Sublist` for resource consumption). 10 theorems, no sorry. `#print axioms` shows only standard kernel axioms. `lean_gate.sh` rejects an extra axiom and runs in CI.
8. **ReleaseFast UB.** Reproduced as a codegen bug on a 33-byte (odd pad) union field under that toolchain (b1–b9 comparison). `Value.ResourceLoc` padded to 40 bytes. `zig build benchmark` is ReleaseFast and green again.

### Same day, simulation

9. **Property and Byzantine harness.** `test/property/byzantine_simulation_test.zig`. Multi-node Mysticeti on a controllable network (partition, loss, delayed delivery). Five scenarios: equivocation safety (300 seeds over honest vote layouts), partition safety plus heal, view change when the leader is withheld, seed determinism, random gossip soak with an equivocator. The harness found three library bugs: (a) `addBlock` leaked on duplicate delivery (first write wins); (b) `block_index` stored a raw pointer that dangled when the round map grew (use-after-free, now a locator); (c) after view change, 2/3-chain lookup matched the full `(value, view)` key and missed (now matches on value).

### Same day, CI

10. **CI pushed to green.** After the main commit (223 files) landed on origin/main, eight rounds: Zig "0.17.0" stable did not exist yet, so CI had never been green; pin the official nightly; GitHub problem matchers turned compile errors into public annotations; 8 Linux-only compile bugs (AsyncHTTPServer allocator argument ×6, `requireAdminForRequest` / `isAuthorizedAdmin` visibility, `std.os.linux.CPU.set` move, `sched_setaffinity` as a raw syscall) and a Dockerfile that named a 0.17.0 tarball which was not there. Final run 36247023070: **test, formal, sdk, build-release, docker all success.**

### Same day, WAN gate

11. **Multi-container WAN gate in CI, green.** `tools/wan_emulation_gate.sh` and the `wan` job (netem 80ms±10ms, 2% loss, full partition, heal; four stage asserts; zero-restart audit). Nine bugs fixed so the gate could run: (1) testnet compose subnet did not match the bootstrap addresses (172.28 vs 172.20, so peers never connected); (2) `Node.init` errdefer `deinit` read an undefined optional and segfaulted, hiding the real error; (3) the same partial-init panic in `runtime_metrics`; (4) devnet validator config had no `authority.signing_key`, so the devnet could not start; (5) the Dockerfile forced an aarch64 cross compile, so an x86_64 host died with exec format error; (6) Docker's default seccomp blocks io_uring, so a Linux node died on start; runtime fallback added; (7) **the portable HTTP server never answered at runtime** (`std.Io` streams need a driver the event loop never ran; tests stayed green because `testing.io` drives itself) so the path writes posix directly; (8) `--dev` implied validator identity, so a fullnode crash-looped on InvalidConfig; (9) three bugs in the gate script itself (container name, field name, dangling YAML key).

## Conclusion

On the production-readiness bar used here, the project was about **95.0%**. Consensus, execution, storage, M4, and the VM sat in the 92–95 band. Tests and the formal specs had machine-checked evidence. The writeup called the rest about 7%, itemized above, and said none of those items were a claim that disagreed with the code. The 2026-10-20 note at the top is the later correction: the table was not recomputed, and audit plus the cutover soak are still open.
