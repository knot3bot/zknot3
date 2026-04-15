# zknot3 - Zig Blockchain Reference Implementation

> A production-grade blockchain node implementation in Zig, following the "三源合恰" (物象性三源) philosophical framework.

## Status

**Current Phase**: Production-ready implementation with all core components complete.

## Features

- [x] **Mysticeti Consensus** - DAG-based BFT consensus
- [x] **Move VM** - Safe execution with linear types and overflow protection
- [x] **LSMTree Storage** - Persistent object storage with WAL crash recovery
- [x] **QUIC Transport** - Real network transport over TCP
- [x] **Kademlia P2P** - Peer discovery and routing
- [x] **Epoch Management** - Validator stake tracking and reconfiguration
- [x] **HTTP/JSON-RPC API** - External interface for clients
- [x] **Checkpointing** - Full state checkpoint and recovery

## Quick Start

### Prerequisites

- Zig 0.15+
- rocksdb (for production storage)

### Build

```bash
# Full build
zig build

# Release build for production
zig build -Doptimize=ReleaseSafe

# Run tests
zig build test
```

### Run a Node

```bash
# Default configuration (development mode)
./zig-out/bin/zknot3 --config ./deploy/config/devnet.toml

# Production mode
./zig-out/bin/zknot3 --config ./deploy/config/mainnet.toml --validator
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      三源合恰 (Three Source Integration)   │
├─────────────┬─────────────┬─────────────────────────────────┤
│  形         │ 性           │  数                             │
├─────────────┼─────────────┼─────────────────────────────────┤
│ storage/    │ move_vm/    │  Epoch.zig                      │
│ - LSMTree   │ - Interpreter│  Stake.zig                      │
│ - WAL       │ - Gas       │  EpochConsensusBridge.zig       │
│ - Checkpoint│ - Resources  │  Metrics.zig                    │
├─────────────┼─────────────┼─────────────────────────────────┤
│ network/    │ crypto/     │  pipeline/                      │
│ - QUIC      │ - Signatures│  - Ingress.zig                  │
│ - Kademlia  │ - Hashing   │  - Executor.zig                  │
│ - P2P       │ - Keys      │  - Egress.zig                    │
└─────────────┴─────────────┴─────────────────────────────────┘
```

### Core Components

| Component | File | Description |
|-----------|------|-------------|
| **Node** | `src/app/Node.zig` | Main node bootstrap and lifecycle |
| **Checkpoint** | `src/form/storage/Checkpoint.zig` | State checkpointing with BLS signatures |
| **ObjectStore** | `src/form/storage/ObjectStore.zig` | Persistent object storage |
| **LSMTree** | `src/form/storage/LSMTree.zig` | Log-structured merge tree |
| **WAL** | `src/form/storage/WAL.zig` | Write-ahead log for crash recovery |
| **Mysticeti** | `src/form/consensus/Mysticeti.zig` | DAG-based BFT consensus |
| **MoveVM** | `src/property/move_vm/Interpreter.zig` | Move bytecode execution |
| **Ingress** | `src/pipeline/Ingress.zig` | Transaction submission and verification |
| **Executor** | `src/pipeline/Executor.zig` | Transaction execution |
| **Egress** | `src/pipeline/Egress.zig` | Certificate aggregation |

## Configuration

### Development

```toml
[network]
rpc_port = 9000
p2p_enabled = false

[consensus]
validator_enabled = true
epoch_duration_secs = 86400

[storage]
data_dir = "./data"
cache_size = 1073741824  # 1GB
```

### Production

```toml
[network]
bind_address = "0.0.0.0"
rpc_port = 9000
p2p_enabled = true
p2p_port = 8080
max_connections = 1024

[consensus]
validator_enabled = true
min_validator_stake = 1000000000  # 1 SUI
min_validators = 4
epoch_duration_secs = 86400

[storage]
data_dir = "/var/lib/zknot3"
object_store_path = "objects"
checkpoint_store_path = "checkpoints"
cache_size = 10737418240  # 10GB
enable_compaction = true
compaction_interval_secs = 3600

[vm]
max_gas_budget = 10000000
min_gas_price = 1000
max_bytecode_size = 65536

[authority]
address = "your-validator-address"
port = 8080
signing_key = "your-32-byte-key"
stake = 1000000000000  # 1000 SUI
```

## Production Deployment

### Docker

```bash
# Build image
docker build -t zknot3:latest .

# Run container
docker run -d \
  --name zknot3 \
  -p 9000:9000 \
  -p 8080:8080 \
  -v /var/lib/zknot3:/var/lib/zknot3 \
  zknot3:latest \
  --config /var/lib/zknot3/config.toml
```

### Kubernetes

```bash
# Deploy validator
kubectl apply -f deploy/kubernetes/validator.yaml

# Check status
kubectl get pods -l app=zknot3
kubectl logs -l app=zknot3
```

