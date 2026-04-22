# Async Gap Assessment (Zig 0.16.0)

## Current State

- **HTTP path**: Linux uses `AsyncHTTPServer` with `std.os.linux.IoUring` and a dedicated thread (`src/form/network/AsyncHTTPServer.zig`).
- **P2P path**: still synchronous read/write + timeout polling in main loop (`src/form/network/P2PServer.zig`, `src/form/consensus/ConsensusIntegration.zig`, `src/main.zig`).
- **Storage path**: `IOUring.zig` currently selects backend labels, but `read/write` still call `std.posix.pread/pwrite` directly, not true submission/completion ring flow (`src/form/storage/IOUring.zig`).
- **Language-level async**: repository does not use Zig `async/await` syntax in core runtime path.

## Risk / Impact

- HTTP can scale better on Linux, but end-to-end throughput is constrained by synchronous P2P + consensus message pump.
- Main loop performs periodic polling and sleeps; this introduces latency jitter under load.
- Storage backend naming suggests async behavior, but current implementation is effectively synchronous I/O.

## Priority Recommendations

1. **P0 - P2P eventing**  
   Move P2P socket progress from polling loops to event-driven readiness (or dedicated worker model) to reduce false disconnects and CPU wakeups.

2. **P1 - Storage backend parity**  
   Implement real io_uring submit/complete for storage reads/writes (Linux), keep thread-pool fallback for non-Linux.

3. **P2 - Unified backpressure**  
   Add shared backpressure strategy across HTTP ingress, txn pool, and P2P broadcast to avoid burst amplification.

4. **P3 - Optional Zig async exploration**  
   Evaluate targeted use of Zig async style only where it simplifies state machines; do not force global rewrite.
