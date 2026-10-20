//! Executor - Transaction execution with resource tracking.
//!
//! Parallelism is driven by `ExecutorConfig.parallelism`:
//! - When `parallelism > 1`, a persistent `WorkerPool` is created at init
//!   (capped by `MAX_WORKER_POOL_SIZE`).
//! - Dependency-graph batches reuse the pool via `submit`; Block-STM
//!   optimistic waves reuse it via `submitRetryWave` (fallback: short-lived
//!   `Thread.spawn` if the pool is absent).
//! - `adaptParallelism` may grow the pool on scale-up (recreate up to the
//!   cap); scale-down only lowers the per-batch ceiling.
//! - Small Block-STM batches (n < 4) or `parallelism <= 1` fall back to the
//!   graph path.
//!
//! Key features:
//! - Reusable worker pool for graph-parallel and Block-STM waves
//! - Resource tracking with linear type guarantees
//! - Gas metering with budget enforcement

const std = @import("std");
const builtin = @import("builtin");
const Marketplace = @import("../property/move_vm/marketplace.zig").Marketplace;
const AgentMessaging = @import("../property/move_vm/agent_messaging.zig").AgentMessaging;
const AgentRegistry = @import("../property/move_vm/agent_registry.zig").AgentRegistry;
const core = @import("../core.zig");
const property = @import("../property.zig");
const Gas = property.move_vm.Gas;
const Resource = property.move_vm.Resource;
const ObjectStore = @import("../form/storage/ObjectStore.zig").ObjectStore;
const ResourceTracker = property.move_vm.ResourceTracker;
const Interpreter = property.move_vm.Interpreter;
const Bytecode = property.move_vm.Bytecode;
const Registry = property.move_vm.Registry;
const ModuleRegistry = property.move_vm.ModuleRegistry;
const TxContext = property.move_vm.TxContext;
const Event = property.move_vm.Event;
const ObjectEffect = @import("../property/move_vm/Interpreter.zig").ObjectEffect;
const Ingress = @import("Ingress.zig");
const DependencyGraph = @import("DependencyGraph.zig").DependencyGraph;
const Log = @import("../app/Log.zig");

/// Read-write set for Block-STM optimistic validation.
pub const ReadWriteSet = struct {
    reads: []const core.ObjectID,
    writes: []const [32]u8,
};

/// Which work payload `WorkerPool` workers should run for the current generation.
const WorkMode = enum { graph_chunk, retry_wave };

/// Inclusive-exclusive index range `[start, end)` for a Block-STM wave chunk.
const ChunkRange = struct { start: usize, end: usize };

/// Persistent thread pool for reusing workers across execution batches.
/// Avoids per-batch `std.Thread.spawn` in graph batches and Block-STM waves.
/// Must not be resized (`ensureWorkerPoolCapacity`) while a `submit*` is in flight.
pub const WorkerPool = struct {
    threads: []std.Thread,
    /// Bumped on each `submit` / `submitRetryWave` (and on shutdown) to wake idle workers.
    /// Waiters block via `std.Io.futexWaitUncancelable` on `.raw` (Zig 0.17; no `std.Thread.Futex`).
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Workers that have finished the current generation (including idle acks).
    done_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Shared execution context — set by submit APIs before bumping generation.
    mode: WorkMode = .graph_chunk,
    exec: ?*Executor = null,
    txs: ?[]const Ingress.Transaction = null,
    results: ?[]ExecutionResult = null,
    /// Graph path: per-worker index slices.
    chunks: ?[]const []const usize = null,
    /// Block-STM path: RW sets / pending flags / per-worker ranges.
    rw_sets: ?[]ReadWriteSet = null,
    needs_exec: ?[]const bool = null,
    ranges: ?[]const ChunkRange = null,
    size: usize,
    started: bool = false,

    fn ioHandle() std.Io {
        return @import("io_instance").io;
    }

    fn wakeGeneration(self: *WorkerPool) void {
        ioHandle().futexWake(u32, &self.generation.raw, std.math.maxInt(u32));
    }

    fn wakeDone(self: *WorkerPool) void {
        ioHandle().futexWake(u32, &self.done_count.raw, 1);
    }

    fn init(allocator: std.mem.Allocator, size: usize) !WorkerPool {
        const n = @max(size, 1);
        const threads = try allocator.alloc(std.Thread, n);
        return .{ .threads = threads, .size = n };
    }

    /// Spawn persistent workers. Must be called on a stable `*WorkerPool`
    /// (e.g. after storing into `Executor.worker_pool`).
    fn start(self: *WorkerPool) !void {
        if (self.started) return;
        var spawned: usize = 0;
        errdefer {
            self.shutdown.store(true, .release);
            _ = self.generation.fetchAdd(1, .release);
            self.wakeGeneration();
            for (self.threads[0..spawned]) |t| t.join();
            self.started = false;
            self.shutdown.store(false, .monotonic);
        }
        for (0..self.size) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, workerMain, .{ self, i });
            spawned += 1;
        }
        self.started = true;
    }

    fn deinit(self: *WorkerPool, allocator: std.mem.Allocator) void {
        if (self.started) {
            self.shutdown.store(true, .release);
            _ = self.generation.fetchAdd(1, .release);
            self.wakeGeneration();
            for (self.threads) |t| t.join();
            self.started = false;
        }
        allocator.free(self.threads);
    }

    fn workerMain(self: *WorkerPool, worker_id: usize) void {
        const iov = ioHandle();
        var last_gen: u32 = 0;
        while (true) {
            while (true) {
                if (self.shutdown.load(.acquire)) return;
                const gen = self.generation.load(.acquire);
                if (gen != last_gen) {
                    last_gen = gen;
                    break;
                }
                // Block until submit/deinit bumps generation (or spurious wake).
                iov.futexWaitUncancelable(u32, &self.generation.raw, last_gen);
            }
            if (self.shutdown.load(.acquire)) return;

            if (self.exec) |exec| {
                const txs = self.txs orelse unreachable;
                const results = self.results orelse unreachable;
                switch (self.mode) {
                    .graph_chunk => {
                        if (self.chunks) |chunks| {
                            if (worker_id < chunks.len) {
                                Executor.runChunk(exec, txs, results, chunks[worker_id]);
                            }
                        }
                    },
                    .retry_wave => {
                        if (self.ranges) |ranges| {
                            if (worker_id < ranges.len) {
                                const r = ranges[worker_id];
                                const rw_sets = self.rw_sets orelse unreachable;
                                const needs_exec = self.needs_exec orelse unreachable;
                                Executor.runChunkWithRetry(exec, txs, results, rw_sets, needs_exec, r.start, r.end);
                            }
                        }
                    },
                }
            }
            const prev = self.done_count.fetchAdd(1, .release);
            // Wake `waitAllAcked` once the last worker acks this generation.
            if (prev + 1 >= self.size) {
                self.wakeDone();
            }
        }
    }

    fn waitAllAcked(self: *WorkerPool) void {
        // All workers ack each generation (idle workers with no chunk still ack).
        const iov = ioHandle();
        const need: u32 = @intCast(self.size);
        while (true) {
            const done = self.done_count.load(.acquire);
            if (done >= need) break;
            iov.futexWaitUncancelable(u32, &self.done_count.raw, done);
        }
    }

    /// Run graph `chunks` in parallel (at most `size` chunks). Returns when all workers ack.
    /// Must not run concurrently with `submitRetryWave` or pool resize.
    fn submit(
        self: *WorkerPool,
        exec: *Executor,
        txs: []const Ingress.Transaction,
        results: []ExecutionResult,
        chunks: []const []const usize,
    ) void {
        std.debug.assert(self.started);
        std.debug.assert(chunks.len <= self.size);

        self.mode = .graph_chunk;
        self.exec = exec;
        self.txs = txs;
        self.results = results;
        self.chunks = chunks;
        self.rw_sets = null;
        self.needs_exec = null;
        self.ranges = null;
        self.done_count.store(0, .monotonic);
        _ = self.generation.fetchAdd(1, .release);
        self.wakeGeneration();
        self.waitAllAcked();
    }

    /// Run Block-STM `runChunkWithRetry` over `ranges` (at most `size`). Returns when all ack.
    /// Must not run concurrently with `submit` or pool resize.
    fn submitRetryWave(
        self: *WorkerPool,
        exec: *Executor,
        txs: []const Ingress.Transaction,
        results: []ExecutionResult,
        rw_sets: []ReadWriteSet,
        needs_exec: []const bool,
        ranges: []const ChunkRange,
    ) void {
        std.debug.assert(self.started);
        std.debug.assert(ranges.len <= self.size);

        self.mode = .retry_wave;
        self.exec = exec;
        self.txs = txs;
        self.results = results;
        self.chunks = null;
        self.rw_sets = rw_sets;
        self.needs_exec = needs_exec;
        self.ranges = ranges;
        self.done_count.store(0, .monotonic);
        _ = self.generation.fetchAdd(1, .release);
        self.wakeGeneration();
        self.waitAllAcked();
    }
};

