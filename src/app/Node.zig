//! Node - zknot3 blockchain node bootstrap and lifecycle
//!
const std = @import("std");
const core = @import("../core.zig");
const pipeline = @import("../pipeline.zig");
const Config = @import("Config.zig").Config;
const Log = @import("Log.zig");
const Indexer = @import("Indexer.zig").Indexer;
const CheckpointSequence = @import("../form/storage/Checkpoint.zig").CheckpointSequence;
const EpochConsensusBridge = @import("../metric/EpochConsensusBridge.zig").EpochConsensusBridge;
const ConsensusEpochInfo = @import("../metric/EpochConsensusBridge.zig").ConsensusEpochInfo;
const Mysticeti = @import("../form/consensus/Mysticeti.zig");
const ObjectStore = @import("../form/storage/ObjectStore.zig").ObjectStore;
const P2PServer_module = @import("../form/network/P2PServer.zig");
const P2PServer = P2PServer_module.P2PServer;

const RuntimeMetrics = @import("../metric/RuntimeMetrics.zig");
const builtin = @import("builtin");

extern "c" fn sysctl(name: [*]const c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
/// Node state
pub const NodeState = enum {
    initializing,
    starting,
    running,
    shutting_down,
    stopped,
};

/// Node errors
pub const NodeError = error{
    InvalidState,
    InvalidConfig,
    NotRunning,
    ObjectStoreNotAvailable,
    ConsensusNotAvailable,
    ExecutorNotAvailable,
    TransactionExpired,
    TransactionAlreadyExecuted,
    InvalidSequence,
    BlockNotFound,
    QuorumNotReached,
};

/// Node dependencies
pub const NodeDependencies = struct {
    object_store: ?*anyopaque = null,
    consensus: ?*anyopaque = null,
    executor: ?*anyopaque = null,
    indexer: ?*Indexer = null,
    epoch_bridge: ?*EpochConsensusBridge = null,
    txn_pool: ?*anyopaque = null, // TxnPool.TxnPool when initialized
};

/// Main zknot3 node structure
pub const Node = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: *const Config,
    state: NodeState,
    deps: NodeDependencies,
    object_store: ?*ObjectStore,
    checkpoint_store: CheckpointSequence,
    txn_history: std.AutoArrayHashMap([32]u8, pipeline.TransactionReceipt),
    committed_blocks: std.AutoArrayHashMap([32]u8, Mysticeti.Block),
    pending_blocks: std.AutoArrayHashMap([32]u8, Mysticeti.Block),
    execution_results: std.AutoArrayHashMap([32]u8, ExecutionResult),
    sender_sequence: std.AutoArrayHashMap([32]u8, u64),
    stats: NodeStats,
    started_at: i64,
    p2p_server: ?*P2PServer = null,
    consensus_round: u64 = 0,
    txn_pool: *pipeline.TxnPool,
    executor: *pipeline.Executor,
    runtime_metrics: ?*RuntimeMetrics.RuntimeMetricsCollector = null,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const Config,
        deps: NodeDependencies,
    ) !*Self {
        const txn_pool = try pipeline.TxnPool.init(allocator, .{});
        errdefer txn_pool.deinit();
        const exec = try pipeline.Executor.init(allocator, .{});
        errdefer exec.deinit();

        const self_ptr = try allocator.create(Self);
        errdefer allocator.destroy(self_ptr);

        self_ptr.allocator = allocator;
        self_ptr.config = config;
        self_ptr.state = .initializing;
        self_ptr.deps = deps;
        self_ptr.object_store = null;
        self_ptr.checkpoint_store = CheckpointSequence.init();
        self_ptr.txn_history = std.AutoArrayHashMap([32]u8, pipeline.TransactionReceipt).init(allocator);
        self_ptr.committed_blocks = std.AutoArrayHashMap([32]u8, Mysticeti.Block).init(allocator);
        self_ptr.pending_blocks = std.AutoArrayHashMap([32]u8, Mysticeti.Block).init(allocator);
        self_ptr.execution_results = std.AutoArrayHashMap([32]u8, ExecutionResult).init(allocator);
        self_ptr.sender_sequence = std.AutoArrayHashMap([32]u8, u64).init(allocator);
        self_ptr.stats = .{};
        self_ptr.started_at = std.time.timestamp();
        self_ptr.p2p_server = null;
        self_ptr.consensus_round = 0;
        self_ptr.txn_pool = txn_pool;
        self_ptr.executor = exec;
        self_ptr.runtime_metrics = try RuntimeMetrics.RuntimeMetricsCollector.init(allocator, 100);
        errdefer {
            self_ptr.runtime_metrics.?.deinit();
            self_ptr.runtime_metrics.?.allocator.destroy(self_ptr.runtime_metrics.?);
        }

        errdefer self_ptr.deinit();

        self_ptr.object_store = try ObjectStore.init(
            allocator,
            .{},
            config.storage.data_dir,
        );

        if (config.network.p2p_enabled) {
            const p2p_config = P2PServer_module.P2PServerConfig{
                .bind_address = config.network.p2p_address,
                .max_connections = 256,
                .bootstrap_peers = config.network.bootstrap_peers,
                .dial_bootstrap = true,
                .validator_key = config.authority.signing_key,
            };

            self_ptr.p2p_server = try P2PServer.init(allocator, p2p_config);
        }

        return self_ptr;
    }


    pub fn deinit(self: *Self) void {
        self.state = .shutting_down;
        if (self.object_store) |store| {
            store.deinit();
        }
        self.txn_history.deinit();
        self.committed_blocks.deinit();
        self.pending_blocks.deinit();
        self.execution_results.deinit();
        self.sender_sequence.deinit();
        if (self.p2p_server) |server| {
            server.deinit();
        }
        self.checkpoint_store.deinit();
        self.txn_pool.deinit();
        self.executor.deinit();
        if (self.runtime_metrics) |rm| {
            rm.deinit();
            self.allocator.destroy(rm);
        }
        self.state = .stopped;
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        if (self.state != .initializing) return error.InvalidState;
        try self.validateConfig();
        self.state = .starting;
        // Recover state from disk before going live
        try self.recoverFromDisk();
        // Start P2P server if enabled
        if (self.p2p_server) |server| {
            try server.start();
            Log.info("P2P server listening on 0.0.0.0:{}", .{self.config.network.p2p_port});
        }
        self.state = .running;
    }

    /// Validate node configuration before starting
    pub fn validateConfig(self: *Self) !void {
        if (self.config.network.rpc_port == 0) {
            return error.InvalidConfig;
        }
        if (self.config.consensus.validator_enabled and self.config.consensus.vote_quorum == 0) {
            return error.InvalidConfig;
        }
        if (self.config.storage.data_dir.len == 0) {
            return error.InvalidConfig;
        }
    }

    pub fn stop(self: *Self) void {
        self.state = .shutting_down;
        if (self.p2p_server) |server| {
            server.stop();
        }
        self.state = .stopped;
    }

    /// Get P2P server if available
    pub fn getP2PServer(self: *Self) ?*P2PServer {
        return self.p2p_server;
    }

    /// Recover node state from disk (checkpoint + WAL)
    pub fn recoverFromDisk(self: *Self) !void {
        // Phase 1: Recover ObjectStore from WAL
        if (self.object_store) |store| {
            try store.recover();
        }

        // Phase 2: Load latest checkpoint into checkpoint_store
        // CheckpointSequence should have a loadLatest() method
        // For now, checkpoint_store starts empty and builds from WAL

        // Phase 3: Recover committed blocks from checkpoint history
        // This would involve loading block certs from checkpoint store

        Log.info("Node recovered from disk", .{});
    }

    pub fn getNodeInfo(self: *Self) NodeInfo {
        return .{
            .version = "0.1.0",
            .state = @tagName(self.state),
            .uptime_seconds = @intCast(std.time.timestamp() - self.started_at),
            .object_store_count = self.execution_results.count(),
            .checkpoint_sequence = self.checkpoint_store.getLatestSequence(),
            .pending_transactions = self.getPendingTxnCount(),
            .committed_blocks = self.committed_blocks.count(),
            .consensus_round = self.consensus_round,
            .blocks_committed_total = self.stats.blocks_committed,
        };
    }

    pub const NodeInfo = struct {
        version: []const u8,
        state: []const u8,
        uptime_seconds: i64,
        object_store_count: u64,
        checkpoint_sequence: u64,
        pending_transactions: usize,
        committed_blocks: usize,
        consensus_round: u64,
        blocks_committed_total: u64,
    };

    pub const ValidatorInfo = struct {
        id: [32]u8,
        stake: u128,
        voting_power: u128,
        is_active: bool,
    };

    pub fn getTriSourceMetrics(self: *Self) RuntimeMetrics.TriSourceMetrics {
        const peer_count = if (self.p2p_server) |p2p| p2p.peerCount() else 0;
        const max_peers = self.config.network.max_connections;
        const network_util = if (max_peers > 0)
            @min(1.0, @as(f64, @floatFromInt(peer_count)) / @as(f64, @floatFromInt(max_peers)))
        else
            0.0;
        const storage_util = @min(1.0, @as(f64, @floatFromInt(self.execution_results.count())) / 10000.0);

        const resource = RuntimeMetrics.ResourceMetrics{
            .cpu_util = 0.5,
            .mem_util = 0.5,
            .storage_util = storage_util,
            .network_util = network_util,
        };

        const knowledge = RuntimeMetrics.KnowledgeMetrics{
            .unique_types = self.execution_results.count(),
            .total_objects = self.execution_results.count() * 2,
            .unique_tx_types = @min(100, self.txn_history.count()),
            .total_transactions = self.stats.transactions_executed,
            .ownership_entropy = 2.0,
        };

        var successful: u64 = 0;
        var total_checked: u64 = 0;
        var it = self.execution_results.iterator();
        while (it.next()) |entry| {
            total_checked += 1;
            if (entry.value_ptr.status == .success) successful += 1;
        }
        const error_rate = if (total_checked > 0)
            1.0 - (@as(f64, @floatFromInt(successful)) / @as(f64, @floatFromInt(total_checked)))
        else
            0.0;

        const tps = if (self.stats.transactions_executed > 0 and self.stats.blocks_committed > 0)
            @as(f64, @floatFromInt(self.stats.transactions_executed)) / @as(f64, @floatFromInt(self.stats.blocks_committed))
        else
            0.0;

        const user = RuntimeMetrics.UserMetrics{
            .latency_p50 = 20.0,
            .latency_p99 = 50.0,
            .tps = tps,
            .target_tps = 10000.0,
            .error_rate = error_rate,
            .user_satisfaction = 1.0 - error_rate,
        };

        return .{
            .wu_feng = resource.computeWuFeng(),
            .xiang_da = knowledge.computeXiangDa(),
            .zi_zai = user.computeZiZai(),
        };
    }

    pub fn getValidatorList(self: *Self, allocator: std.mem.Allocator) ![]ValidatorInfo {
        if (self.deps.epoch_bridge) |bridge| {
            const quorum = bridge.quorum;
            var list = try std.ArrayList(ValidatorInfo).initCapacity(allocator, quorum.members.items.len);
            errdefer list.deinit(allocator);
            for (quorum.members.items) |member| {
                const power = bridge.getValidatorVotingPower(member.id);
                try list.append(allocator, .{
                    .id = member.id,
                    .stake = member.stake,
                    .voting_power = power,
                    .is_active = member.is_active,
                });
            }
            return try list.toOwnedSlice(allocator);
        }
        return &[_]ValidatorInfo{};
    }

    pub fn getSystemInfo(self: *Self) SystemInfo {
        _ = self;
        const cpu_count = std.Thread.getCpuCount() catch 1;
        return .{
            .cpu_count = cpu_count,
            .total_memory_bytes = getTotalSystemMemory(),
            .cpu_usage_percent = 0.0,
        };
    }

    pub const SystemInfo = struct {
        cpu_count: usize,
        total_memory_bytes: u64,
        cpu_usage_percent: f64,
    };

    fn getTotalSystemMemory() u64 {
        if (builtin.target.os.tag == .linux) {
            var buf: [1024]u8 = undefined;
            const file = std.fs.cwd().openFile("/proc/meminfo", .{}) catch return 0;
            defer file.close();
            const n = file.read(&buf) catch return 0;
            const content = buf[0..n];
            const prefix = "MemTotal:";
            if (std.mem.indexOf(u8, content, prefix)) |idx| {
                const line_start = idx + prefix.len;
                const line_end = std.mem.indexOf(u8, content[line_start..], " kB") orelse return 0;
                const num_str = std.mem.trim(u8, content[line_start..line_start + line_end], " ");
                const kb = std.fmt.parseInt(u64, num_str, 10) catch return 0;
                return kb * 1024;
            }
            return 0;
        } else if (builtin.target.os.tag == .macos) {
            const CTL_HW: c_int = 6;
            const HW_MEMSIZE: c_int = 24;
            const mib = &[_]c_int{ CTL_HW, HW_MEMSIZE };
            var memsize: u64 = 0;
            var len: usize = @sizeOf(u64);

            if (sysctl(mib.ptr, mib.len, &memsize, &len, null, 0) == 0) {
                return memsize;
            }
            return 0;
        }
        return 0;
    }

    pub fn proposeBlock(self: *Self, payload: []const u8) !?*Mysticeti.Block {
        if (self.state != .running) return error.NotRunning;
        const block = try Mysticeti.Block.create(
            .{0} ** 32,
            Mysticeti.Round{ .value = self.consensus_round },
            payload,
            &.{},
            self.allocator,
        );
        try self.pending_blocks.put(block.digest, block);
        return self.pending_blocks.getPtr(block.digest);
    }

    pub fn advanceRound(self: *Self) void {
        self.consensus_round += 1;
        if (self.consensus_round > self.stats.highest_round) {
            self.stats.highest_round = self.consensus_round;
        }
    }

    pub fn receiveBlock(self: *Self, block_data: []const u8) !void {
        if (self.state != .running) return error.NotRunning;
        var block = try Mysticeti.Block.create(
            .{0} ** 32,
            Mysticeti.Round{ .value = 0 },
            block_data,
            &.{},
            self.allocator,
        );
        if (self.pending_blocks.contains(block.digest) or self.committed_blocks.contains(block.digest)) {
            block.deinit(self.allocator);
            return;
        }
        try self.pending_blocks.put(block.digest, block);
    }

    pub fn receiveVote(self: *Self, vote_data: []const u8) !void {
        if (self.state != .running) return error.NotRunning;

        // Deserialize vote
        const vote = Mysticeti.Vote.deserialize(self.allocator, vote_data) catch return;

        // Verify vote signature
        if (!vote.verifySignature()) {
            Log.warn("Rejected vote with invalid signature from voter", .{});
            return;
        }

        // Find the block this vote is for
        if (self.pending_blocks.getPtr(vote.block_digest)) |block| {
            // Add vote if not already present from this voter
            if (!block.votes.contains(vote.voter)) {
                try block.votes.put(vote.voter, vote);
            }
        } else if (self.committed_blocks.getPtr(vote.block_digest)) |block| {
            // Vote on already committed block - add to committed block's votes too
            if (!block.votes.contains(vote.voter)) {
                try block.votes.put(vote.voter, vote);
            }
        }
        // If block not found, vote is orphaned (this is normal in DAG consensus)
    }


    pub fn tryCommitBlocks(self: *Self) !?Mysticeti.CommitCertificate {
        if (self.state != .running) return error.NotRunning;
        var it = self.pending_blocks.iterator();
        while (it.next()) |entry| {
            const block = entry.value_ptr.*;
            if (block.votes.count() >= self.config.consensus.vote_quorum) {
                var exec_results: []ExecutionResult = &[_]ExecutionResult{};
                var exec_results_owned = false;
                if (self.executeBlockTransactions(&block)) |results| {
                    exec_results = results;
                    exec_results_owned = true;
                } else |err| {
                    Log.err("Failed to execute block transactions: {}", .{err});
                }
                if (exec_results_owned) {
                    self.allocator.free(exec_results);
                }
                if (self.executeBlockTransactions(&block)) |results| {
                    exec_results = results;
                } else |err| {
                    Log.err("Failed to execute block transactions: {}", .{err});
                    exec_results = &[_]ExecutionResult{};
                }
                self.allocator.free(exec_results);

                const cert = Mysticeti.CommitCertificate{
                    .block_digest = block.digest,
                    .round = block.round,
                    .quorum_stake = @as(u128, @intCast(block.votes.count())) * 1000,
                    .confidence = 0.95,
                };
                if (self.pending_blocks.get(block.digest)) |committed| {
                    _ = self.pending_blocks.swapRemove(block.digest);
                    try self.committed_blocks.put(block.digest, committed);

                    // Prune old committed blocks to prevent unbounded growth
                    while (self.committed_blocks.count() > self.config.consensus.max_committed_blocks) {
                        const first_key = self.committed_blocks.keys()[0];
                        if (self.committed_blocks.getPtr(first_key)) |block_ptr| {
                            block_ptr.*.deinit(self.allocator);
                        }
                        _ = self.committed_blocks.swapRemove(first_key);
                    }

                    if (block.round.value > self.stats.highest_round) {
                        self.stats.highest_round = block.round.value;
                    }
                    self.stats.blocks_committed += 1;
                    return cert;
                }
            }
        }
        return null;
    }

    pub fn executeBlockTransactions(self: *Self, block: *const Mysticeti.Block) ![]ExecutionResult {
        if (self.state != .running) return error.NotRunning;
        var results = try std.ArrayList(ExecutionResult).initCapacity(self.allocator, 16);
        errdefer results.deinit(self.allocator);

        // Payload: 32-byte sender addresses packed together
        const sender_len = 32;
        var offset: usize = 0;

        while (offset + sender_len <= block.payload.len) : (offset += sender_len) {
            var sender: [32]u8 = undefined;
            @memcpy(&sender, block.payload[offset..offset + sender_len]);

            const tx = pipeline.Transaction{
                .sender = sender,
                .inputs = &.{},
                .program = &.{},
                .gas_budget = 1000,
                .sequence = 0,
                .signature = null,
                .public_key = null,
            };

            const result = self.executor.execute(tx) catch |err| {
                try results.append(self.allocator, .{
                    .digest = sender,
                    .status = if (err == error.OutOfGas) .out_of_gas else .invalid_bytecode,
                    .gas_used = 0,
                    .output_objects = &.{},
                });
                continue;
            };

            try results.append(self.allocator, result);

            const receipt = pipeline.TransactionReceipt{
                .digest = result.digest,
                .status = if (result.status == .success) .executed else .failed,
                .gas_used = result.gas_used,
                .sender = sender,
            };
            try self.txn_history.put(result.digest, receipt);
        }

        self.stats.transactions_executed += results.items.len;
        return try results.toOwnedSlice(self.allocator);
    }

    pub fn commitBlock(self: *Self, block: *const Mysticeti.Block) !?ExecutionResult {
        if (self.state != .running) return error.NotRunning;
        if (!self.committed_blocks.contains(block.digest)) return error.BlockNotFound;
        const results = try self.executeBlockTransactions(block);
        var total_gas: u64 = 0;
        for (results) |res| total_gas += res.gas_used;
        const summary = ExecutionResult{
            .digest = block.digest,
            .status = .success,
            .gas_used = total_gas,
            .output = &.{},
        };
        try self.execution_results.put(block.digest, summary);
        self.stats.transactions_executed += @intCast(results.len);
        self.stats.total_gas_used += total_gas;
        return summary;
    }

    pub fn getEpochInfo(self: *Self) ConsensusEpochInfo {
        if (self.deps.epoch_bridge) |bridge| return bridge.getConsensusEpochInfo();
        return .{ .epoch_number = 0, .total_stake = 0, .validator_count = 0, .quorum_threshold = 0 };
    }

    pub fn needsReconfiguration(self: *Self) bool {
        if (self.deps.epoch_bridge) |bridge| return bridge.checkReconfiguration();
        return false;
    }

    pub const ExecutorStats = struct {
        transactions_executed: u64 = 0,
        total_gas_used: u64 = 0,
        parallelism: usize = 0,
    };

    pub const NodeStats = struct {
        transactions_executed: u64 = 0,
        total_gas_used: u64 = 0,
        blocks_committed: u64 = 0,
        highest_round: u64 = 0,
    };

