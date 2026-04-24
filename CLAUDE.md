# CLAUDE.md - zknot3 Development Context

## Project Overview

**zknot3** is a Zig re-implementation of the Knot3 blockchain, guided by the "三源合恰" (物象性三源) philosophical framework.

**Current Status**: Production-ready implementation with all core components complete and tested.

## Architecture

### Three-Source Framework (三源合恰)

```
形         →  Spatial topology, computational state  →  storage/, network/, consensus/
性         →  Intrinsic attributes, relation contracts →  move_vm/, access/, crypto/
数         →  Quantitative measures, ordinal evolution →  Epoch, Stake, Metrics
```

### Directory Structure

```
src/
├── app/                    # Application layer
│   ├── Node.zig           # Main node bootstrap and lifecycle
│   ├── Config.zig          # Configuration management
│   └── Indexer.zig         # Object/event indexing
├── core/                   # Core types
│   └── core.zig           # ObjectID, Address, Types
├── form/                   # Form layer (storage, network, consensus)
│   ├── storage/
│   │   ├── Checkpoint.zig  # State checkpointing with BLS
│   │   ├── ObjectStore.zig # Object persistence
│   │   ├── LSMTree.zig     # Log-structured merge tree
│   │   └── WAL.zig         # Write-ahead log
│   ├── network/
│   │   ├── QUIC.zig        # QUIC-style transport
│   │   ├── Kademlia.zig    # K-bucket peer routing
│   │   ├── P2P.zig         # P2P networking
│   │   ├── HTTPServer.zig   # HTTP + JSON-RPC API
│   │   └── Noise.zig       # Encryption
│   └── consensus/
│       ├── Mysticeti.zig    # DAG-based BFT consensus
│       └── Quorum.zig       # Quorum calculations
├── property/               # Property layer (Move VM, crypto)
│   ├── move_vm/
│   │   ├── Interpreter.zig # Bytecode execution
│   │   ├── Gas.zig         # Gas metering
│   │   ├── Resource.zig     # Linear type tracking
│   │   └── Bytecode.zig    # Verification
│   └── crypto/
│       └── Signature.zig   # Ed25519 signatures
├── metric/                 # Metric layer
│   ├── Epoch.zig           # Epoch management
│   ├── Stake.zig           # Stake pool
│   └── EpochConsensusBridge.zig
└── pipeline/              # Pipeline layer
    ├── Ingress.zig        # Transaction submission
    ├── Executor.zig        # Transaction execution
    └── Egress.zig         # Certificate aggregation
```

## Build Commands

```bash
# Development build
zig build -Doptimize=Debug

# Production build
zig build -Doptimize=ReleaseSafe

# Run tests
zig build test

# All 25 tests pass with full coverage
```

## Key Implementation Details

### Crash Recovery

1. **WAL (Write-Ahead Log)**
   - All mutations logged before applying to memtable
   - `LSMTree.recover()` replays uncommitted transactions
   - CRC32 checksums verify integrity

2. **Checkpoint**
   - `Checkpoint.verify()` validates state root
   - Previous digest chain verification
   - 2/3+ quorum BLS signature validation

3. **Recovery Flow**
   ```
   Node.start()
   └─> Node.recoverFromDisk()
         ├─> ObjectStore.recover()
         │     └─> LSMTree.recover()
         │           └─> WAL.replay()
         └─> Load checkpoint history
   ```

### Consensus (Mysticeti)

- DAG-based BFT with 3-round implicit commit
- Leader-free proposal mechanism
- Quorum-based voting with stake weighting
- Vote aggregation via `Egress.aggregate()`

### Move VM Safety

- **Linear Types**: Compile-time resource tracking
- **Overflow Protection**: `@addWithOverflow`, `@subWithOverflow`, etc.
- **Gas Metering**: Budget enforcement per transaction
- **Deterministic Execution**: Same inputs → same outputs

### Network

- **QUIC-style transport** over TCP
- **Kademlia** for peer discovery (256 buckets, k=20)
- **JSON-RPC** API at `POST /rpc`
- Health endpoint at `GET /health`

## Testing

### Test Suite (25 tests)

| File | Tests | Purpose |
|------|-------|---------|
| e2e_test.zig | 7 | End-to-end pipeline tests |
| Node.zig | 5 | Node lifecycle tests |
| Checkpoint.zig | 3 | Checkpoint verification |
| ObjectStore.zig | 2 | Object CRUD |
| LSMTree.zig | 5 | Storage + WAL recovery |
| QUIC.zig | 4 | Network transport |
| HTTPServer.zig | 4 | HTTP API |

### Running Tests

```bash
# All tests
zig build test

# Specific test
zig build test -- "WAL replay"
```

## Deployment

### Docker

```bash
docker build -t zknot3:latest -f deploy/docker/Dockerfile .
docker run -d zknot3:latest --config /etc/zknot3/config.toml
```

### Kubernetes

```bash
kubectl apply -f deploy/kubernetes/validator.yaml
```

Configuration is in `deploy/config/production.toml`.


## Production Stability Notes (Updated 2025-04)

### Known Issues Already Fixed

**13-Hour Freeze**: The node previously froze after ~13 hours because P2P socket I/O had no timeouts. Half-open TCP connections would block `writeAll()` indefinitely.
- Socket timeouts are now enforced (`SO_RCVTIMEO` / `SO_SNDTIMEO` = 100ms) — set **before** handshake so a stalled peer cannot freeze the accept loop
- HTTP connections have 5-second read/write timeouts
- Event loop limits P2P message batch size to 10 per peer
- Handshake failure no longer leaks sockets: `errdefer` closes the raw stream when `PeerConnection.init` or `performHandshake` fails
- Outbound `dial()` now respects `max_connections` and cleans up on failure