/// Execution result — packed for cache efficiency.
/// Hot fields (digest, status, gas_used) fit in a single cache line.
pub const ExecutionResult = struct {
    digest: [32]u8,
    status: ExecutionStatus,
    gas_used: u64,
    output_objects: [][32]u8 align(8),
    events: []Event align(8),
    /// Transfer, share, and freeze effects copied out of the interpreter.
    object_effects: []ObjectEffect align(8) = &.{},

    /// Release all owned memory
    pub fn deinit(self: ExecutionResult, allocator: std.mem.Allocator) void {
        if (self.output_objects.len > 0) allocator.free(self.output_objects);
        for (self.events) |evt| {
            if (evt.payload.len > 0) allocator.free(evt.payload);
        }
        if (self.events.len > 0) allocator.free(self.events);
        if (self.object_effects.len > 0) allocator.free(self.object_effects);
    }
};

/// Execution status
pub const ExecutionStatus = enum {
    success,
    out_of_gas,
    invalid_bytecode,
    resource_error,
    /// Payer balance too low for gas_budget / gas_used (only when enforce_gas_payment).
    insufficient_gas_funds,
};

/// Executor configuration
pub const ExecutorConfig = struct {
    parallelism: usize = 4,
    max_gas: u64 = 10_000_000,
    /// Use Block-STM optimistic execution instead of dependency-graph batching
    use_block_stm: bool = true,
};