See [deploy/kubernetes/](deploy/kubernetes/) for full manifests.

## API Reference

### JSON-RPC Endpoints

#### POST /rpc

```json
{
  "jsonrpc": "2.0",
  "method": "sui_getObject",
  "params": {"id": "0x..."},
  "id": 1
}
```

**Supported Methods**:
- `sui_getObject` - Get object by ID
- `sui_getTransaction` - Get transaction receipt
- `sui_submitTransaction` - Submit a transaction
- `sui_getCheckpoint` - Get checkpoint by sequence
- `sui_getEpochInfo` - Get current epoch information

#### GET /health

Returns node health status.

### Response Format

```json
{
  "jsonrpc": "2.0",
  "result": {...},
  "id": 1
}
```

Error response:
```json
{
  "jsonrpc": "2.0",
  "error": {"code": -32600, "message": "Invalid request"},
  "id": 1
}
```

## Testing

```bash
# Run all tests
zig build test

# Run specific test suite
zig build test -- test_name

# Run with coverage
zig build test -fcover
```

### Test Categories

| Suite | Tests | Coverage |
|-------|-------|----------|
| e2e_test.zig | 7 | Full pipeline integration |
| Node.zig | 5 | Node lifecycle |
| Checkpoint.zig | 3 | Checkpoint verification |
| ObjectStore.zig | 2 | Object CRUD |
| LSMTree.zig | 5 | Storage + WAL recovery |
| QUIC.zig | 4 | Network transport |
| HTTPServer.zig | 4 | HTTP API |

## Security

- All transactions require Ed25519 signature verification
- Move VM enforces linear type safety at runtime
- Integer overflow protection on all arithmetic operations
- WAL ensures durability against crashes
- Checkpoint verification includes BLS quorum validation

## Development

### Code Structure

```
src/
├── app/           # Node, Config, Indexer
├── core/          # ObjectID, Address, Types
├── form/          # Storage, Network, Consensus
│   ├── storage/   # LSMTree, WAL, Checkpoint, ObjectStore
│   ├── network/   # QUIC, Kademlia, P2P, HTTP
│   └── consensus/  # Mysticeti, Quorum
├── property/      # Move VM, Crypto
│   └── move_vm/   # Interpreter, Gas, Resources
├── metric/        # Epoch, Stake, Bridge
└── pipeline/      # Ingress, Executor, Egress
```

### Build Commands

```bash
# Development build
zig build -Doptimize=Debug

# Production build with optimizations
zig build -Doptimize=ReleaseFast

# Production build with safety checks
zig build -Doptimize=ReleaseSafe

# Export formal verification specs
zig build -Dexport-formal=true

# Run tri-source metric tests
zig build test -- tri_source.wu_feng    # 物丰: resource efficiency
zig build test -- tri_source.xiang_da   # 象大: knowledge coverage  
zig build test -- tri_source.zi_zai    # 性自在: user satisfaction
```
## Production Stability Fixes (2025-04)

The following critical fixes have been applied to resolve long-running node freezes and memory safety issues:

### Fixed: 13-Hour Node Freeze
- **Root cause**: P2P `writeAll()` blocked indefinitely on half-open TCP connections due to missing socket timeouts.
- **Fixes**:
  - Added `SO_RCVTIMEO` and `SO_SNDTIMEO` (100ms) to all P2P sockets in `P2PServer.zig`
  - Added 5-second read/write timeouts to HTTP connections in `HTTPServer.zig`
  - Limited P2P message processing to 10 messages per peer per event loop iteration to prevent starvation
  - Fixed peer iterator invalidation during broadcast by collecting failed peers before removal
  - Fixed file descriptor leak: `PeerConnection.deinit()` now closes the underlying stream
  - Fixed bootstrap retry storm by increasing interval from 5s to 60s

### Fixed: Double-Free Memory Corruption
- **Root cause**: `PeerConnection.deinit()` called `allocator.destroy(self)`, but callers (`P2PServer.deinit()` and `removePeer()`) also called `destroy()` on the same pointer.
- **Fix**: Removed `self.allocator.destroy(self)` from `PeerConnection.deinit()` and `QUICPeerConnection.deinit()`; destruction is now the sole responsibility of the owner (`P2PServer`).

### Fixed: Additional Memory Leaks & Panics
- `Dashboard.zig`: Fixed integer underflow in `(42 - block.round.value) * 2` and plugged ArrayList leaks
- `Node.zig`: Fixed Block leak in `receiveBlock()` when block already exists
- `ConsensusIntegration.zig`: Fixed use-after-free when re-validating peer pointers across broadcast boundaries

### Verification
- All tests pass: `zig build test`
- Docker containers deploy cleanly with zero restarts
- 24-hour soak test validated: no freezes, no double-frees, consensus advancing, transactions submitting successfully


## License

MIT
