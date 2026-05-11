# Network Protocol Specification

## Overview

zknot3 uses a dual-layer networking stack:
- **P2P layer**: Kademlia DHT for peer discovery + gossip for message propagation
- **Transport layer**: QUIC-style framing over TCP (future: real QUIC/UDP)

## Message Types

| Type | Code | Direction | Purpose |
|------|------|-----------|---------|
| `BlockProposal` | 0x11 | Broadcast | New consensus block |
| `Vote` | 0x12 | Broadcast | Validator vote on block |
| `Transaction` | 0x10 | Broadcast | New transaction gossip |
| `BlockRequest` | 0x20 | Request/Reply | Sync missing blocks |
| `BlockResponse` | 0x21 | Request/Reply | Block data response |

## Peer Lifecycle

```
DISCOVERED → CONNECTING → HANDSHAKE → ACTIVE → (BANNED | DISCONNECTED)
```

### 1. Discovery (Kademlia)
- 256 buckets, k=20 peers per bucket
- XOR distance metric on peer_id
- Periodic bucket refresh (every 60s)
- Bootstrap from configured seed peers

### 2. Handshake (Noise XX)
- 3-message XX handshake pattern
- HKDF key derivation for send/receive CipherStates
- Handshake nonce tracked to prevent replay
- Failed handshake → peer not added to routing table

### 3. Active State
- `isActive()` checks last-seen timestamp (30s timeout)
- Connection pool reuses TCP connections per peer
- Per-peer rate limiting: `p2p_max_messages_per_peer_per_second`
- Per-message-type rate limiting: `p2p_max_messages_per_type_per_second`

### 4. Ban/Disconnect
- Rate limit violations → automatic ban
- Ban duration: `p2p_peer_ban_seconds` (default 86,400 = 24h)
- `refreshRoutingTable()` removes stale peers (>1h no activity)

## Gossip Protocol

```
Message received:
  1. Check LRU cache (dedup by message digest)
  2. If seen → drop
  3. Process message locally
  4. Forward to K random peers (K = fanout, default 3)
  5. Add digest to LRU cache
```

- Fanout: K=3 (configurable)
- LRU cache: 10,000 entries per message type
- Compression: messages may be compressed before send

## Rate Limiting

```
Global limits:
  max_messages_per_tick: 256       (per event-loop tick)
  max_accepts_per_tick: 16         (new connections per tick)

Per-peer limits:
  p2p_max_messages_per_peer_per_second: 100
  p2p_max_messages_per_type_per_second: 50

Ban threshold: 3x rate limit violations → ban for p2p_peer_ban_seconds
```

## Transport

### Current: QUIC-style TCP Framing
```
Frame: [type:u8][stream_id:u32][length:u32][payload:bytes]
```
Uses TCP with application-level multiplexing. NOT real QUIC/UDP.

### Future: QUIC/UDP Migration Path
- `QUIC.zig` already has stream abstraction
- Noise session per QUIC connection
- 0-RTT handshake for re-connections
- Migration blocked on: QUIC library integration (msquic or quiche)

## HTTP / JSON-RPC

- `POST /tx` — Submit transaction (requires auth for non-loopback)
- `POST /rpc` — JSON-RPC 2.0 endpoint
- `GET /health` — Health check (always returns 200)
- `GET /ready` — Readiness check (requires consensus_round > 0)
- `GET /metrics` — Prometheus metrics endpoint

### Auth Model
- `network.admin_token` must be set for non-loopback bind
- Write endpoints (`/tx`, write RPC methods) require `X-Zknot3-Admin-Token` header
- Read endpoints are public