/// Executor with transaction execution support
pub const Executor = struct {
    const Self = @This();
    /// Hard cap on persistent WorkerPool threads (and on adaptive scale-up).
    /// Prevents miswiring `parallelism = max_txs_per_block` from spawning thousands of OS threads.
    pub const MAX_WORKER_POOL_SIZE: usize = 16;

    allocator: std.mem.Allocator,
    config: ExecutorConfig,
    /// Per-instance thread affinity counter
    _thread_counter: u32 = 0,
    /// Pre-execution result cache: keyed by (block_digest, tx_index)
    pre_exec_cache: std.AutoArrayHashMapUnmanaged([40]u8, ExecutionResult) = .empty,
    /// Reusable result buffer. Slots are empty until a batch fills them.
    /// Returned batches are moved out, so callers free their own array.
    result_pool: []ExecutionResult = &.{},
    result_pool_live: usize = 0,
    /// Optional native function registry for VM calls.
    /// Ownership: once set, the Executor takes ownership and will deinit+destroy in deinit().
    registry: ?*Registry = null,
    /// On-chain published module registry (owned by the Executor).
    module_registry: ModuleRegistry = undefined,
    /// Optional object store for persisting published module objects.
    object_store: ?*ObjectStore = null,
    /// Consensus epoch injected into every transaction that does not bring its own context.
    epoch: u64 = 0,
    /// Epoch start in milliseconds. Bytecode reads this instead of the host clock.
    epoch_timestamp_ms: u64 = 0,
    /// Optional domain clocks. When attached, `setEpoch` keeps them on the epoch start.
    marketplace: ?*Marketplace = null,
    agent_messaging: ?*AgentMessaging = null,
    agent_registry: ?*AgentRegistry = null,
    /// Pragmatic gas ledger (address → balance). Not a full gas-coin object model.
    /// Policy: when `enforce_gas_payment` is false (default), balances are ignored and
    /// existing callers keep working. When true, missing addresses count as 0; we require
    /// balance >= gas_budget before exec, then deduct actual gas_used (success or failure)
    /// with fail-closed (no partial deduct if balance < gas_used).
    gas_accounts: std.AutoHashMapUnmanaged([32]u8, u64) = .empty,
    enforce_gas_payment: bool = false,
    /// Optional durability hook (Node wires to `appendGasBalanceWal`). Cleared during WAL replay.
    on_gas_balance_changed: ?*const fn (*anyopaque, [32]u8, u64) anyerror!void = null,
    gas_balance_ctx: ?*anyopaque = null,
    /// Persistent workers when `config.parallelism > 1` (may grow via adaptParallelism).
    /// Joined in `deinit`. Do not resize while a pool submit is in flight.
    worker_pool: ?WorkerPool = null,

    pub fn init(allocator: std.mem.Allocator, config: ExecutorConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .registry = null,
            .module_registry = ModuleRegistry.init(allocator),
            .object_store = null,
            .epoch = 0,
            .epoch_timestamp_ms = 0,
            .marketplace = null,
            .agent_messaging = null,
            .agent_registry = null,
            .gas_accounts = .empty,
            .enforce_gas_payment = false,
            .on_gas_balance_changed = null,
            .gas_balance_ctx = null,
            .worker_pool = null,
        };
        if (config.parallelism > 1) {
            const pool_size = @min(config.parallelism, Self.MAX_WORKER_POOL_SIZE);
            self.worker_pool = try WorkerPool.init(allocator, pool_size);
            errdefer {
                if (self.worker_pool) |*p| {
                    p.deinit(allocator);
                    self.worker_pool = null;
                }
            }
            try self.worker_pool.?.start();
        }
        return self;
    }

    /// Wire Node-owned M4 gas WAL append callback. Pass nulls to disable (replay).
    pub fn setGasBalanceWalHook(
        self: *Self,
        ctx: ?*anyopaque,
        cb: ?*const fn (*anyopaque, [32]u8, u64) anyerror!void,
    ) void {
        self.gas_balance_ctx = ctx;
        self.on_gas_balance_changed = cb;
    }

    fn persistGasBalance(self: *Self, addr: [32]u8, balance: u64) !void {
        if (self.on_gas_balance_changed) |cb| {
            const ctx = self.gas_balance_ctx orelse return;
            try cb(ctx, addr, balance);
        }
    }

    /// Seed or update a payer's gas balance (tests / Node wiring). Absolute set.
    pub fn setGasBalance(self: *Self, addr: [32]u8, amount: u64) !void {
        try self.gas_accounts.put(self.allocator, addr, amount);
        try self.persistGasBalance(addr, amount);
    }

    /// Current ledger balance; unset addresses are 0.
    pub fn getGasBalance(self: *const Self, addr: [32]u8) u64 {
        return self.gas_accounts.get(addr) orelse 0;
    }

    /// Operational credit: add `amount` to the ledger. Fail-closed on u64 overflow.
    /// Durability: Node.creditGas appends M4 WAL after this returns; deduct/set use the hook.
    pub fn creditGasBalance(self: *Self, addr: [32]u8, amount: u64) !void {
        const current = self.getGasBalance(addr);
        const next, const overflow = @addWithOverflow(current, amount);
        if (overflow != 0) return error.Overflow;
        try self.gas_accounts.put(self.allocator, addr, next);
    }

    /// Fail-closed deduct: only mutates when balance >= gas_used.
    fn tryDeductGas(self: *Self, payer: [32]u8, gas_used: u64) bool {
        if (!self.enforce_gas_payment or gas_used == 0) return true;
        const bal = self.getGasBalance(payer);
        if (bal < gas_used) return false;
        const entry = self.gas_accounts.getPtr(payer) orelse return false;
        const next, const overflow = @subWithOverflow(entry.*, gas_used);
        if (overflow != 0) return false;
        entry.* = next;
        self.persistGasBalance(payer, next) catch {
            entry.* = bal;
            return false;
        };
        return true;
    }

    /// Apply gas payment after metering. On insufficient funds, discards success
    /// effects and returns `insufficient_gas_funds` without mutating the ledger.
    fn settleGasPayment(self: *Self, payer: [32]u8, result: ExecutionResult) ExecutionResult {
        if (!self.enforce_gas_payment) return result;
        if (self.tryDeductGas(payer, result.gas_used)) return result;
        result.deinit(self.allocator);
        return .{
            .digest = result.digest,
            .status = .insufficient_gas_funds,
            .gas_used = result.gas_used,
            .output_objects = &.{},
            .events = &.{},
        };
    }

    pub fn setEpoch(self: *Self, number: u64, timestamp_ms: u64) void {
        self.epoch = number;
        self.epoch_timestamp_ms = timestamp_ms;
        const epoch_sec: i64 = @intCast(@divTrunc(timestamp_ms, 1000));
        if (self.marketplace) |mp| mp.setClock(epoch_sec);
        if (self.agent_messaging) |am| am.setClock(epoch_sec);
        if (self.agent_registry) |reg| reg.setClock(epoch_sec);
    }

    fn bindContext(self: *Self, tx: Ingress.Transaction, tx_context: ?*TxContext, fallback: *TxContext) *TxContext {
        if (tx_context) |ctx| return ctx;
        fallback.* = .{
            .sender = tx.sender,
            .tx_hash = tx.digest(),
            .epoch = self.epoch,
            .gas_price = 1,
            .gas_budget = tx.gas_budget,
            .epoch_timestamp_ms = self.epoch_timestamp_ms,
        };
        return fallback;
    }

    pub fn deinit(self: *Self) void {
        if (self.worker_pool) |*pool| {
            pool.deinit(self.allocator);
            self.worker_pool = null;
        }
        if (self.registry) |reg| {
            reg.deinit();
            self.allocator.destroy(reg);
        }
        // Domain clocks are borrowed; the owner frees them.
        self.marketplace = null;
        self.agent_messaging = null;
        self.agent_registry = null;
        self.module_registry.deinit();
        var cached = self.pre_exec_cache.iterator();
        while (cached.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.pre_exec_cache.deinit(self.allocator);
        self.gas_accounts.deinit(self.allocator);
        self.releaseResultPool();
        self.allocator.destroy(self);
    }

    /// Execute a single transaction (legacy wrapper without tx context)
    pub fn execute(self: *Self, tx: Ingress.Transaction) !ExecutionResult {
        return self.executeWithContext(tx, null);
    }

    /// Copy interpreter outputs into executor-owned memory.
    /// The interpreter frees its own lists on deinit, so the returned slices
    /// must not alias them. Empty inputs stay as zero-length slices.
    fn copyVmEffects(
        self: *Self,
        objects: []const [32]u8,
        events: []const Event,
        effects: []const ObjectEffect,
    ) !struct { output_objects: [][32]u8, events: []Event, object_effects: []ObjectEffect } {
        const owned_objects: [][32]u8 = if (objects.len == 0)
            @constCast(@as([]const [32]u8, &.{}))
        else
            try self.allocator.dupe([32]u8, objects);
        errdefer if (owned_objects.len > 0) self.allocator.free(owned_objects);

        const owned_effects: []ObjectEffect = if (effects.len == 0)
            @constCast(@as([]const ObjectEffect, &.{}))
        else
            try self.allocator.dupe(ObjectEffect, effects);
        errdefer if (owned_effects.len > 0) self.allocator.free(owned_effects);

        const owned_events: []Event = if (events.len == 0)
            @constCast(@as([]const Event, &.{}))
        else
            try self.allocator.alloc(Event, events.len);
        var copied: usize = 0;
        errdefer {
            for (owned_events[0..copied]) |evt| {
                if (evt.payload.len > 0) self.allocator.free(evt.payload);
            }
            if (owned_events.len > 0) self.allocator.free(owned_events);
        }
        for (events, 0..) |evt, i| {
            owned_events[i] = evt;
            owned_events[i].payload = if (evt.payload.len == 0) &.{} else try self.allocator.dupe(u8, evt.payload);
            copied += 1;
        }
        return .{
            .output_objects = owned_objects,
            .events = owned_events,
            .object_effects = owned_effects,
        };
    }

    /// Execute a single transaction with optional tx context for native functions.
    /// Supports sponsored transactions: gas is paid by `tx.payer` if set,
    /// otherwise sender pays. See `enforce_gas_payment` / `gas_accounts` for ledger policy.
    pub fn executeWithContext(self: *Self, tx: Ingress.Transaction, tx_context: ?*TxContext) !ExecutionResult {
        const gas_payer = tx.payer orelse tx.sender;

        // Fail-closed upfront: require full budget coverage before any VM work.
        if (self.enforce_gas_payment and self.getGasBalance(gas_payer) < tx.gas_budget) {
            return ExecutionResult{
                .digest = tx.digest(),
                .status = .insufficient_gas_funds,
                .gas_used = 0,
                .output_objects = &.{},
                .events = &.{},
            };
        }

        // Initialize gas meter
        const gas_config: Gas.GasConfig = .{
            .initial_budget = tx.gas_budget,
            .max_gas = self.config.max_gas,
        };
        var gas = Gas.GasMeter.init(gas_config);

        // Fresh tracker per call. validate/checkLeaks only cover this tx, and
        // WorkerPool workers must not share one unsynchronized ResourceTracker.
        var tx_tracker = ResourceTracker.init(self.allocator);
        defer tx_tracker.deinit();

        // Initialize interpreter
        var interpreter = try Interpreter.init(
            self.allocator,
            &gas,
            &tx_tracker,
        );
        defer interpreter.deinit();
        interpreter.registry = self.registry;
        var fallback_context: TxContext = undefined;
        interpreter.tx_context = self.bindContext(tx, tx_context, &fallback_context);

        // Parse and verify bytecode
        var verifier = Bytecode.BytecodeVerifier.init(self.allocator);
        var module = verifier.verify(tx.program) catch {
            return self.settleGasPayment(gas_payer, .{
                .digest = tx.digest(),
                .status = .invalid_bytecode,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            });
        };
        defer module.deinit(self.allocator);

        // Execute
        const result = interpreter.execute(module) catch |err| {
            return self.settleGasPayment(gas_payer, .{
                .digest = tx.digest(),
                .status = if (err == error.OutOfGas) .out_of_gas else .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            });
        };
        // Release the return value (not used by Executor) to avoid leaking
        // any heap-allocated data (e.g. vectors) left on the stack.
        if (result.return_value) |rv| {
            rv.deinit(self.allocator);
        }

        // Validate resource tracking (void function - debug assert)
        tx_tracker.validate() catch |err| {
            Log.err("[ERR] Resource validation failed: {}", .{err});
            return self.settleGasPayment(gas_payer, .{
                .digest = tx.digest(),
                .status = .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            });
        };

        // Check for resource leaks - all resources should be consumed or moved
        tx_tracker.checkLeaks() catch |err| {
            Log.err("[ERR] Resource leak check failed: {}", .{err});
            return self.settleGasPayment(gas_payer, .{
                .digest = tx.digest(),
                .status = .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            });
        };

        const owned = try self.copyVmEffects(result.output_objects, result.events, result.object_effects);
        return self.settleGasPayment(gas_payer, .{
            .digest = tx.digest(),
            .status = .success,
            .gas_used = result.gas_consumed,
            .output_objects = owned.output_objects,
            .events = owned.events,
            .object_effects = owned.object_effects,
        });
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

    /// Attach an object store so Publish operations persist module objects.
    pub fn attachObjectStore(self: *Self, store: *ObjectStore) void {
        self.object_store = store;
    }

    const PublishSummary = struct {
        ids: [][32]u8,
        gas_after: u64,
    };

    /// Register every module blob from a Publish operation on-chain.
    /// Charges gas per published byte; persists module objects when a store
    /// is attached. Caller owns the returned ids slice.
    fn publishModules(self: *Self, tx: Ingress.Transaction, blobs: []const []const u8, gas_so_far: u64) !PublishSummary {
        var ids = try self.allocator.alloc([32]u8, blobs.len);
        errdefer self.allocator.free(ids);
        var gas_after = gas_so_far;
        for (blobs, 0..) |blob, i| {
            const outcome = try self.module_registry.publish(tx.sender, tx.sender, blob, 0);
            gas_after += outcome.gas_charge;
            if (outcome.upgraded) gas_after /= 2; // upgrades are cheaper than fresh publishes
            ids[i] = outcome.id;
            if (self.object_store) |store| {
                // put() serializes internally; the data copy stays ours.
                const data = try self.allocator.dupe(u8, blob);
                defer self.allocator.free(data);
                try store.put(.{
                    .id = .{ .bytes = outcome.id },
                    .version = .{ .seq = @intCast(outcome.version), .causal = @as([16]u8, @splat(0)) },
                    .ownership = core.Ownership.shared(0),
                    .type_tag = 2, // module object
                    .data = data,
                });
            }
        }
        return .{ .ids = ids, .gas_after = gas_after };
    }

    /// Execute a Programmable Transaction Block or single transaction.
    /// When `tx.operations` is non-empty, each operation dispatches by type.
    /// All operations in the block share the same gas budget.
    pub fn executePTB(self: *Self, tx: Ingress.Transaction) !ExecutionResult {
        if (tx.operations.len > 0) {
            var cumulative_gas: u64 = 0;
            var published_ids = std.ArrayList([32]u8).empty;
            defer published_ids.deinit(self.allocator);
            for (tx.operations) |op| {
                // Publish operations register modules on-chain instead of
                // running bytecode: each module blob is decoded, policy-
                // checked, versioned, and (when a store is attached)
                // persisted as a module object.
                if (op == .Publish) {
                    const outcome = self.publishModules(tx, op.Publish.modules, cumulative_gas) catch {
                        return ExecutionResult{
                            .digest = tx.digest(),
                            .status = .invalid_bytecode,
                            .gas_used = cumulative_gas,
                            .output_objects = &.{},
                            .events = &.{},
                        };
                    };
                    cumulative_gas = outcome.gas_after;
                    try published_ids.appendSlice(self.allocator, outcome.ids);
                    self.allocator.free(outcome.ids);
                    continue;
                }
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
                        .object_effects = op_result.object_effects,
                    };
                }
                op_result.deinit(self.allocator);
            }
            // All operations succeeded — return aggregate result with the
            // ids of any published module objects.
            const owned_ids = try self.allocator.dupe([32]u8, published_ids.items);
            return ExecutionResult{
                .digest = tx.digest(),
                .status = .success,
                .gas_used = cumulative_gas,
                .output_objects = owned_ids,
                .events = &.{},
            };
        }
        return self.executeWithContext(tx, null);
    }

    /// Execute a batch via `executeOrdered` so `parallelism` / WorkerPool apply.
    pub fn executeBatch(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        return self.executeOrdered(transactions);
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

    fn emptyResult() ExecutionResult {
        return .{
            .digest = @as([32]u8, @splat(0)),
            .status = .success,
            .gas_used = 0,
            .output_objects = &.{},
            .events = &.{},
        };
    }

    fn assignResult(slot: *ExecutionResult, next: ExecutionResult, allocator: std.mem.Allocator) void {
        slot.deinit(allocator);
        slot.* = next;
    }

    /// Drop every live pooled result, then free the array.
    fn releaseResultPool(self: *Self) void {
        const live = @min(self.result_pool_live, self.result_pool.len);
        for (self.result_pool[0..live]) |res| res.deinit(self.allocator);
        if (self.result_pool.len > 0) self.allocator.free(self.result_pool);
        self.result_pool = &.{};
        self.result_pool_live = 0;
    }

    /// Slots `0..n` are empty results and safe to overwrite with `assignResult`.
    fn prepareResultSlots(self: *Self, n: usize) ![]ExecutionResult {
        if (n == 0) return &.{};
        if (self.result_pool.len < n) {
            self.releaseResultPool();
            self.result_pool = try self.allocator.alloc(ExecutionResult, n);
            for (self.result_pool) |*slot| slot.* = emptyResult();
        } else {
            const live = @min(self.result_pool_live, self.result_pool.len);
            for (self.result_pool[0..live]) |*slot| {
                slot.deinit(self.allocator);
                slot.* = emptyResult();
            }
            if (n > live) {
                for (self.result_pool[live..n]) |*slot| slot.* = emptyResult();
            }
        }
        self.result_pool_live = n;
        return self.result_pool[0..n];
    }

    /// Move pooled results into a caller-owned array. Pool slots become empty.
    fn moveOutResults(self: *Self, n: usize) ![]ExecutionResult {
        if (n == 0) return &.{};
        const out = try self.allocator.alloc(ExecutionResult, n);
        for (0..n) |i| {
            out[i] = self.result_pool[i];
            self.result_pool[i] = emptyResult();
        }
        return out;
    }

    /// Execute transactions with dependency-graph ordering.
    /// The returned array is owned by the caller.
    fn executeOrderedGraph(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        const allocator = self.allocator;
        const results = try self.prepareResultSlots(transactions.len);

        // Arena for graph and thread handles only — results go to pool
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var graph = try DependencyGraph.init(aa, transactions);
        defer graph.deinit();
        const batches = try graph.topologicalBatches(aa);
        const pool_cap: usize = if (self.worker_pool) |*pool| pool.size else std.math.maxInt(usize);
        const max_threads = @min(@max(self.config.parallelism, 1), pool_cap);

        // MVCC object-version set for conflict detection within parallel batches
        var mvcc_set: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty;
        defer mvcc_set.deinit(aa);

        for (batches) |batch| {
            if (batch.len <= 1) {
                assignResult(&results[batch[0]], self.executeOne(transactions[batch[0]]), allocator);
                continue;
            }
            // A shared input, or a failed record of an input, runs the batch in order.
            mvcc_set.clearRetainingCapacity();
            var conflict = false;
            for (batch) |idx| {
                if (conflict) break;
                for (transactions[idx].inputs) |input_id| {
                    if (mvcc_set.contains(input_id.bytes)) {
                        conflict = true;
                        break;
                    }
                    mvcc_set.put(aa, input_id.bytes, {}) catch {
                        conflict = true;
                        break;
                    };
                }
            }
            if (conflict) {
                for (batch) |seq_idx| {
                    assignResult(&results[seq_idx], self.executeOne(transactions[seq_idx]), allocator);
                }
                continue;
            }
            const num_threads = @min(max_threads, batch.len);
            const chunk_size = @max(1, @divTrunc(batch.len + num_threads - 1, num_threads));
            const num_chunks = @divTrunc(batch.len + chunk_size - 1, chunk_size);
            var chunk_slices = try aa.alloc([]const usize, num_chunks);
            var ci: usize = 0;
            while (ci < num_chunks) : (ci += 1) {
                const start = ci * chunk_size;
                const end = @min(start + chunk_size, batch.len);
                chunk_slices[ci] = batch[start..end];
            }
            if (self.worker_pool) |*pool| {
                pool.submit(self, transactions, results, chunk_slices);
            } else {
                var threads = try aa.alloc(std.Thread, num_chunks);
                ci = 0;
                while (ci < num_chunks) : (ci += 1) {
                    threads[ci] = try std.Thread.spawn(.{}, runChunk, .{ self, transactions, results, chunk_slices[ci] });
                }
                for (threads[0..num_chunks]) |t| t.join();
            }
        }
        return self.moveOutResults(transactions.len);
    }

    /// Block-STM optimistic parallel execution.
    /// Executes ALL transactions in parallel without pre-checking conflicts,
    /// then validates read-write sets in block order. Conflicting transactions
    /// are re-executed. Prefers the persistent `WorkerPool` via `submitRetryWave`;
    /// falls back to short-lived threads when the pool is absent.
    /// For small batches (n < 4) or parallelism <= 1, falls back to the
    /// dependency-graph path.
    pub fn executeBlockSTM(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        const n = transactions.len;
        if (n == 0) return &.{};
        if (n < 4 or self.config.parallelism <= 1) {
            return self.executeOrderedGraph(transactions);
        }

        const allocator = self.allocator;
        const pool_cap: usize = if (self.worker_pool) |*pool| pool.size else std.math.maxInt(usize);
        const max_threads = @min(@min(self.config.parallelism, (n + 7) / 8), pool_cap);
        const max_retries: u8 = 3;
        const results = try self.prepareResultSlots(n);

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

            // Execute pending transactions in parallel (range chunks over [0, n)).
            const chunk_size = @max(1, @divTrunc(n + max_threads - 1, max_threads));
            const num_chunks = @divTrunc(n + chunk_size - 1, chunk_size);
            var ranges = try allocator.alloc(ChunkRange, num_chunks);
            defer allocator.free(ranges);
            var ci: usize = 0;
            while (ci < num_chunks) : (ci += 1) {
                const start = ci * chunk_size;
                const end = @min(start + chunk_size, n);
                ranges[ci] = .{ .start = start, .end = end };
            }
            if (self.worker_pool) |*pool| {
                pool.submitRetryWave(self, transactions, results, rw_sets, needs_exec, ranges);
            } else {
                var threads = try allocator.alloc(std.Thread, num_chunks);
                defer allocator.free(threads);
                ci = 0;
                while (ci < num_chunks) : (ci += 1) {
                    threads[ci] = try std.Thread.spawn(.{}, runChunkWithRetry, .{
                        self, transactions, results, rw_sets, needs_exec, ranges[ci].start, ranges[ci].end,
                    });
                }
                for (threads[0..num_chunks]) |t| t.join();
            }

            // Validation pass: check read-write conflicts in block order
            var wrote_set = std.AutoArrayHashMapUnmanaged([32]u8, void).empty;
            defer wrote_set.deinit(allocator);
            var any_invalid = false;

            for (0..n) |i| {
                if (!needs_exec[i] and valid[i]) {
                    // Already validated — still add writes to the set
                    if (results[i].status == .success) {
                        for (rw_sets[i].writes) |w| {
                            try wrote_set.put(allocator, w, {});
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
                        try wrote_set.put(allocator, w, {});
                    }
                }
            }
            if (!any_invalid) break;
        }

        return self.moveOutResults(n);
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
            assignResult(&res[i], exec.executeOne(txs[i]), exec.allocator);
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
                // Raw affinity mask (cpu_set_t layout, 1024 CPUs): avoids
                // std.os.linux.CPU.set, whose location moved across
                // 0.17-dev nightlies.
                var cpu_mask: [16]u8 = @splat(0);
                const target_core = tid % @as(u32, @intCast(exec.config.parallelism));
                cpu_mask[target_core / 8] |= @as(u8, 1) << @intCast(target_core % 8);
                _ = std.os.linux.syscall3(.sched_setaffinity, 0, cpu_mask.len, @intFromPtr(&cpu_mask));
            }
        }
        for (indices) |idx| {
            assignResult(&res[idx], exec.executeOne(txs[idx]), exec.allocator);
        }
    }

    fn executeOne(self: *Self, tx: Ingress.Transaction) ExecutionResult {
        return self.executeWithContext(tx, null) catch |err| ExecutionResult{
            .digest = tx.digest(),
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

    /// Grow (or create) the persistent pool so `pool.size >= target`, capped by
    /// `MAX_WORKER_POOL_SIZE`. Recreates the pool when expansion is needed —
    /// must not be called while `submit` / `submitRetryWave` is in flight.
    fn ensureWorkerPoolCapacity(self: *Self, target: usize) !void {
        const want = @min(@max(target, 1), Self.MAX_WORKER_POOL_SIZE);
        if (want <= 1) return;
        if (self.worker_pool) |*pool| {
            if (pool.size >= want) return;
            pool.deinit(self.allocator);
            self.worker_pool = null;
        }
        self.worker_pool = try WorkerPool.init(self.allocator, want);
        errdefer {
            if (self.worker_pool) |*p| {
                p.deinit(self.allocator);
                self.worker_pool = null;
            }
        }
        try self.worker_pool.?.start();
    }

    /// Adaptive scaling: adjust concurrency based on pending workload.
    /// Scale-up raises `config.parallelism` and grows the WorkerPool when
    /// `pool.size` is below the new target (recreate, capped).
    /// Scale-down only lowers the per-batch ceiling; pool size is left as-is
    /// so idle workers remain cheap to keep and resize races are avoided.
    pub fn adaptParallelism(self: *Self, pending_count: usize) void {
        if (pending_count > self.config.parallelism * 100) {
            const new_par = @min(self.config.parallelism + 1, Self.MAX_WORKER_POOL_SIZE);
            self.config.parallelism = new_par;
            self.ensureWorkerPoolCapacity(new_par) catch {};
        } else if (pending_count < self.config.parallelism * 10) {
            self.config.parallelism = @max(self.config.parallelism -| 1, 1);
        }
    }

    fn preExecKey(block_digest: [32]u8, index: u64) [40]u8 {
        var key: [40]u8 = undefined;
        @memcpy(key[0..32], &block_digest);
        std.mem.writeInt(u64, key[32..40], index, .big);
        return key;
    }

    /// Speculative pre-execution: run block transactions when received,
    /// cache results keyed by (block_digest, tx_index). Replacing an entry
    /// frees the previous result. `takePreExecuted` moves one result out.
    pub fn preExecuteBlock(self: *Self, block_digest: [32]u8, txs: []const Ingress.Transaction) !void {
        for (txs, 0..) |tx, i| {
            const result = self.executeOne(tx);
            const prev = self.pre_exec_cache.fetchPut(self.allocator, preExecKey(block_digest, @intCast(i)), result) catch |err| {
                result.deinit(self.allocator);
                return err;
            };
            if (prev) |old| old.value.deinit(self.allocator);
        }
    }

    /// Remove one cached pre-execution result. The caller owns it.
    pub fn takePreExecuted(self: *Self, block_digest: [32]u8, index: u64) ?ExecutionResult {
        const kv = self.pre_exec_cache.fetchSwapRemove(preExecKey(block_digest, index)) orelse return null;
        return kv.value;
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

test "creditGasBalance adds and rejects u64 overflow" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    const addr: [32]u8 = @splat(0x55);
    try std.testing.expectEqual(@as(u64, 0), executor.getGasBalance(addr));

    try executor.creditGasBalance(addr, 100);
    try std.testing.expectEqual(@as(u64, 100), executor.getGasBalance(addr));
    try executor.creditGasBalance(addr, 50);
    try std.testing.expectEqual(@as(u64, 150), executor.getGasBalance(addr));

    // Absolute set remains available and does not bypass overflow on credit.
    try executor.setGasBalance(addr, std.math.maxInt(u64));
    try std.testing.expectError(error.Overflow, executor.creditGasBalance(addr, 1));
    try std.testing.expectEqual(std.math.maxInt(u64), executor.getGasBalance(addr));
}

test "gas payer with enough balance succeeds and balance decreases" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();
    executor.enforce_gas_payment = true;

    const sender: [32]u8 = @splat(0x11);
    try executor.setGasBalance(sender, 10_000);

    const tx = Ingress.Transaction{
        .sender = sender,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 1,
    };
    const result = try executor.execute(tx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(ExecutionStatus.success, result.status);
    try std.testing.expect(result.gas_used > 0);
    try std.testing.expectEqual(10_000 - result.gas_used, executor.getGasBalance(sender));
}

test "gas payer with insufficient balance fails without success" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();
    executor.enforce_gas_payment = true;

    const sender: [32]u8 = @splat(0x22);
    // Unset address → 0; also cover explicit low balance
    try executor.setGasBalance(sender, 0);

    const tx = Ingress.Transaction{
        .sender = sender,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 },
        .gas_budget = 1000,
        .sequence = 1,
    };
    const result = try executor.execute(tx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(ExecutionStatus.insufficient_gas_funds, result.status);
    try std.testing.expectEqual(@as(u64, 0), result.gas_used);
    try std.testing.expectEqual(@as(u64, 0), executor.getGasBalance(sender));
}

test "sponsored gas deducts from payer not sender" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();
    executor.enforce_gas_payment = true;

    const sender: [32]u8 = @splat(0x33);
    const payer: [32]u8 = @splat(0x44);
    try executor.setGasBalance(sender, 50_000);
    try executor.setGasBalance(payer, 10_000);

    const tx = Ingress.Transaction{
        .sender = sender,
        .payer = payer,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 },
        .gas_budget = 1000,
        .sequence = 1,
    };
    const result = try executor.execute(tx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(ExecutionStatus.success, result.status);
    try std.testing.expect(result.gas_used > 0);
    try std.testing.expectEqual(@as(u64, 50_000), executor.getGasBalance(sender));
    try std.testing.expectEqual(10_000 - result.gas_used, executor.getGasBalance(payer));
}