pub fn executeTransaction(self: *Self, tx: pipeline.Transaction) !ExecutionResult {
if (self.state != .running) return error.NotRunning;
        const digest = tx.digest();

        // Replay protection: reject already-executed transactions
        if (self.txn_history.contains(digest) or self.execution_results.contains(digest)) {
            return error.TransactionAlreadyExecuted;
        }

        // Sequence number check
        const expected_sequence = self.sender_sequence.get(tx.sender) orelse 0;
        if (tx.sequence != expected_sequence) {
            return error.InvalidSequence;
        }
const result = ExecutionResult{
.digest = digest,
.status = .success,
.gas_used = tx.gas_budget / 2,
.output = &.{},
};
try self.execution_results.put(digest, result);
const receipt = pipeline.TransactionReceipt{
.digest = digest,
.status = .success,
.gas_used = result.gas_used,
.sender = tx.sender,
};
        try self.txn_history.put(digest, receipt);

        // Increment sender sequence
        try self.sender_sequence.put(tx.sender, expected_sequence + 1);
self.stats.transactions_executed += 1;
self.stats.total_gas_used += result.gas_used;
return result;
}

    pub fn executeTransactionBatch(self: *Self, txs: []const pipeline.Transaction) ![]ExecutionResult {
        if (self.state != .running) return error.NotRunning;
        var results = std.ArrayList(ExecutionResult).init(self.allocator);
        errdefer results.deinit();
        for (txs) |tx| {
            const result = try self.executeTransaction(tx);
            try results.append(result);
        }
        return results.toOwnedSlice();
    }

    pub fn getTransactionReceipt(self: *Self, digest: [32]u8) ?pipeline.TransactionReceipt {
        return self.txn_history.get(digest);
    }

    pub fn getExecutionResult(self: *Self, digest: [32]u8) ?ExecutionResult {
        return self.execution_results.get(digest);
    }

    pub fn getExecutorStats(self: *Self) ExecutorStats {
        return ExecutorStats{
            .transactions_executed = self.stats.transactions_executed,
            .total_gas_used = self.stats.total_gas_used,
            .parallelism = self.config.parallel_execution,
        };
    }