**Double-Free in P2P**: `PeerConnection.deinit()` used to `destroy(self)`, but `P2PServer` also destroyed the same pointer — a textbook double-free.
- `PeerConnection.deinit()` now only closes the stream
- `QUICPeerConnection.deinit()` no longer self-destructs
- Memory ownership is strictly: `P2PServer` creates → `P2PServer` destroys

**QUIC Peer Type Confusion / Wrong-Size Free**: `handleQUICConnection` used `@ptrCast` to store `*QUICPeerConnection` in the TCP `peers` map, causing `removePeer` to free with the wrong size.
- Added a separate `quic_peers` map; all peer operations iterate both maps
- `QUICConnection.setTCPConnection` now sets 100ms socket timeouts
- `QUICTransport.closeConnection` now calls `deinit()` instead of just `close()`, fixing stream/receive_buffer leaks

**Consensus Loop Blocking**: A single vote could trigger a large batch of block executions inside `processPeerMessages()`, freezing the main loop.
- `ConsensusIntegration` uses deferred commit: `onVoteReceived` / `checkAndPropose` set `should_commit = true`
- The main loop calls `ci.maybeCommit()` **after** `processPeerMessages()`, so heavy commit work never blocks P2P recv

**HTTP Layer Robustness**
- `HTTPServer.handleConnection` now enforces `max_concurrent_http_connections` (returns 503 when exceeded)
- Requests with `Content-Length` larger than the 4096-byte stack buffer are now read into a heap-allocated buffer so the full body is available
- `extractBody` returns `null` when the body is shorter than `Content-Length`, preventing silent truncation of large POSTs

**Dashboard Panic / Leaks**: Integer underflow in round arithmetic and missing `ArrayList.deinit()` calls caused panics and memory growth.

### Operational Checklist

Before declaring a deploy ready:
1. `zig build test` passes (25 tests)
2. Docker image builds cleanly: `docker build -t zknot3:latest -f deploy/docker/Dockerfile .`
3. All validators and fullnode start with **0 restarts**
4. Consensus rounds advance on all validators
5. Soak monitor shows no `double free`, no `gpa` errors, no `WouldBlock` loops
6. `POST /tx` returns `{"success":true}`

### Quick Diagnostics

```bash
# Check for double-free across all nodes
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  docker logs $c 2>&1 | grep -ci "double free"
done

# Check container restarts
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  docker inspect --format='{{.RestartCount}}' $c
done

# Run soak test (default 24h, pass hours as arg)
./tools/soak_monitor.sh 1
```

## Important Patterns

### Recoverable State

When modifying storage code, always:
1. Log to WAL before modifying memtable
2. Flush memtable to SSTable when full
3. Include checkpoint verification in `Node.recoverFromDisk()`

### Checkpoint Commitment Consistency

`Checkpoint.digest()`, `serialize()`, and `signingCommitment()` must all bind the **same** data scope. Any change to `serialize()` must be mirrored in `digest()` so that chain-linking (`verify()`) and signature verification agree on the canonical commitment. Rule: `digest()` should hash the full `serialize()` output.

### WAL Recovery for M4 State

Any mutable M4 state (stake, governance, epoch) must:
1. Append a WAL record **before** or **immediately after** the in-memory mutation
2. Provide both `appendXxxWal()` (write) and `replayWalExtension()` handler (read)
3. Update `LSMTree.recoverWithOptions` switch if adding a new `WalRecordType`
4. Update `Node.replayMainnetM4Wal` switch to route the new record type

### M4 State Snapshot

For fast recovery (avoiding replaying thousands of individual WAL records):
- Implement `serializeStateSnapshot()` that dumps all in-memory M4 state to a binary blob
- Implement `deserializeStateSnapshot(blob)` that replaces all in-memory state from the blob
- Call `appendStateSnapshotWal()` during graceful shutdown (see `Node.deinit()`)
- The snapshot WAL record is replayed like any other record in `replayWalExtension()`

### Error Handling

- Use `try` for operations that can fail
- Return meaningful errors from `NodeError`
- All errors should be caught and logged

### Thread Safety

- Node operations are single-threaded by default
- Parallel execution planned for future (via Zig's async)
- Lock objects when accessed from multiple contexts

## Common Tasks

### Adding a New Storage Type

1. Implement `init()`, `deinit()`, `get()`, `put()`, `delete()`
2. Add WAL logging in `put()` and `delete()`
3. Add recover method if needed
4. Add tests in the same file

### Adding a New RPC Method

1. Add method name to `HTTPServer.handleConnection()`
2. Implement handler function
3. Return `JSONRPCResponse.success()` or `JSONRPCResponse.newError()`
4. Add test

### Adding a Consensus Message

1. Add message type to `Mysticeti.zig`
2. Implement `serialize()` and `deserialize()`
3. Add to `Node.receiveVote()` handling
4. Add test

## Configuration

See `deploy/config/production.toml` for production settings.

Key settings:
- `consensus.validator_enabled`: Enable validator mode
- `storage.data_dir`: Data directory
- `network.p2p_enabled`: Enable P2P networking
- `vm.max_gas_budget`: Maximum gas per transaction