test "failed execution keeps the transaction digest" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    const invalid = Ingress.Transaction{
        .sender = @as([32]u8, @splat(0x42)),
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 1000,
        .sequence = 3,
    };
    const invalid_result = try executor.execute(invalid);
    defer invalid_result.deinit(allocator);
    try std.testing.expectEqual(ExecutionStatus.invalid_bytecode, invalid_result.status);
    try std.testing.expectEqualSlices(u8, &invalid.digest(), &invalid_result.digest);

    const trapped = Ingress.Transaction{
        .sender = @as([32]u8, @splat(0x43)),
        .inputs = &.{},
        .program = &.{0x10},
        .gas_budget = 1000,
        .sequence = 4,
    };
    const trapped_result = try executor.execute(trapped);
    defer trapped_result.deinit(allocator);
    try std.testing.expectEqual(ExecutionStatus.resource_error, trapped_result.status);
    try std.testing.expectEqualSlices(u8, &trapped.digest(), &trapped_result.digest);
}

test "executor binds the epoch timestamp instead of the host clock" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();
    executor.setEpoch(9, 1_700_000_000_000);

    const tx = Ingress.Transaction{
        .sender = @as([32]u8, @splat(0xAB)),
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 100,
        .sequence = 1,
    };
    var fallback: TxContext = undefined;
    const ctx = executor.bindContext(tx, null, &fallback);
    try std.testing.expectEqual(@as(u64, 9), ctx.epoch);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000), ctx.epoch_timestamp_ms);
}