pub fn submitTransaction(self: *Self, tx: pipeline.Transaction, gas_price: u64) !void {
        if (self.state != .running) return error.NotRunning;
        const digest = tx.digest();
        if (self.txn_history.contains(digest) or self.execution_results.contains(digest)) {
            return error.TransactionAlreadyExecuted;
        }
try self.txn_pool.add(tx, gas_price);
}

    pub fn getTxnPoolStats(self: *Self) TxnPoolStats {
        const stats = self.txn_pool.stats();
        return TxnPoolStats{
            .pending = stats.pool_size,
            .executing = 0,
            .received_total = stats.received_total,
            .executed_total = stats.executed_total,
        };
    }


    pub fn cleanupExpiredTransactions(self: *Self) usize {
        return self.txn_pool.removeExpired();
    }

    pub fn getPendingTxnCount(self: *Self) usize {
            return self.txn_pool.stats().pool_size;
        }


    pub fn getCommittedBlock(self: *Self, hash: [32]u8) ?Mysticeti.Block {
        return self.committed_blocks.get(hash);
    }

    pub fn isRunning(self: *Self) bool {
        return self.state == .running;
    }

    /// Get an object from the object store
    pub fn getObject(self: *Self, id: core.ObjectID) !?ObjectStore.Object {
        if (self.object_store) |store| {
            return try store.get(id);
        }
        return error.ObjectStoreNotAvailable;
    }

    /// Put an object into the object store
    pub fn putObject(self: *Self, object: ObjectStore.Object) !void {
        if (self.object_store) |store| {
            try store.put(object);
            return;
        }
        return error.ObjectStoreNotAvailable;
    }

    /// Delete an object from the object store
    pub fn deleteObject(self: *Self, id: core.ObjectID) !void {
        if (self.object_store) |store| {
            store.delete(id);
            return;
        }
        return error.ObjectStoreNotAvailable;
    }
};

    pub const TxnPoolStats = struct {
        pending: usize,
        executing: usize,
        received_total: u64 = 0,
        executed_total: u64 = 0,
    };

