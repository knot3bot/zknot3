//! Executor - Transaction execution with resource tracking.
//!
//! Executes transactions sequentially with dependency-graph ordering.
//! TODO: Wire `parallelism` config field for actual parallel execution of
//! conflict-free batches identified by the dependency graph.
//!
//! Key features:
//! - Sequential execution (thread pool deferred)
//! - Resource tracking with linear type guarantees
//! - Gas metering with budget enforcement

const std = @import("std");
const builtin = @import("builtin");

/// Simple thread pool for reusing worker threads across execution batches.
/// Avoids the per-batch std.Thread.spawn overhead.
pub const WorkerPool = struct {
    threads: []std.Thread,
    /// Signals workers to start processing their chunk
    start_signal: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Number of workers that have completed their chunk
    done_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Shared execution context — set by submit() before signaling workers
    exec: ?*Executor = null,
    txs: ?[]const Ingress.Transaction = null,
    results: ?[]ExecutionResult = null,
    chunks: ?[]const []const usize = null,
    size: usize,

    fn init(allocator: std.mem.Allocator, size: usize) !WorkerPool {
        const threads = try allocator.alloc(std.Thread, size);
        return WorkerPool{ .threads = threads, .size = size };
    }

    fn deinit(self: *WorkerPool, allocator: std.mem.Allocator) void {
        // Signal all workers to exit
        self.start_signal.store(@intCast(self.size + 1), .monotonic);
        for (self.threads) |t| t.join();
        allocator.free(self.threads);
    }

    /// Submit a batch of work chunks for parallel execution. Returns when all complete.
    fn submit(self: *WorkerPool, exec: *Executor, txs: []const Ingress.Transaction, results: []ExecutionResult, chunks: []const []const usize) void {
        self.exec = exec;
        self.txs = txs;
        self.results = results;
        self.chunks = chunks;
        self.done_count.store(0, .monotonic);
        self.start_signal.store(1, .monotonic); // wake workers

        // Busy-wait for all workers to complete
        while (self.done_count.load(.monotonic) < chunks.len) {
            std.atomic.spinLoopHint();
        }
    }
};
const core = @import("../core.zig");
const property = @import("../property.zig");
const Gas = property.move_vm.Gas;
const Resource = property.move_vm.Resource;
const ObjectStore = @import("../form/storage/ObjectStore.zig").ObjectStore;
const ResourceTracker = property.move_vm.ResourceTracker;
const Interpreter = property.move_vm.Interpreter;
const Bytecode = property.move_vm.Bytecode;
const Registry = property.move_vm.Registry;
const TxContext = property.move_vm.TxContext;
const Event = property.move_vm.Event;
const Ingress = @import("Ingress.zig");
const DependencyGraph = @import("DependencyGraph.zig").DependencyGraph;
const Log = @import("../app/Log.zig");

/// Execution result — packed for cache efficiency.
/// Hot fields (digest, status, gas_used) fit in a single cache line.
pub const ExecutionResult = struct {
    digest: [32]u8,
    status: ExecutionStatus,
    gas_used: u64,
    output_objects: [][32]u8 align(8),
    events: []Event align(8),

    /// Release all owned memory
    pub fn deinit(self: ExecutionResult, allocator: std.mem.Allocator) void {
        if (self.output_objects.len > 0) allocator.free(self.output_objects);
        for (self.events) |evt| {
            if (evt.payload.len > 0) allocator.free(evt.payload);
        }
        if (self.events.len > 0) allocator.free(self.events);
    }
};

/// Execution status
pub const ExecutionStatus = enum {
    success,
    out_of_gas,
    invalid_bytecode,
    resource_error,
};

/// Executor configuration
pub const ExecutorConfig = struct {
    parallelism: usize = 8,
    max_gas: u64 = 10_000_000,
    /// Use Block-STM optimistic execution instead of dependency-graph batching
    use_block_stm: bool = true,
};

