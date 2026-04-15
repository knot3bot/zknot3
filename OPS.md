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
docker compose up -d

# Verify
./tools/soak_monitor.sh 0.1  # 6-minute smoke test
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
| validator-1 | 9000 | 8080/8081 |
| validator-2 | 9010 | 8090/8091 |
| validator-3 | 9020 | 8100/8101 |
| validator-4 | 9030 | 8110/8111 |
| fullnode | 9040 | 8120 |

### Kubernetes

```bash
kubectl apply -f deploy/kubernetes/validator.yaml
```

---

## Health Checks

### HTTP Endpoints

- **Health**: `GET http://localhost:9000/health` → `{"healthy":true}`
- **Consensus Status**: `GET http://localhost:9000/api/consensus/status`
- **Submit TX**: `POST http://localhost:9000/tx` (body: 32-byte raw tx)

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

**Root Cause**: `P2PServer.broadcast()` called `stream.writeAll()` on TCP sockets with no timeout. A half-open connection (peer crashed, network partition, etc.) would block indefinitely, freezing the single-threaded event loop.

**Fixes Applied**:
- `P2PServer.zig`: Added `SO_RCVTIMEO` and `SO_SNDTIMEO` (100ms) via `setsockopt` on all peer sockets
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

### Issue: Dashboard Integer Underflow + Memory Leaks (FIXED)

**Symptoms**: Occasional panics in `Dashboard.zig` with `integer overflow` or `underflow`. Slow memory growth over time.

**Fixes Applied**:
- `Dashboard.zig`: Replaced `(42 - block.round.value) * 2` with `now + 84 - block.round.value * 2` to avoid underflow when round > 42
- `Dashboard.zig`: Added missing `ArrayList.deinit()` calls in `handleBlocks()` and `handleTransactions()`
- `Node.zig`: Added `block.deinit()` in `receiveBlock()` early-return path when block already exists

---

## Troubleshooting

### Consensus rounds are stuck at 0

1. Check if all validators can reach each other on P2P ports (8080-8081)
2. Check logs for `ConnectionRefused` — bootstrap may be dialing before the target listener is ready
3. Verify `vote_quorum` in config is ≤ number of validators

### High restart count

1. Check logs for panics or `error(gpa)` messages
2. Run `./tools/soak_monitor.sh 0.1` to reproduce
3. If `Double free detected`, investigate `P2PServer` peer lifecycle

### Slow memory growth

1. Check for missing `defer allocator.free(...)` or `defer arr.deinit()` in recent changes
2. Check `Node.pending_blocks` and `Node.committed_blocks` — blocks are never pruned in current implementation
3. Check `P2PServer.peers` for leaked `PeerConnection` objects when peers disconnect

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

## File Ownership for Critical Fixes

| Issue | Primary File | Pattern |
|-------|--------------|---------|
| 13h freeze | `src/form/network/P2PServer.zig` | Always set socket timeouts on peer connections |
| Double-free | `src/form/network/P2PServer.zig` | `deinit()` must not `destroy(self)` if owner also destroys |
| UAF in consensus | `src/form/consensus/ConsensusIntegration.zig` | Re-validate peer pointers after any callback that might mutate the peer map |
| Block leak | `src/app/Node.zig` | Early returns must still free locally-allocated objects |
| Dashboard panic | `src/app/ui/Dashboard.zig` | Avoid subtraction that can underflow; use `now + const - value` |