test "executor setEpoch advances marketplace and agent clocks" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    var mp = try Marketplace.init(allocator);
    defer mp.deinit();
    var am = try AgentMessaging.init(allocator);
    defer am.deinit();
    var reg = try AgentRegistry.init(allocator);
    defer reg.deinit();
    executor.marketplace = mp;
    executor.agent_messaging = am;
    executor.agent_registry = reg;

    executor.setEpoch(3, 1_700_000_000_000);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), mp.clock_sec);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), am.clock_sec);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), reg.clock_sec);
}

test "executor keeps event bytes after the interpreter is destroyed" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    const reg = try allocator.create(Registry);
    reg.* = Registry.init(allocator);
    executor.registry = reg;
    try reg.registerSuiFramework();

    // ld_u64 0x11, 0x22, 0x33, count=3; vec_pack; sui::event::emit; ret
    const program = [_]u8{
        0x34, 0x11, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x22, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x33, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x03, 0,   0,   0,    0,    0,    0,   0,
        0x93, 0x03, 0,   0,   0,    0xA0, 0x03, 's', 'u',
        'i',  0x0B, 'e', 'v', 'e',  'n',  't',  ':', ':',
        'e',  'm',  'i', 't', 0x01, 0x01,
    };
    const tx = Ingress.Transaction{
        .sender = @as([32]u8, @splat(0x11)),
        .inputs = &.{},
        .program = &program,
        .gas_budget = 10_000,
        .sequence = 1,
    };
    const result = try executor.execute(tx);
    defer result.deinit(allocator);

    const scratch = try allocator.alloc(u8, 64);
    defer allocator.free(scratch);
    @memset(scratch, 0xAB);
    try std.testing.expectEqual(@as(usize, 1), result.events.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33 }, result.events[0].payload);
}

