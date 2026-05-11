# System Architecture Overview

## Node Internal Data Flow

```
                   ┌──────────────────────────┐
                   │       HTTP / JSON-RPC     │
                   │   POST /tx  POST /rpc     │
                   │   GET /health  /metrics   │
                   └─────────────┬────────────┘
                                 │
                   ┌─────────────▼────────────┐
                   │        Ingress           │
                   │   Verify sig, gas, nonce │
                   │   Fast Path: owner check │
                   │   Mempool: dedup + queue │
                   └──────┬──────────┬────────┘
                          │          │
               Fast Path  │          │  Consensus Path
               (single    │          │  (shared objects)
                owner)    │          │
                          │    ┌─────▼──────────┐
                          │    │   Consensus     │
                          │    │ Mysticeti DAG   │
                          │    │ Propose→Vote→   │
                          │    │ Commit          │
                          │    └─────┬──────────┘
                          │          │
                   ┌──────▼──────────▼──────────┐
                   │        Executor            │
                   │   Block-STM: parallel opt. │
                   │   Move VM: bytecode interp │
                   │   Resource tracker: linear │
                   │   Gas meter: budget check  │
                   └─────────────┬─────────────┘
                                 │
                   ┌─────────────▼────────────┐
                   │       ObjectStore        │
                   │   LSM-Tree + WAL         │
                   │   MemTable → SSTable     │
                   │   Bloom filter + CRC32   │
                   └─────────────┬────────────┘
                                 │
                   ┌─────────────▼────────────┐
                   │       Checkpoint         │
                   │   Merkle state root      │
                   │   BLS/Ed25519 sig agg    │
                   │   Chain continuity       │
                   └──────────────────────────┘

                   ┌──────────────────────────┐
                   │           P2P            │
                   │   Kademlia discovery     │
                   │   Noise XX encryption    │
                   │   Gossip broadcast       │
                   │   QUIC/TCP transport     │
                   └──────────────────────────┘
```

## Module Map

```
src/
├── app/                    Application layer
│   ├── Node.zig           Main node bootstrap and lifecycle
│   ├── Config.zig          Configuration management + validation
│   ├── Indexer.zig         Object/event indexing
│   ├── Log.zig             Structured logging
│   └── BlockExecution.zig  Batch transaction execution
│
├── core/                   Core types
│   ├── core.zig           ObjectID, Address, Types
│   └── crypto/Bls.zig     BLS12-381 via blst
│
├── form/                   Form layer (形 — spatial topology)
│   ├── storage/
│   │   ├── LSMTree.zig     Log-structured merge tree
│   │   ├── WAL.zig         Write-ahead log with CRC32
│   │   ├── ObjectStore.zig Object persistence + dynamic fields
│   │   ├── Checkpoint.zig  State checkpoint with BLS
│   │   ├── IpfsStore.zig   IPFS CID tracking
│   │   └── IOUring.zig     Linux io_uring async I/O
│   ├── network/
│   │   ├── P2P.zig         Peer-to-peer networking
│   │   ├── P2PServer.zig   TCP/QUIC connection management
│   │   ├── Kademlia.zig    K-bucket peer routing
│   │   ├── Noise.zig       Noise XX handshake + encryption
│   │   ├── QUIC.zig        QUIC-style transport over TCP
│   │   ├── HTTPServer.zig  Sync HTTP + JSON-RPC
│   │   ├── AsyncHTTPServer.zig io_uring HTTP (Linux)
│   │   └── Yamux.zig       Stream multiplexing
│   └── consensus/
│       ├── Mysticeti.zig   DAG-based BFT consensus
│       ├── Quorum.zig      Stake-weighted quorum
│       └── Validator.zig   Validator set management
│
├── property/               Property layer (性 — intrinsic attributes)
│   ├── move_vm/
│   │   ├── Interpreter.zig Bytecode execution
│   │   ├── Bytecode.zig    Verification + stack type check
│   │   ├── Gas.zig         Gas metering (monotonic)
│   │   ├── Resource.zig    Linear type tracking
│   │   └── values.zig      Value system + Container
│   └── crypto/
│       ├── Signature.zig   Ed25519 signatures
│       └── ZkLogin.zig     OAuth → on-chain identity
│
├── metric/                 Metric layer (数 — quantitative measures)
│   ├── Epoch.zig           Epoch management
│   ├── Stake.zig           Stake pool + delegation
│   ├── RuntimeMetrics.zig  Prometheus metrics collector
│   └── EpochConsensusBridge.zig Epoch→consensus bridge
│
└── pipeline/               Pipeline layer
    ├── Ingress.zig         Transaction submission + verify
    ├── Executor.zig        Block-STM parallel execution
    ├── Egress.zig          Certificate aggregation
    └── DependencyGraph.zig Conflict detection graph
```

## Key Design Decisions

| Decision | Rationale | ADR |
|----------|-----------|-----|
| Move VM over EVM | Resource safety (linear types) | ADR-001 |
| DAG-BFT over HotStuff | Leaderless = higher throughput | ADR-002 |
| Zig over Rust/Go | No GC, explicit memory, C ABI | ADR-003 |
| LSM-Tree + WAL | Append-heavy state DB (proven) | — |
| Block-STM execution | Optimistic parallelism (Sui model) | — |
| Noise XX handshake | Modern 3-message key exchange | — |
| BLS aggregate signatures | O(1) certificate size at scale | — |