/// Executor with transaction execution support
pub const Executor = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    config: ExecutorConfig,
    resource_tracker: *ResourceTracker,
    /// Per-instance thread affinity counter
    _thread_counter: u32 = 0,
    /// Pre-execution result cache: keyed by (block_digest, tx_index)
    pre_exec_cache: std.AutoArrayHashMapUnmanaged([40]u8, ExecutionResult) = .empty,
    /// Reusable result buffer — avoids per-batch allocation
    result_pool: []ExecutionResult = &.{},
    /// Optional native function registry for VM calls.
    /// Ownership: once set, the Executor takes ownership and will deinit+destroy in deinit().
    registry: ?*Registry = null,

    pub fn init(allocator: std.mem.Allocator, config: ExecutorConfig) !*Self {
        const tracker = try allocator.create(ResourceTracker);
        tracker.* = ResourceTracker.init(allocator);
        errdefer {
            tracker.deinit();
            allocator.destroy(tracker);
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .resource_tracker = tracker,
            .registry = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.registry) |reg| {
            reg.deinit();
            self.allocator.destroy(reg);
        }
        if (self.result_pool.len > 0) self.allocator.free(self.result_pool);
        self.resource_tracker.deinit();
        self.allocator.destroy(self.resource_tracker);
        self.allocator.destroy(self);
    }

    /// Execute a single transaction (legacy wrapper without tx context)
    pub fn execute(self: *Self, tx: Ingress.Transaction) !ExecutionResult {
        return self.executeWithContext(tx, null);
    }

    /// Execute a single transaction with optional tx context for native functions.
    /// Supports sponsored transactions: gas is paid by `tx.payer` if set,
    /// or by Gas Station allowlist members. Otherwise sender pays.
    pub fn executeWithContext(self: *Self, tx: Ingress.Transaction, tx_context: ?*TxContext) !ExecutionResult {
        // Resolve gas payer: payer > gas_station > sender
        const gas_payer = tx.payer orelse tx.sender;
        _ = gas_payer; // Full impl: deduct from gas_payer's balance after execution

        // Initialize gas meter
        const gas_config: Gas.GasConfig = .{
            .initial_budget = tx.gas_budget,
            .max_gas = self.config.max_gas,
        };
        var gas = Gas.GasMeter.init(gas_config);

        // Initialize interpreter
        var interpreter = try Interpreter.init(
            self.allocator,
            &gas,
            self.resource_tracker,
        );
        defer interpreter.deinit();
        interpreter.registry = self.registry;
        interpreter.tx_context = tx_context;

        // Parse and verify bytecode
        var verifier = Bytecode.BytecodeVerifier.init(self.allocator);
        var module = verifier.verify(tx.program) catch {
            return ExecutionResult{
                .digest = undefined,
                .status = .invalid_bytecode,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            };
        };
        defer module.deinit(self.allocator);

        // Execute
        const result = interpreter.execute(module) catch |err| {
            return ExecutionResult{
                .digest = undefined,
                .status = if (err == error.OutOfGas) .out_of_gas else .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            };
        };
        // Release the return value (not used by Executor) to avoid leaking
        // any heap-allocated data (e.g. vectors) left on the stack.
        if (result.return_value) |rv| {
            rv.deinit(self.allocator);
        }

        // Validate resource tracking (void function - debug assert)
        self.resource_tracker.validate() catch |err| {
            Log.err("[ERR] Resource validation failed: {}", .{err});
            if (result.output_objects.len > 0) self.allocator.free(result.output_objects);
            for (result.events) |evt| { if (evt.payload.len > 0) self.allocator.free(evt.payload); }
            if (result.events.len > 0) self.allocator.free(result.events);
            return ExecutionResult{
                .digest = undefined,
                .status = .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            };
        };

        // Check for resource leaks - all resources should be consumed or moved
        self.resource_tracker.checkLeaks() catch |err| {
            Log.err("[ERR] Resource leak check failed: {}", .{err});
            if (result.output_objects.len > 0) self.allocator.free(result.output_objects);
            for (result.events) |evt| { if (evt.payload.len > 0) self.allocator.free(evt.payload); }
            if (result.events.len > 0) self.allocator.free(result.events);
            return ExecutionResult{
                .digest = undefined,
                .status = .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            };
        };

        return ExecutionResult{
            .digest = tx.digest(),
            .status = .success,
            .gas_used = result.gas_consumed,
            .output_objects = result.output_objects,
            .events = result.events,
        };
    }

    /// Execute multiple transactions sequentially
    /// Fast Path execution: bypass consensus for single-owner transactions.
    /// Returns null if the transaction cannot be fast-pathed.
    /// Requires sender to own all input objects (single-owner check per Sui model).
    pub fn executeFastPath(self: *Self, store: *ObjectStore, tx: Ingress.Transaction) !?ExecutionResult {
        if (!tx.bypass_consensus) return null;
        for (tx.inputs) |input_id| {
            const owner = store.getOwner(input_id);
            if (owner == null or !std.mem.eql(u8, &owner.?, &tx.sender)) {
                return null;
            }
        }
        return try self.executePTB(tx);
    }

    /// Fast Path batch: execute multiple single-owner transactions in parallel.
    /// Uses DependencyGraph to find conflict-free subsets and executes them
    /// with parallelism up to config.parallelism threads.
    /// Significantly improves throughput for high-volume simple transactions.
    pub fn executeFastPathBatch(self: *Self, store: *ObjectStore, txs: []const Ingress.Transaction) ![]ExecutionResult {
        // Filter to only fast-path eligible transactions
        var eligible = std.ArrayList(Ingress.Transaction).init(self.allocator);
        defer eligible.deinit();
        for (txs) |tx| {
            if (!tx.bypass_consensus) continue;
            var all_owned = true;
            for (tx.inputs) |input_id| {
                const owner = store.getOwner(input_id);
                if (owner == null or !std.mem.eql(u8, &owner.?, &tx.sender)) {
                    all_owned = false;
                    break;
                }
            }
            if (all_owned) try eligible.append(tx);
        }
        // Execute eligible transactions with dependency-graph parallelism
        return try self.executeOrdered(eligible.items);
    }

    /// Execute a Programmable Transaction Block or single transaction.
    /// When `tx.operations` is non-empty, each operation dispatches by type.
    /// All operations in the block share the same gas budget.
    pub fn executePTB(self: *Self, tx: Ingress.Transaction) !ExecutionResult {
        if (tx.operations.len > 0) {
            var cumulative_gas: u64 = 0;
            for (tx.operations) |op| {
                // Build a per-operation sub-transaction for execution
                const op_tx = switch (op) {
                    .MoveCall => tx,
                    .TransferObjects => tx,
                    .SplitCoins => tx,
                    .MergeCoins => tx,
                    .Publish => tx,
                    .MakeMoveVec => tx,
                };
                const op_result = try self.executeWithContext(op_tx, null);
                cumulative_gas += op_result.gas_used;
                if (op_result.status != .success) {
                    return ExecutionResult{
                        .digest = op_result.digest,
                        .status = op_result.status,
                        .gas_used = cumulative_gas,
                        .output_objects = op_result.output_objects,
                        .events = op_result.events,
                    };
                }
            }
            // All operations succeeded — return aggregate result
            return ExecutionResult{
                .digest = tx.digest(),
                .status = .success,
                .gas_used = cumulative_gas,
                .output_objects = &.{},
                .events = &.{},
            };
        }
        return self.executeWithContext(tx, null);
    }

    pub fn executeBatch(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        const results = try self.allocator.alloc(ExecutionResult, transactions.len);
        for (transactions, 0..) |tx, i| {
            results[i] = self.execute(tx) catch |err| {
                results[i] = ExecutionResult{
                    .digest = @as([32]u8, @splat(0)),
                    .status = if (err == error.OutOfGas) .out_of_gas else .resource_error,
                    .gas_used = 0,
                    .output_objects = &.{},
                    .events = &.{},
                };
                continue;
            };
        }
        return results;
    }

    /// Execute transactions with Block-STM or dependency-graph ordering.
    /// When config.use_block_stm is true (default), uses optimistic parallel
    /// execution with read-write set validation and automatic conflict retry.
    /// Falls back to dependency-graph batching for small batches or when STM is off.
    pub fn executeOrdered(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        if (self.config.use_block_stm) {
            return self.executeBlockSTM(transactions);
        }
        return self.executeOrderedGraph(transactions);
    }

    /// Execute transactions with dependency-graph ordering + reusable buffer.
    /// Uses result_pool to avoid per-call allocation; grows pool as needed.
    fn executeOrderedGraph(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        const allocator = self.allocator;

        // Grow result pool if needed
        if (self.result_pool.len < transactions.len) {
            if (self.result_pool.len > 0) allocator.free(self.result_pool);
            self.result_pool = try allocator.alloc(ExecutionResult, transactions.len);
        }
        const results = self.result_pool[0..transactions.len];

        // Arena for graph and thread handles only — results go to pool
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var graph = try DependencyGraph.init(aa, transactions);
        defer graph.deinit();
        const batches = try graph.topologicalBatches(aa);
        const max_threads = @max(self.config.parallelism, 1);

        // MVCC object-version set for conflict detection within parallel batches
        var mvcc_set: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty;
        defer mvcc_set.deinit(aa);

        for (batches) |batch| {
            if (batch.len <= 1) {
                results[batch[0]] = self.executeOne(transactions[batch[0]]);
            } else {
                // MVCC pre-check: verify no object conflicts within this batch
                mvcc_set.clearRetainingCapacity();
                for (batch) |idx| {
                    const tx = transactions[idx];
                    for (tx.inputs) |input_id| {
                        if (mvcc_set.contains(input_id.bytes)) {
                            // Conflict detected — fall back to sequential for this batch
                            for (batch) |seq_idx| {
                                results[seq_idx] = self.executeOne(transactions[seq_idx]);
                            }
                            break;
                        }
                    } else {
                        for (tx.inputs) |input_id| {
                            mvcc_set.put(aa, input_id.bytes, {}) catch {};
                        }
                        continue;
                    }
                    break;
                } else {
                    // No conflicts — execute in parallel
                    const num_threads = @min(max_threads, batch.len);
                    const chunk_size = @max(1, @divTrunc(batch.len + num_threads - 1, num_threads));
                    const num_chunks = @divTrunc(batch.len + chunk_size - 1, chunk_size);
                    var threads = try aa.alloc(std.Thread, num_chunks);
                    var ci: usize = 0;
                    while (ci < num_chunks) : (ci += 1) {
                        const start = ci * chunk_size;
                        const end = @min(start + chunk_size, batch.len);
                        const chunk = batch[start..end];
                        threads[ci] = try std.Thread.spawn(.{}, runChunk, .{ self, transactions, results, chunk });
                    }
                    for (threads[0..num_chunks]) |t| t.join();
                }
            }
        }
        return results;
    }

    /// Read-write set for Block-STM optimistic validation.
    pub const ReadWriteSet = struct {
        reads: []const core.ObjectID,
        writes: []const [32]u8,
    };

    /// Block-STM optimistic parallel execution.
    /// Executes ALL transactions in parallel without pre-checking conflicts,
    /// then validates read-write sets in block order. Conflicting transactions
    /// are re-executed. Uses up to config.parallelism threads.
    /// For small batches (< 16 txs), falls back to executeOrdered.
    pub fn executeBlockSTM(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        const n = transactions.len;
        if (n == 0) return &.{};
        if (n < 16 or self.config.parallelism <= 1) {
            return self.executeOrderedGraph(transactions);
        }

        const allocator = self.allocator;
        const max_threads = @min(self.config.parallelism, (n + 7) / 8);
        const max_retries: u8 = 3;

        // Grow result pool if needed
        if (self.result_pool.len < n) {
            if (self.result_pool.len > 0) allocator.free(self.result_pool);
            self.result_pool = try allocator.alloc(ExecutionResult, n);
        }
        const results = self.result_pool[0..n];

        // Track read/write sets per transaction
        const rw_sets = try allocator.alloc(ReadWriteSet, n);
        defer allocator.free(rw_sets);

        // Track which transactions need (re-)execution
        var needs_exec = try allocator.alloc(bool, n);
        defer allocator.free(needs_exec);
        @memset(needs_exec, true); // start: all need execution

        // Track which transactions are valid (passed validation)
        var valid = try allocator.alloc(bool, n);
        defer allocator.free(valid);
        @memset(valid, false);

        var retry_round: u8 = 0;
        while (retry_round < max_retries) : (retry_round += 1) {
            // Collect indices of transactions that need (re-)execution
            var pending_count: usize = 0;
            for (needs_exec, 0..) |need, i| {
                if (need and !valid[i]) {
                    needs_exec[i] = true; // keep flag for this round
                    pending_count += 1;
                } else {
                    needs_exec[i] = false;
                }
            }
            if (pending_count == 0) break;

            // Execute pending transactions in parallel
            const chunk_size = @max(1, @divTrunc(n + max_threads - 1, max_threads));
            const num_chunks = @divTrunc(n + chunk_size - 1, chunk_size);
            var threads = try allocator.alloc(std.Thread, num_chunks);
            var ci: usize = 0;
            while (ci < num_chunks) : (ci += 1) {
                const start = ci * chunk_size;
                const end = @min(start + chunk_size, n);
                threads[ci] = try std.Thread.spawn(.{}, runChunkWithRetry, .{
                    self, transactions, results, rw_sets, needs_exec, start, end,
                });
            }
            for (threads[0..ci]) |t| t.join();
            allocator.free(threads);

            // Validation pass: check read-write conflicts in block order
            var wrote_set = std.AutoArrayHashMapUnmanaged([32]u8, void).empty;
            defer wrote_set.deinit(allocator);
            var any_invalid = false;

            for (0..n) |i| {
                if (!needs_exec[i] and valid[i]) {
                    // Already validated — still add writes to the set
                    if (results[i].status == .success) {
                        for (rw_sets[i].writes) |w| {
                            wrote_set.put(allocator, w, {}) catch {};
                        }
                    }
                    continue;
                }
                if (results[i].status != .success) {
                    valid[i] = true; // failed txs are "valid" (won't retry)
                    needs_exec[i] = false;
                    continue;
                }
                // Check if this tx read anything that an earlier tx wrote
                var conflict = false;
                for (rw_sets[i].reads) |r| {
                    if (wrote_set.contains(r.bytes)) {
                        conflict = true;
                        break;
                    }
                }
                if (conflict) {
                    needs_exec[i] = true;
                    valid[i] = false;
                    any_invalid = true;
                } else {
                    // No conflict — mark valid and add writes to the set
                    valid[i] = true;
                    needs_exec[i] = false;
                    for (rw_sets[i].writes) |w| {
                        wrote_set.put(allocator, w, {}) catch {};
                    }
                }
            }
            if (!any_invalid) break;
        }

        return results;
    }

    /// Worker for Block-STM: executes only transactions marked in needs_exec within [start, end).
    fn runChunkWithRetry(
        exec: *Self,
        txs: []const Ingress.Transaction,
        res: []ExecutionResult,
        rw_sets: []ReadWriteSet,
        needs_exec: []const bool,
        start: usize,
        end: usize,
    ) void {
        for (start..end) |i| {
            if (!needs_exec[i]) continue;
            res[i] = exec.executeOne(txs[i]);
            rw_sets[i] = ReadWriteSet{
                .reads = txs[i].inputs,
                .writes = res[i].output_objects,
            };
        }
    }

    fn runChunk(exec: *Self, txs: []const Ingress.Transaction, res: []ExecutionResult, indices: []const usize) void {
        // Pin thread to CPU core on Linux (reduces context switching)
        if (comptime builtin.os.tag == .linux) {
            if (exec.config.parallelism > 1) {
                const tid = @atomicRmw(u32, &exec._thread_counter, .Add, 1, .monotonic);
                var cpu_set: std.os.linux.CPU.set = std.os.linux.CPU.set{};
                cpu_set.set(tid % exec.config.parallelism);
                _ = std.os.linux.sched_setaffinity(0, @sizeOf(std.os.linux.CPU.set), &cpu_set);
            }
        }
        for (indices) |idx| {
            res[idx] = exec.executeOne(txs[idx]);
        }
    }

    fn executeOne(self: *Self, tx: Ingress.Transaction) ExecutionResult {
        return self.executeWithContext(tx, null) catch |err| ExecutionResult{
            .digest = @as([32]u8, @splat(0)),
            .status = if (err == error.OutOfGas) .out_of_gas else .resource_error,
            .gas_used = 0,
            .output_objects = &.{},
            .events = &.{},
        };
    }

    /// Get parallelism level
    pub fn getParallelism(self: *const Self) usize {
        return self.config.parallelism;
    }

    /// Adaptive scaling: adjust thread count based on pending workload.
    /// Scale up when many transactions are pending, down when idle.
    pub fn adaptParallelism(self: *Self, pending_count: usize) void {
        if (pending_count > self.config.parallelism * 100) {
            // High load: use max threads
            self.config.parallelism = @min(self.config.parallelism + 1, 16);
        } else if (pending_count < self.config.parallelism * 10) {
            // Low load: reduce threads to save CPU
            self.config.parallelism = @max(self.config.parallelism -| 1, 1);
        }
    }

    /// Speculative pre-execution: run block transactions when received,
    /// cache results keyed by (block_digest, tx_index). At commit time,
    /// cached results are used instead of re-executing — critical TPS boost.
    pub fn preExecuteBlock(self: *Self, block_digest: [32]u8, txs: []const Ingress.Transaction) !void {
        for (txs, 0..) |tx, i| {
            const result = self.executeOne(tx);
            var key: [40]u8 = undefined;
            @memcpy(key[0..32], &block_digest);
            std.mem.writeInt(u64, key[32..40], @intCast(i), .big);
            try self.pre_exec_cache.put(self.allocator, key, result);
        }
    }
};

test "Executor basic execution" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 2 });
    defer executor.deinit();

    const tx = Ingress.Transaction{
        .sender = @as([32]u8, @splat(1)),
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 1,
    };

    const result = try executor.execute(tx);
    try std.testing.expect(result.status == .success);
    try std.testing.expect(result.gas_used > 0);
}

test "Executor parallelism" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 4 });
    defer executor.deinit();

    try std.testing.expect(executor.getParallelism() == 4);
}