test "executor copies transfer effects instead of aliasing them" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    var effect = ObjectEffect{
        .kind = .transfer,
        .object_id = @as([32]u8, @splat(0x44)),
        .recipient = @as([32]u8, @splat(0x55)),
    };
    const owned = try executor.copyVmEffects(&.{}, &.{}, &.{effect});
    defer {
        const wrapped = ExecutionResult{
            .digest = @as([32]u8, @splat(0)),
            .status = .success,
            .gas_used = 0,
            .output_objects = owned.output_objects,
            .events = owned.events,
            .object_effects = owned.object_effects,
        };
        wrapped.deinit(allocator);
    }
    effect.recipient = @as([32]u8, @splat(0));
    try std.testing.expectEqual(ObjectEffect.Kind.transfer, owned.object_effects[0].kind);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x55)), &owned.object_effects[0].recipient);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x44)), &owned.object_effects[0].object_id);
}

test "pre-execution cache frees replaced results and hands one result to the caller" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    const reg = try allocator.create(Registry);
    reg.* = Registry.init(allocator);
    executor.registry = reg;
    try reg.registerSuiFramework();

    const program = [_]u8{
        0x34, 0x11, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x22, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x33, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x03, 0,   0,   0,    0,    0,    0,   0,
        0x93, 0x03, 0,   0,   0,    0xA0, 0x03, 's', 'u',
        'i',  0x0B, 'e', 'v', 'e',  'n',  't',  ':', ':',
        'e',  'm',  'i', 't', 0x01, 0x01,
    };
    const tx = Ingress.Transaction{
        .sender = @as([32]u8, @splat(0x11)),
        .inputs = &.{},
        .program = &program,
        .gas_budget = 10_000,
        .sequence = 1,
    };
    const block_a: [32]u8 = @splat(0xA1);
    const block_b: [32]u8 = @splat(0xB2);
    try executor.preExecuteBlock(block_a, &.{tx});
    try executor.preExecuteBlock(block_a, &.{tx});
    const taken = executor.takePreExecuted(block_a, 0) orelse return error.MissingCachedResult;
    defer taken.deinit(allocator);
    try std.testing.expect(executor.takePreExecuted(block_a, 0) == null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33 }, taken.events[0].payload);

    try executor.preExecuteBlock(block_b, &.{tx});
    try std.testing.expectEqual(@as(usize, 1), executor.pre_exec_cache.count());
}

