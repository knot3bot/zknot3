# zknot3 Production Operations Guide

> Operational runbook for running zknot3 validators and fullnodes in production.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Deployment](#deployment)
3. [Health Checks](#health-checks)
4. [Known Issues & Fixes](#known-issues--fixes)
5. [Troubleshooting](#troubleshooting)
6. [Monitoring](#monitoring)

---

## Quick Start

```bash
# Build
zig build -Doptimize=ReleaseSafe

# Run local devnet (4 validators + 1 fullnode)
cd deploy/docker
cp .env.example .env
# edit .env and set ZKNOT3_ADMIN_TOKEN to a real value
docker compose up -d

# Verify
./tools/soak_monitor.sh 0.1  # 6-minute smoke test
```

### 管理员写接口鉴权（重要）

为避免误把“写类接口”暴露到公网，节点现在具备两层保护：

- **默认只允许 RPC 绑定到 loopback**（`127.0.0.1` / `localhost`）
- 当你把 `network.bind_address` 设为非 loopback（例如 `0.0.0.0`）时，必须同时设置 **`network.admin_token`**，否则节点会拒绝启动

写类接口包括：

- `POST /tx`
- `POST /rpc` 且 method 为 `knot3_submitStakeOperation` / `knot3_submitGovernanceProposal`

客户端需要带 header：

```bash
curl -sS \
  -H "X-Zknot3-Admin-Token: change-me-dev-token" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"knot3_submitStakeOperation","params":{}}' \
  http://127.0.0.1:9003/rpc
```

---

## Deployment

### Docker Compose (Recommended)

```bash
docker build -t zknot3:latest -f deploy/docker/Dockerfile .
cd deploy/docker
docker compose up -d
```

Services exposed:
| Node | RPC Port | P2P Port |
|------|----------|----------|
| validator-1 | 9003 | 8083 / 9133 |
| validator-2 | 9013 | 8093 / 9143 |
| validator-3 | 9023 | 8103 / 9153 |
| validator-4 | 9033 | 8113 / 9163 |
| fullnode | 9043 | 8123 / 9173 |

### Kubernetes

```bash
kubectl apply -f deploy/kubernetes/validator.yaml
```

---

## Health Checks

### HTTP Endpoints

- **Health**: `GET http://localhost:9003/health` → `{"healthy":true}`
- **Consensus Status**: `GET http://localhost:9003/api/consensus/status`
- **Submit TX**: `POST http://localhost:9003/tx`（写类接口，需要 `X-Zknot3-Admin-Token`）

### Container Health

```bash
# All containers must be "running"
docker ps --filter "name=zknot3"

# Zero restarts is mandatory
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  echo "$c: $(docker inspect --format='{{.RestartCount}}' $c) restarts"
done
```

### Log Checks

```bash
# Critical: no double-free errors
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  count=$(docker logs $c 2>&1 | grep -ci "double free")
  echo "$c double-free count: $count"
done

# Critical: no GPA (GeneralPurposeAllocator) errors
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  count=$(docker logs $c 2>&1 | grep -ci "error(gpa)")
  echo "$c gpa errors: $count"
done
```

---

## Known Issues & Fixes

### Issue: 13-Hour Node Freeze (FIXED)

**Symptoms**: Node stops producing blocks after ~13 hours. CPU drops to near-zero. Docker container stays "running" but consensus halts.

**Root Cause**: `P2PServer.broadcast()` called `stream.writeAll()` on TCP sockets with no timeout. A half-open connection (peer crashed, network partition, etc.) would block indefinitely, freezing the single-threaded event loop. Additionally, handshake performed before timeout setup meant a malicious peer could stall during handshake forever.

**Fixes Applied**:
- `P2PServer.zig`: `SO_RCVTIMEO` and `SO_SNDTIMEO` (100ms) are now set **before** `performHandshake` on both inbound and outbound connections
- `P2PServer.zig`: Handshake failure now triggers `errdefer` that closes the raw socket and frees the `PeerConnection`
- `P2PServer.zig`: Outbound `dial()` now checks `max_connections` before opening a socket
- `HTTPServer.zig`: Added 5-second read/write timeouts on HTTP connections
- `ConsensusIntegration.zig`: Limited `processPeerMessages()` to 10 messages per peer per loop iteration
- `P2PServer.zig`: Fixed iterator invalidation in `broadcast()` — failed peers are collected and removed after iteration
- `P2PServer.zig`: Fixed FD leak by closing the stream in `PeerConnection.deinit()`
- Increased bootstrap retry interval from 5s to 60s to reduce connection storms

### Issue: Double-Free Memory Corruption (FIXED)

**Symptoms**: Logs show `error(gpa): Double free detected`. Container may restart or enter undefined behavior.

**Root Cause**: `PeerConnection.deinit()` called `self.allocator.destroy(self)`. However, both `P2PServer.deinit()` and `P2PServer.removePeer()` also called `allocator.destroy()` on the same pointer. This is a textbook double-free.

**Fix Applied**:
- `PeerConnection.deinit()` now only closes `self.conn.stream`
- `QUICPeerConnection.deinit()` no longer self-destructs
- Memory ownership rule: `P2PServer` creates the `PeerConnection`, so `P2PServer` (and only `P2PServer`) destroys it

### Issue: QUIC Peer Type Confusion / Wrong-Size Free (FIXED)

**Symptoms**: Potential memory corruption or crash when QUIC peers disconnect.

**Root Cause**: `handleQUICConnection` stored `*QUICPeerConnection` in the TCP `peers` map via `@ptrCast`. `removePeer` then freed the QUIC pointer using `PeerConnection` size.

**Fix Applied**:
- Added `quic_peers: AutoArrayHashMapUnmanaged([32]u8, *QUICPeerConnection)` as a separate map
- `removePeer`, `broadcast`, `sendToPeer`, `peerCount`, `getPeerIDs`, `isPeerConnectedByAddress` all operate on both maps
- `deinit` destroys QUIC peers via `quic_conn.deinit()` + `allocator.destroy(peer)`
- `QUICTransport.closeConnection` now calls `conn.deinit()` (which frees streams and receive_buffer) instead of just `conn.close()`

### Issue: Consensus Main-Loop Blocking (FIXED)

**Symptoms**: Intermittent latency spikes in consensus rounds; main loop appears to "hang" for tens of milliseconds under load.

**Root Cause**: `onVoteReceived` and `checkAndPropose` synchronously called `tryCommit()`, which can execute a batch of pending blocks through the Move VM inside the P2P message handler.

**Fix Applied**:
- `ConsensusIntegration` now defers commit: `onVoteReceived` / `checkAndPropose` set `should_commit = true`
- The main loop calls `ci.maybeCommit()` after `processPeerMessages()`, ensuring heavy commit work never blocks peer message recv

### Issue: HTTP Concurrent Connection / Request Truncation (FIXED)

**Symptoms**: Large POST requests (e.g., `/tx` with big payload) could be silently truncated because `handleConnection` only read into a 4096-byte stack buffer. No limit on concurrent HTTP connections.

**Fix Applied**:
- `HTTPServer` now tracks `active_connections` and returns HTTP 503 when `max_concurrent_http_connections` is exceeded
- `Content-Length` is parsed up-front; if the total request exceeds 4096 bytes, a heap-allocated buffer is used and the remainder is read with `streamReadAll`
- `extractBody` now returns `null` when the available data is shorter than `Content-Length`, preventing silent truncation

### Issue: Dashboard Integer Underflow + Memory Leaks (FIXED)

**Symptoms**: Occasional panics in `Dashboard.zig` with `integer overflow` or `underflow`. Slow memory growth over time.

**Fixes Applied**:
- `Dashboard.zig`: Replaced `(42 - block.round.value) * 2` with `now + 84 - block.round.value * 2` to avoid underflow when round > 42
- `Dashboard.zig`: Added missing `ArrayList.deinit()` calls in `handleBlocks()` and `handleTransactions()`
- `Node.zig`: Added `block.deinit()` in `receiveBlock()` early-return path when block already exists

### Issue: Move VM / Executor Robustness — Memory Leaks & Boundary Errors (FIXED)

**Symptoms**: Potential memory leaks when resource validation fails after successful VM execution. Bytecode verifier could mis-parse `ld_const` with zero length. Interpreter `vec_borrow` with negative index triggers safety panic. `vec_pack` with huge count allows memory exhaustion.

**Fixes Applied**:
- `Executor.zig`: `validate()` / `checkLeaks()` failure paths now free `result.output_objects` and `result.events` before returning `.resource_error`
- `Node.zig`: `commitBlock()` now has `defer` to release `executeBlockTransactions` results (both per-result `deinit` and array `free`)
- `Bytecode.zig`: Rejects empty bytecode; rejects `ld_const` with length=0; validates `call` payload boundaries; validates branch targets are within instruction count
- `Interpreter.zig`: `vec_pack` limited to 4096 elements to prevent DoS via huge allocation
- `Interpreter.zig`: `vec_borrow` checks `index.data.int < 0` before `@intCast` to avoid safety panic
- Added 4 BytecodeVerifier regression tests (empty bytecode, ld_const zero-length, truncated call, invalid branch target)

### Issue: Storage WAL Integrity — Checkpoint Commitment Mismatch & Recovery Gaps (FIXED)

**Symptoms**: `Checkpoint.digest()` and `serialize()` bind different data ranges, creating a security gap where chain-linking and signature verification commit to different scopes. `CheckpointSequence` resets to 0 on every restart. Governance votes are lost after node restart because they are never written to WAL.

**Fixes Applied**:
- `Checkpoint.zig`: `digest()` now hashes the full `serialize()` output (same scope as `signingCommitment()`), closing the commitment mismatch
- `Checkpoint.zig`: Added `CheckpointSequence.save()` / `load()` to persist sequence counter to `{data_dir}/checkpoints/sequence.bin`
- `Node.zig`: `init()` loads checkpoint sequence from disk; `deinit()` saves it; `tryCommitBlocks` / `tryCommitBlocksBatch` advance and save the sequence on every quorum block
- `WAL.zig`: Added `.m4_governance_vote = 17` record type
- `MainnetExtensionHooks.zig`: `voteOnProposal()` now appends a WAL record after each vote; `replayWalExtension()` replays it via `injectReplayedGovernanceVote()`
- `LSMTree.zig`: Updated recovery switch to ignore `.m4_governance_vote` (M4 records must not interleave into LSM WAL)
- `MainnetExtensionHooks.zig`: Implemented `serializeStateSnapshot()` / `deserializeStateSnapshot()` — full M4 state (stake ops, proposals, votes, validator stake, delegations, evidence, epoch, validator set hash) serialized to `.m4_state_snapshot` WAL record
- `Node.zig`: `deinit()` triggers `appendStateSnapshotWal()` before shutdown for fast recovery
- `MainnetExtensionHooks.zig`: `replayWalExtension()` now handles `.m4_state_snapshot` by calling `deserializeStateSnapshot()` instead of returning `UnsupportedWalReplayOp`
- Added regression tests: `Checkpoint digest binds object_changes`, `CheckpointSequence save/load roundtrip`, `governance vote WAL roundtrip`, `M4 state snapshot roundtrip`

---

## Troubleshooting

### Consensus rounds are stuck at 0

1. Check if all validators can reach each other on P2P ports (8083)
2. Check logs for `ConnectionRefused` — bootstrap may be dialing before the target listener is ready
3. Verify `vote_quorum` in config is ≤ number of validators

### High restart count

1. Check logs for panics or `error(gpa)` messages
2. Run `./tools/soak_monitor.sh 0.1` to reproduce
3. If `Double free detected`, investigate `P2PServer` peer lifecycle

### Slow memory growth

1. Check for missing `defer allocator.free(...)` or `defer arr.deinit()` in recent changes
2. Check `Node.pending_blocks` and `Node.committed_blocks` — `committed_blocks` are pruned at `max_committed_blocks`; `pending_blocks` are pruned at `max_pending_blocks` (both configured in `Config.ConsensusConfig`)
3. Check `ExecutionResult.events` and `output_objects` — callers must call `ExecutionResult.deinit(allocator)` to release owned memory
4. Check `P2PServer.peers` for leaked `PeerConnection` objects when peers disconnect

### `WouldBlock` spam in logs

This is expected behavior after the timeout fix. A `WouldBlock` from `stream.read()` simply means no data arrived within the 100ms timeout. The event loop continues. **Only** worry if it is paired with actual peer disconnections or consensus halts.

---

## Monitoring

### Soak Test Monitor

```bash
# Run continuous health monitoring (default 24h)
./tools/soak_monitor.sh

# Custom duration, e.g., 2 hours
./tools/soak_monitor.sh 2
```

What it checks every 30 seconds:
- All containers are `running`
- HTTP `/health` responds on all nodes
- Consensus `current_round` is advancing on validators
- Container restart counts are zero
- A test transaction submits successfully every ~5 minutes

### Key Metrics to Watch

| Metric | Good | Bad |
|--------|------|-----|
| Container restarts | 0 | > 0 |
| `double free` in logs | 0 | > 0 |
| `error(gpa)` in logs | 0 | > 0 |
| Consensus round | Increasing | Stuck |
| TX submit | `{"success":true}` | Repeated failures |

---

## Recovery Procedures

### Node restart / crash recovery

1. `Node.recoverFromDisk()` replays both `ObjectStore` WAL and M4 extension WAL
2. M4 state (stake, governance, epoch, validator set hash) is restored from `m4_wal`
3. After recovery, call `Node.advanceEpoch()` to sync `stake_pool` → `quorum` and execute approved proposals

## File Ownership for Critical Fixes

| Issue | Primary File | Pattern |
|-------|--------------|---------|
| 13h freeze | `src/form/network/P2PServer.zig` | Always set socket timeouts on peer connections |
| Double-free | `src/form/network/P2PServer.zig` | `deinit()` must not `destroy(self)` if owner also destroys |
| UAF in consensus | `src/form/consensus/ConsensusIntegration.zig` | Re-validate peer pointers after any callback that might mutate the peer map |
| Block leak | `src/app/Node.zig` | Early returns must still free locally-allocated objects |
| Dashboard panic | `src/app/ui/Dashboard.zig` | Avoid subtraction that can underflow; use `now + const - value` |
| Memory leak | `src/pipeline/Executor.zig` | Call `ExecutionResult.deinit(allocator)` after consuming results |
| Pending block leak | `src/app/Node.zig` | `receiveBlock` prunes oldest pending blocks when over `max_pending_blocks` |

---

## Secrets / Keys（严禁提交到仓库）

`deploy/docker/configs/validator-*.json` 现在**不再**包含：

- `authority.signing_key`
- `authority.bls_signing_seed`

原因：它们属于高敏感材料，提交到仓库即视为泄漏。

在生产上应通过外部注入（例如环境变量/密钥管理器/挂载文件）提供这些值；在 devnet 可用固定种子，但也应放在本机/CI 的私密配置中，而不是 git 跟踪文件中。
