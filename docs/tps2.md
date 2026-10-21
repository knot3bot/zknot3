# TPS work

Numbers below are estimates, not a benchmark run.

```
case                              TPS            latency
Fast path, single owner, serial   5,000-10,000   <10ms
2-chain, 4 validators             1,000-2,000    ~1s
2-chain, 20 validators            200-500        ~2s
3-chain, 100 validators           50-150         ~4s
PTB batch                         2,000-5,000    <50ms
```

## In the tree

| # | Change | Claimed gain | State |
|---|--------|--------------|-------|
| 1 | Fast path (single owner skips consensus) | 5-20x | done |
| 2 | Parallel execution (DependencyGraph + threads) | 2-4x | done |
| 3 | 2-chain / 3-chain selection | 1.3x | done |
| 4 | DAG pruning | holds under load | done |
| 5 | O(1) block lookup (`block_index`) | removes an O(n²) scan | done |
| 6 | PTB dispatch | 1.5x | done |

## Phase 1

1. Parallel fast path (2-3x). `executeFastPath` calls `executePTB` one transaction at a time. The target is DependencyGraph plus `std.Thread`. Not done.
2. WAL group commit (1.3-1.5x). Each record calls `fsync`. The target is one `fsync` per batch. Not done.
3. BLS vote aggregation (2-3x on the vote path). Votes are Ed25519, 64 bytes each. The target is one aggregated certificate. Not done.

## Phase 2

4. Batch signature checks in `Ingress.verify` (1.5-2x).
5. LRU for hot objects in `ObjectStore.get` (1.5-2x). Ownership has to stay reference-counted.
6. Execute transactions when the block arrives, before commit (1.3-1.5x).

## Phase 3

7. Block-STM: execute, detect conflicts, retry (5-10x).
8. One Mysticeti instance per shard (10-50x).
9. JIT for hot contracts (3-5x).

## Where time goes

```
path                         now                  next
Ingress.submit()             O(1)                 done
Ingress.verify()             O(n) signatures      batch
Executor.executeFastPath()   serial               parallel
Executor.executeOrdered()    thread per batch     pool
ObjectStore.get()            LSM lookup           cache
ObjectStore.put()            sync compaction      async
WAL.append()                 fsync per record     batch
Mysticeti.receiveVote()      Ed25519 O(n)         BLS O(1)
Egress.aggregate()           overflow-checked     done
Mysticeti.tryCommit()        O(1)                 done
```

Last edited 2026-05-11. The "356 tests" and "~9.2/10" notes from that day are not a current score.