test "ordered batches return distinct caller-owned results" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 1, .use_block_stm = true });
    defer executor.deinit();

    const reg = try allocator.create(Registry);
    reg.* = Registry.init(allocator);
    executor.registry = reg;
    try reg.registerSuiFramework();

    const program = [_]u8{
        0x34, 0x11, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x22, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x33, 0,   0,   0,    0,    0,    0,   0,
        0x34, 0x03, 0,   0,   0,    0,    0,    0,   0,
        0x93, 0x03, 0,   0,   0,    0xA0, 0x03, 's', 'u',
        'i',  0x0B, 'e', 'v', 'e',  'n',  't',  ':', ':',
        'e',  'm',  'i', 't', 0x01, 0x01,
    };
    const tx = Ingress.Transaction{
        .sender = @as([32]u8, @splat(0x11)),
        .inputs = &.{},
        .program = &program,
        .gas_budget = 10_000,
        .sequence = 1,
    };
    const first = try executor.executeOrdered(&.{tx});
    const second = try executor.executeOrdered(&.{tx});
    defer {
        for (second) |res| res.deinit(allocator);
        allocator.free(second);
    }
    defer {
        for (first) |res| res.deinit(allocator);
        allocator.free(first);
    }
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33 }, first[0].events[0].payload);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33 }, second[0].events[0].payload);
    try std.testing.expect(first[0].events[0].payload.ptr != second[0].events[0].payload.ptr);
}