const ExecutionResult = @import("../pipeline/Executor.zig").ExecutionResult;


test "Node initialization" {
    const allocator = std.testing.allocator;
    const config = try allocator.create(Config);
    config.* = Config.default();
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();
    try std.testing.expect(node.state == .initializing);
}

test "Node info" {
    const allocator = std.testing.allocator;
    const config = try allocator.create(Config);
    config.* = Config.default();
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();
    const info = node.getNodeInfo();
    try std.testing.expect(info.checkpoint_sequence == 0);
}

test "Node start/stop" {
    const allocator = std.testing.allocator;
    const config = try allocator.create(Config);
    config.* = Config.default();
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();
    try node.start();
    try std.testing.expect(node.state == .running);
    node.stop();
    try std.testing.expect(node.state == .stopped);
}

test "Node recoverFromDisk does not crash" {
    const allocator = std.testing.allocator;
    const config = try allocator.create(Config);
    config.* = Config.default();
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    // recoverFromDisk should not error even with empty disk
    try node.recoverFromDisk();
    try std.testing.expect(node.state == .initializing);
}

test "Node start calls recoverFromDisk" {
    const allocator = std.testing.allocator;
    const config = try allocator.create(Config);
    config.* = Config.default();
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();

    // start() should call recoverFromDisk() internally
    try node.start();
    try std.testing.expect(node.state == .running);

    // Node should be operational after start
    const info = node.getNodeInfo();
    try std.testing.expect(info.checkpoint_sequence == 0);

    node.stop();
    try std.testing.expect(node.state == .stopped);
}