test "WorkerPool init deinit" {
    const allocator = std.testing.allocator;
    var pool = try WorkerPool.init(allocator, 2);
    try pool.start();
    try std.testing.expect(pool.started);
    try std.testing.expectEqual(@as(usize, 2), pool.size);
    pool.deinit(allocator);
}

test "Executor parallelism" {
    const allocator = std.testing.allocator;
    // Force graph path so WorkerPool.submit is exercised.
    var executor = try Executor.init(allocator, .{ .parallelism = 4, .use_block_stm = false });
    defer executor.deinit();

    try std.testing.expect(executor.getParallelism() == 4);
    try std.testing.expect(executor.worker_pool != null);

    var txs: [8]Ingress.Transaction = undefined;
    for (&txs, 0..) |*tx, i| {
        tx.* = .{
            .sender = @as([32]u8, @splat(@as(u8, @intCast(i + 1)))),
            .inputs = &.{},
            .program = &.{ 0x31, 0x01 }, // ld_true; ret
            .gas_budget = 1000,
            .sequence = @intCast(i),
        };
    }
    const results = try executor.executeBatch(&txs);
    defer {
        for (results) |r| r.deinit(allocator);
        allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 8), results.len);
    for (results) |r| {
        try std.testing.expectEqual(ExecutionStatus.success, r.status);
        try std.testing.expect(r.gas_used > 0);
    }
}

test "Block-STM path uses WorkerPool" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 4, .use_block_stm = true });
    defer executor.deinit();

    try std.testing.expect(executor.worker_pool != null);
    const pool_size = executor.worker_pool.?.size;
    try std.testing.expectEqual(@as(usize, 4), pool_size);

    // n >= 4 keeps the Block-STM path (submitRetryWave) rather than graph fallback.
    var txs: [8]Ingress.Transaction = undefined;
    for (&txs, 0..) |*tx, i| {
        tx.* = .{
            .sender = @as([32]u8, @splat(@as(u8, @intCast(i + 1)))),
            .inputs = &.{},
            .program = &.{ 0x31, 0x01 }, // ld_true; ret
            .gas_budget = 1000,
            .sequence = @intCast(i),
        };
    }
    const results = try executor.executeBatch(&txs);
    defer {
        for (results) |r| r.deinit(allocator);
        allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 8), results.len);
    for (results) |r| {
        try std.testing.expectEqual(ExecutionStatus.success, r.status);
        try std.testing.expect(r.gas_used > 0);
    }
    // Pool survives the wave (no tear-down / recreate on submit).
    try std.testing.expect(executor.worker_pool != null);
    try std.testing.expectEqual(pool_size, executor.worker_pool.?.size);
}

test "adaptParallelism scale-up grows WorkerPool" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 2 });
    defer executor.deinit();

    try std.testing.expectEqual(@as(usize, 2), executor.getParallelism());
    try std.testing.expect(executor.worker_pool != null);
    try std.testing.expectEqual(@as(usize, 2), executor.worker_pool.?.size);

    // pending > parallelism * 100 → +1 config and recreate pool at new size.
    executor.adaptParallelism(2 * 100 + 1);
    try std.testing.expectEqual(@as(usize, 3), executor.getParallelism());
    try std.testing.expect(executor.worker_pool != null);
    try std.testing.expectEqual(@as(usize, 3), executor.worker_pool.?.size);

    // Scale-down only lowers the ceiling; pool size stays.
    executor.adaptParallelism(0);
    try std.testing.expectEqual(@as(usize, 2), executor.getParallelism());
    try std.testing.expectEqual(@as(usize, 3), executor.worker_pool.?.size);
}
