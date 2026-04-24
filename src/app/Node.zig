//! Node - zknot3 blockchain node bootstrap and lifecycle
//!
const std = @import("std");
const core = @import("../core.zig");
const pipeline = @import("../pipeline.zig");
const property = @import("../property.zig");
const Config = @import("Config.zig").Config;
const Log = @import("Log.zig");
const Indexer = @import("Indexer.zig").Indexer;
const CheckpointSequence = @import("../form/storage/Checkpoint.zig").CheckpointSequence;
const EpochManager = @import("../metric/Epoch.zig").EpochManager;
const StakePool = @import("../metric/Stake.zig").StakePool;
const Quorum = @import("../form/consensus/Quorum.zig").Quorum;
const EpochConsensusBridge = @import("../metric/EpochConsensusBridge.zig").EpochConsensusBridge;
const ConsensusEpochInfo = @import("../metric/EpochConsensusBridge.zig").ConsensusEpochInfo;
const Mysticeti = @import("../form/consensus/Mysticeti.zig");
const ObjectStore = @import("../form/storage/ObjectStore.zig").ObjectStore;
const P2PServer_module = @import("../form/network/P2PServer.zig");
const P2PServer = P2PServer_module.P2PServer;
const TxnAdmission = @import("TxnAdmission.zig");
const BlockCommit = @import("BlockCommit.zig");
const BlockExecution = @import("BlockExecution.zig");
const TxExecutionCoordinator = @import("TxExecutionCoordinator.zig");
const NodeStatsCoordinator = @import("NodeStatsCoordinator.zig");
const ConsensusIngressCoordinator = @import("ConsensusIngressCoordinator.zig");
const NodeLifecycleCoordinator = @import("NodeLifecycleCoordinator.zig");
const NodeMetricsCoordinator = @import("NodeMetricsCoordinator.zig");
const ObjectStoreCoordinator = @import("ObjectStoreCoordinator.zig");
const NodeInfoCoordinator = @import("NodeInfoCoordinator.zig");
const TxnPoolCoordinator = @import("TxnPoolCoordinator.zig");
const CommitCoordinator = @import("CommitCoordinator.zig");
const VoteIngressResult = @import("ConsensusIngressCoordinator.zig").VoteIngressResult;
const MainnetExtensionHooks = @import("MainnetExtensionHooks.zig");
const wal_mod = @import("../form/storage/WAL.zig");
const WAL = wal_mod.WAL;
const WalRecordType = wal_mod.WalRecordType;
const SigCrypto = @import("../property/crypto/Signature.zig");
const Bls = core.Bls;

fn appendM4CheckpointProofSig(
    allocator: std.mem.Allocator,
    pairs: *std.ArrayList(MainnetExtensionHooks.ProofSigPair),
    sk: [32]u8,
    proof_bytes: []const u8,
) !void {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(sk);
    const pk = kp.public_key.toBytes();
    var vid: [32]u8 = undefined;
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(&pk);
    h.final(&vid);
    const sig = try SigCrypto.Ed25519.sign(sk, proof_bytes);
    try pairs.append(allocator, .{ .validator_id = vid, .signature = sig });
}

const RuntimeMetrics = @import("../metric/RuntimeMetrics.zig");
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
    InvalidSignature,
    MissingSigningKey,
};

/// Node dependencies
pub const NodeDependencies = struct {
    object_store: ?*anyopaque = null,
    consensus: ?*anyopaque = null,
    executor: ?*anyopaque = null,
    indexer: ?*Indexer = null,
    epoch_bridge: ?*EpochConsensusBridge = null,
    trace_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
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
    txn_history: std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt),
    committed_blocks: std.AutoArrayHashMapUnmanaged([32]u8, Mysticeti.Block),
    pending_blocks: std.AutoArrayHashMapUnmanaged([32]u8, Mysticeti.Block),
    execution_results: std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult),
    sender_sequence: std.AutoArrayHashMapUnmanaged([32]u8, u64),
    stats: NodeStats,
    started_at: i64,
    p2p_server: ?*P2PServer = null,
    consensus_round: u64 = 0,
    txn_pool: *pipeline.TxnPool,
    executor: *pipeline.Executor,
    runtime_metrics: ?*RuntimeMetrics.RuntimeMetricsCollector = null,
    mainnet_hooks: *MainnetExtensionHooks.Manager,
    /// M4 protocol WAL (separate from LSM); optional if init fails.
    m4_wal: ?*WAL = null,
    /// Epoch management (Phase 0: default primary path)
    epoch_manager: ?*EpochManager = null,
    stake_pool: ?*StakePool = null,
    quorum: ?*Quorum = null,
    epoch_bridge: ?*EpochConsensusBridge = null,
    /// Phase 1: optional indexer for object/event queries
    indexer: ?*Indexer = null,
    /// Phase 1: atomic trace ID counter for observability
    trace_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const Config,
        deps: NodeDependencies,
    ) !*Self {
        const txn_pool = try pipeline.TxnPool.init(allocator, .{});
        errdefer txn_pool.deinit();
        const exec = try pipeline.Executor.init(allocator, .{
            .parallelism = config.consensus.max_txs_per_block,
            .max_gas = config.vm.max_gas_budget,
        });
        errdefer exec.deinit();

        // Phase 2: set up native function registry for Move VM
        const vm_registry = try allocator.create(property.move_vm.Registry);
        errdefer allocator.destroy(vm_registry);
        vm_registry.* = property.move_vm.Registry.init(allocator);
        errdefer vm_registry.deinit();
        try vm_registry.registerSuiFramework();
        exec.registry = vm_registry;

        const self_ptr = try allocator.create(Self);
        errdefer allocator.destroy(self_ptr);

        self_ptr.allocator = allocator;
        self_ptr.config = config;
        self_ptr.state = .initializing;
        self_ptr.deps = deps;
        self_ptr.object_store = null;
        const cp_path = try std.fmt.allocPrint(allocator, "{s}/{s}/sequence.bin", .{ config.storage.data_dir, config.storage.checkpoint_store_path });
        defer allocator.free(cp_path);
        self_ptr.checkpoint_store = CheckpointSequence.load(cp_path) catch |err| blk: {
            Log.warn("[WARN] Failed to load checkpoint sequence from {s}: {s}, starting from 0", .{ cp_path, @errorName(err) });
            break :blk CheckpointSequence.init();
        };
        self_ptr.txn_history = std.AutoArrayHashMapUnmanaged([32]u8, pipeline.TransactionReceipt).empty;
        self_ptr.committed_blocks = std.AutoArrayHashMapUnmanaged([32]u8, Mysticeti.Block).empty;
        self_ptr.pending_blocks = std.AutoArrayHashMapUnmanaged([32]u8, Mysticeti.Block).empty;
        self_ptr.execution_results = std.AutoArrayHashMapUnmanaged([32]u8, ExecutionResult).empty;
        self_ptr.sender_sequence = std.AutoArrayHashMapUnmanaged([32]u8, u64).empty;
        self_ptr.stats = .{};
        self_ptr.started_at = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            break :blk (ts.sec);
        };
        self_ptr.p2p_server = null;
        self_ptr.consensus_round = 0;
        self_ptr.txn_pool = txn_pool;
        self_ptr.executor = exec;
        self_ptr.runtime_metrics = try RuntimeMetrics.RuntimeMetricsCollector.init(allocator, 100);
        self_ptr.mainnet_hooks = try MainnetExtensionHooks.Manager.init(allocator);
        errdefer self_ptr.mainnet_hooks.deinit();
        self_ptr.m4_wal = null;
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

        // Phase 0: initialize epoch bridge as the default primary path
        const epoch_manager = try EpochManager.init(allocator, .{
            .duration_seconds = config.consensus.epoch_duration_secs,
            .min_validators = config.consensus.min_validators,
            .max_validators = config.consensus.max_validators,
        }, self_ptr.started_at);
        errdefer epoch_manager.deinit();

        const stake_pool = try StakePool.init(allocator);
        errdefer stake_pool.deinit();

        const quorum = try Quorum.init(allocator);
        errdefer quorum.deinit();

        const epoch_bridge = try EpochConsensusBridge.init(allocator, epoch_manager, stake_pool, quorum);
        errdefer epoch_bridge.deinit();

        // Phase 0: bootstrap validator stake from config known_validators into stake_pool
        for (config.network.known_validators) |kv| {
            if (kv.stake > 0) {
                const pk = std.fmt.parseInt(u256, kv.public_key_hex, 16) catch continue;
                var validator_id: [32]u8 = undefined;
                std.mem.writeInt(u256, &validator_id, pk, .big);
                stake_pool.addStake(validator_id, kv.stake, true) catch continue;
            }
        }

        self_ptr.epoch_manager = epoch_manager;
        self_ptr.stake_pool = stake_pool;
        self_ptr.quorum = quorum;
        self_ptr.epoch_bridge = epoch_bridge;
        self_ptr.deps.epoch_bridge = epoch_bridge;

        // Phase 1: initialize indexer for object/event queries
        const indexer = try Indexer.init(allocator, .{});
        self_ptr.indexer = indexer;
        self_ptr.deps.indexer = indexer;

        const m4_base = try std.fmt.allocPrint(allocator, "{s}/m4_state", .{config.storage.data_dir});
        defer allocator.free(m4_base);
        if (WAL.init(allocator, m4_base)) |wal_val| {
            const m4_wal_ptr = try allocator.create(WAL);
            m4_wal_ptr.* = wal_val;
            self_ptr.m4_wal = m4_wal_ptr;
            self_ptr.mainnet_hooks.setM4Wal(m4_wal_ptr);
        } else |err| {
            Log.warn("M4 WAL init failed: {s}", .{@errorName(err)});
        }

        if (config.network.p2p_enabled) {
            const p2p_config = P2PServer_module.P2PServerConfig{
                .bind_address = config.network.p2p_address,
                .max_connections = 256,
                .bootstrap_peers = config.network.bootstrap_peers,
                .dial_bootstrap = true,
                .validator_key = config.authority.signing_key,
                .allow_unauthenticated_handshake = config.allow_unauthenticated_p2p,
                .max_messages_per_second_per_peer = config.network.p2p_max_messages_per_peer_per_second,
                .max_messages_per_second_per_type = config.network.p2p_max_messages_per_type_per_second,
                .peer_score_ban_threshold = config.network.p2p_peer_score_ban_threshold,
                .peer_ban_seconds = config.network.p2p_peer_ban_seconds,
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
        self.txn_history.deinit(self.allocator);
        var it_exec = self.execution_results.iterator();
        while (it_exec.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.execution_results.deinit(self.allocator);
        var it_committed = self.committed_blocks.iterator();
        while (it_committed.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.committed_blocks.deinit(self.allocator);
        var it_pending = self.pending_blocks.iterator();
        while (it_pending.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.pending_blocks.deinit(self.allocator);
        self.sender_sequence.deinit(self.allocator);
        if (self.p2p_server) |server| {
            server.deinit();
        }
        const cp_path = std.fmt.allocPrint(self.allocator, "{s}/{s}/sequence.bin", .{ self.config.storage.data_dir, self.config.storage.checkpoint_store_path }) catch null;
        if (cp_path) |p| {
            defer self.allocator.free(p);
            self.checkpoint_store.save(p) catch |err| {
                Log.warn("[WARN] Failed to save checkpoint sequence to {s}: {s}", .{ p, @errorName(err) });
            };
        }
        self.checkpoint_store.deinit();
        self.txn_pool.deinit();
        self.executor.deinit();
        self.mainnet_hooks.appendStateSnapshotWal() catch |err| {
            Log.warn("[WARN] Failed to append M4 state snapshot on shutdown: {s}", .{@errorName(err)});
        };
        self.mainnet_hooks.setM4Wal(null);
        if (self.m4_wal) |w| {
            w.deinit();
            self.allocator.destroy(w);
        }
        self.mainnet_hooks.deinit();
        if (self.indexer) |idx| idx.deinit();
        if (self.epoch_bridge) |eb| eb.deinit();
        if (self.quorum) |q| q.deinit();
        if (self.stake_pool) |sp| sp.deinit();
        if (self.epoch_manager) |em| em.deinit();
        if (self.runtime_metrics) |rm| {
            rm.deinit();
            self.allocator.destroy(rm);
        }
        self.state = .stopped;
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        try NodeLifecycleCoordinator.runStart(self);
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
        try NodeLifecycleCoordinator.recoverFromDisk(self.object_store);
        // Phase 2+: replay M4 WAL to restore stake/governance/epoch state
        try self.replayMainnetM4Wal();
    }

    /// Replay M4 extension WAL into `mainnet_hooks` after object-store recovery.
    /// Temporarily clears `m4_wal` on the hooks so replay does not append duplicate records.
    pub fn replayMainnetM4Wal(self: *Self) !void {
        const w = self.m4_wal orelse return;
        self.mainnet_hooks.setM4Wal(null);
        defer self.mainnet_hooks.setM4Wal(w);

        const Cb = struct {
            fn onReplay(op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) !void {
                _ = key;
                const node: *Self = @ptrCast(@alignCast(ctx));
                switch (op) {
                    .m4_stake_operation,
                    .m4_governance_proposal,
                    .m4_governance_status,
                    .m4_governance_vote,
                    .m4_equivocation_evidence,
                    .m4_state_snapshot,
                    .m4_epoch_advance,
                    .m4_validator_set_rotate,
                    => {
                        const payload = value orelse return error.InvalidWalPayload;
                        try node.mainnet_hooks.replayWalExtension(op, payload);
                    },
                    else => {},
                }
            }
        };

        const result = try w.replayWithOptions(Cb.onReplay, self, .{
            .max_record_type = 20,
            .validate_types = true,
            .skip_corrupted = false,
        });
        if (result.errors > 0) return error.ReadFailed;
    }

    pub fn getNodeInfo(self: *Self) NodeInfo {
        const epoch_info = self.getEpochInfo();
        return .{
            .version = "0.1.0",
            .state = @tagName(self.state),
            .uptime_seconds = NodeMetricsCoordinator.computeUptimeSeconds(self.started_at),
            .object_store_count = self.execution_results.count(),
            .checkpoint_sequence = self.checkpoint_store.getLatestSequence(),
            .pending_transactions = self.getPendingTxnCount(),
            .committed_blocks = self.committed_blocks.count(),
            .pending_blocks = self.pending_blocks.count(),
            .consensus_round = self.consensus_round,
            .blocks_committed_total = NodeStatsCoordinator.blocksCommitted(&self.stats),
            .epoch = epoch_info.epoch_number,
            .validator_count = epoch_info.validator_count,
            .total_stake = epoch_info.total_stake,
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
        pending_blocks: usize,
        consensus_round: u64,
        blocks_committed_total: u64,
        epoch: u64,
        validator_count: usize,
        total_stake: u128,
    };

    pub const ValidatorInfo = NodeInfoCoordinator.ValidatorInfo;

    pub fn getTriSourceMetrics(self: *Self) RuntimeMetrics.TriSourceMetrics {
        const peer_count = if (self.p2p_server) |p2p| p2p.peerCount() else 0;
        const max_peers = self.config.network.max_connections;
        const network_util = NodeMetricsCoordinator.computeNetworkUtil(peer_count, max_peers);
        const storage_util = NodeMetricsCoordinator.computeStorageUtil(self.execution_results.count());

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
            .total_transactions = NodeStatsCoordinator.txExecuted(&self.stats),
            .ownership_entropy = 2.0,
        };

        const summary = NodeMetricsCoordinator.summarizeExecutionResults(&self.execution_results);
        const error_rate = NodeMetricsCoordinator.computeErrorRate(summary);
        const stats_snap = NodeStatsCoordinator.snapshot(&self.stats);
        const tps = NodeMetricsCoordinator.computeTps(stats_snap.transactions_executed, stats_snap.blocks_committed);

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
        return NodeInfoCoordinator.getValidatorList(allocator, self.deps.epoch_bridge);
    }

    pub fn getSystemInfo(self: *Self) SystemInfo {
        _ = self;
        return NodeInfoCoordinator.getSystemInfo();
    }

    pub const SystemInfo = NodeInfoCoordinator.SystemInfo;

    pub fn proposeBlock(self: *Self, payload: []const u8) !?*Mysticeti.Block {
        if (self.state != .running) return error.NotRunning;
        const block = try Mysticeti.Block.create(
            .{0} ** 32,
            Mysticeti.Round{ .value = self.consensus_round },
            payload,
            &.{},
            self.allocator,
        );
        if (self.pending_blocks.getPtr(block.digest)) |old| {
            old.*.deinit(self.allocator);
        }
        try self.pending_blocks.put(self.allocator, block.digest, block);
        return self.pending_blocks.getPtr(block.digest);
    }

    pub fn advanceRound(self: *Self) void {
        self.consensus_round += 1;
        NodeStatsCoordinator.onRoundAdvanced(&self.stats, self.consensus_round);
    }

    pub fn receiveBlock(self: *Self, block_data: []const u8) !void {
        if (self.state != .running) return error.NotRunning;

        // Product-grade: prune oldest pending blocks when over limit
        const max_pending = self.config.consensus.max_pending_blocks;
        while (self.pending_blocks.count() >= max_pending) {
            const first_key = self.pending_blocks.keys()[0];
            if (self.pending_blocks.getPtr(first_key)) |block_ptr| {
                block_ptr.*.deinit(self.allocator);
            }
            _ = self.pending_blocks.swapRemove(first_key);
        }

        try ConsensusIngressCoordinator.receiveBlock(
            self.allocator,
            &self.pending_blocks,
            &self.committed_blocks,
            block_data,
        );
    }

    pub fn receiveVote(self: *Self, vote_data: []const u8) !VoteIngressResult {
        if (self.state != .running) return error.NotRunning;
        return try ConsensusIngressCoordinator.receiveVote(
            self.allocator,
            &self.pending_blocks,
            &self.committed_blocks,
            vote_data,
        );
    }

    pub fn tryCommitBlocks(self: *Self) !?Mysticeti.CommitCertificate {
        if (self.state != .running) return error.NotRunning;

        const QuorumExecCtx = struct {
            node: *Self,
        };
        var quorum_ctx = QuorumExecCtx{ .node = self };
        const onQuorumBlock = struct {
            fn call(ctx: *anyopaque, block: *const Mysticeti.Block) void {
                const typed_ctx = @as(*QuorumExecCtx, @ptrCast(@alignCast(ctx)));
                if (typed_ctx.node.executeBlockTransactions(block)) |exec_results| {
                    for (exec_results) |res| {
                        res.deinit(typed_ctx.node.allocator);
                    }
                    typed_ctx.node.allocator.free(exec_results);
                    _ = typed_ctx.node.checkpoint_store.advance();
                    const cp_path = std.fmt.allocPrint(typed_ctx.node.allocator, "{s}/{s}/sequence.bin", .{ typed_ctx.node.config.storage.data_dir, typed_ctx.node.config.storage.checkpoint_store_path }) catch null;
                    if (cp_path) |p| {
                        defer typed_ctx.node.allocator.free(p);
                        typed_ctx.node.checkpoint_store.save(p) catch |err| {
                            Log.warn("[WARN] Failed to save checkpoint sequence: {s}", .{@errorName(err)});
                        };
                    }
                } else |err| {
                    Log.err("Failed to execute block transactions: {}", .{err});
                }
            }
        }.call;

        if (try CommitCoordinator.tryCommitOne(
            self.allocator,
            &self.pending_blocks,
            &self.committed_blocks,
            self.config.consensus.vote_quorum,
            self.config.consensus.max_committed_blocks,
            onQuorumBlock,
            &quorum_ctx,
        )) |outcome| {
            NodeStatsCoordinator.onBlockCommitted(&self.stats, outcome.promoted_round);
            return outcome.cert;
        }

        return null;
    }

    /// Drains up to `max_batch` quorum blocks in a single call, invoking
    /// `on_cert` for each committed certificate. Returns the number of blocks
    /// committed. Used by the adaptive commit loop to avoid one-by-one
    /// drain + scheduler hops under bursty load.
    pub fn tryCommitBlocksBatch(
        self: *Self,
        max_batch: usize,
        on_cert_ctx: *anyopaque,
        on_cert: *const fn (ctx: *anyopaque, cert: Mysticeti.CommitCertificate) anyerror!void,
    ) !usize {
        if (self.state != .running) return error.NotRunning;

        const QuorumExecCtx = struct {
            node: *Self,
        };
        var quorum_ctx = QuorumExecCtx{ .node = self };
        const onQuorumBlock = struct {
            fn call(ctx: *anyopaque, block: *const Mysticeti.Block) void {
                const typed_ctx = @as(*QuorumExecCtx, @ptrCast(@alignCast(ctx)));
                if (typed_ctx.node.executeBlockTransactions(block)) |exec_results| {
                    for (exec_results) |res| {
                        res.deinit(typed_ctx.node.allocator);
                    }
                    typed_ctx.node.allocator.free(exec_results);
                    _ = typed_ctx.node.checkpoint_store.advance();
                    const cp_path = std.fmt.allocPrint(typed_ctx.node.allocator, "{s}/{s}/sequence.bin", .{ typed_ctx.node.config.storage.data_dir, typed_ctx.node.config.storage.checkpoint_store_path }) catch null;
                    if (cp_path) |p| {
                        defer typed_ctx.node.allocator.free(p);
                        typed_ctx.node.checkpoint_store.save(p) catch |err| {
                            Log.warn("[WARN] Failed to save checkpoint sequence: {s}", .{@errorName(err)});
                        };
                    }
                } else |err| {
                    Log.err("Failed to execute block transactions: {}", .{err});
                }
            }
        }.call;

        const OutcomeCtx = struct {
            node: *Self,
            user_ctx: *anyopaque,
            user_cb: *const fn (ctx: *anyopaque, cert: Mysticeti.CommitCertificate) anyerror!void,
        };
        var outcome_ctx = OutcomeCtx{
            .node = self,
            .user_ctx = on_cert_ctx,
            .user_cb = on_cert,
        };
        const onOutcome = struct {
            fn call(raw: *anyopaque, outcome: CommitCoordinator.CommitOutcome) anyerror!void {
                const c = @as(*OutcomeCtx, @ptrCast(@alignCast(raw)));
                NodeStatsCoordinator.onBlockCommitted(&c.node.stats, outcome.promoted_round);
                try c.user_cb(c.user_ctx, outcome.cert);
            }
        }.call;

        return try CommitCoordinator.tryCommitBatch(
            self.allocator,
            &self.pending_blocks,
            &self.committed_blocks,
            self.config.consensus.vote_quorum,
            self.config.consensus.max_committed_blocks,
            onQuorumBlock,
            &quorum_ctx,
            max_batch,
            onOutcome,
            &outcome_ctx,
        );
    }

    pub fn executeBlockTransactions(self: *Self, block: *const Mysticeti.Block) ![]ExecutionResult {
        if (self.state != .running) return error.NotRunning;
        var ctx = BlockExecution.ExecuteContext{
            .allocator = self.allocator,
            .executor = self.executor,
            .txn_history = &self.txn_history,
        };
        const results = try BlockExecution.executePayloadTransactions(&ctx, block.payload);
        const gas_sum = NodeStatsCoordinator.gasSum(results);
        NodeStatsCoordinator.onTransactionsExecuted(&self.stats, results.len, gas_sum);
        return results;
    }

    pub fn commitBlock(self: *Self, block: *const Mysticeti.Block) !?ExecutionResult {
        if (self.state != .running) return error.NotRunning;
        if (!self.committed_blocks.contains(block.digest)) return error.BlockNotFound;
        const results = try self.executeBlockTransactions(block);
        defer {
            for (results) |res| { res.deinit(self.allocator); }
            self.allocator.free(results);
        }
        var total_gas: u64 = 0;
        for (results) |res| total_gas += res.gas_used;
        const summary = ExecutionResult{
            .digest = block.digest,
            .status = .success,
            .gas_used = total_gas,
            .output_objects = &.{},
            .events = &.{},
        };
        try self.execution_results.put(self.allocator, block.digest, summary);
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

    // NodeStats uses atomic counters so that the commit loop (writer) and
    // metrics/HTTP handlers (readers) can race without torn reads or data
    // races. All reads go through `NodeStatsCoordinator.snapshot` /
    // `NodeStatsCoordinator.<field>` helpers.
    pub const NodeStats = NodeStatsCoordinator.NodeStatsAtomic;

    fn txAdmissionContext(self: *Self) TxnAdmission.Context {
        return .{
            .is_running = self.state == .running,
            .txn_history = &self.txn_history,
            .execution_results = &self.execution_results,
            .sender_sequence = &self.sender_sequence,
            .max_nonce_ahead = 32,
        };
    }

    fn hasSeenTransaction(self: *Self, digest: [32]u8) bool {
        const ctx = self.txAdmissionContext();
        return TxnAdmission.hasSeenTransaction(&ctx, digest);
    }

    fn validateIncomingTransaction(self: *Self, tx: pipeline.Transaction) NodeError![32]u8 {
        const ctx = self.txAdmissionContext();
        return TxnAdmission.validateIncomingTransaction(&ctx, tx) catch |err| switch (err) {
            error.NotRunning => error.NotRunning,
            error.InvalidSignature => error.InvalidSignature,
            error.TransactionAlreadyExecuted => error.TransactionAlreadyExecuted,
            error.NonceTooOld => error.InvalidSequence,
            error.NonceTooNew => error.InvalidSequence,
        };
    }

    fn txExecContext(self: *Self) TxExecutionCoordinator.Context {
        return .{
            .allocator = self.allocator,
            .execution_results = &self.execution_results,
            .txn_history = &self.txn_history,
            .sender_sequence = &self.sender_sequence,
        };
    }

    /// Generate a unique trace id for observability.
    pub fn generateTraceId(self: *Self) [32]u8 {
        const seq = self.trace_counter.fetchAdd(1, .monotonic);
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        var out: [32]u8 = undefined;
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(std.mem.asBytes(&seq));
        ctx.update(std.mem.asBytes(&ts.sec));
        ctx.update(std.mem.asBytes(&ts.nsec));
        ctx.final(&out);
        return out;
    }

    fn indexExecutionResult(self: *Self, tx_digest: [32]u8, result: ExecutionResult) void {
        const idx = self.indexer orelse return;
        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk ts.sec; };
        // Phase 2: index VM-emitted events
        for (result.events) |evt| {
            idx.indexEvent(.{
                .transaction_digest = tx_digest,
                .event_type = evt.event_type,
                .contents = evt.payload,
                .timestamp = now,
                .event_index = evt.event_index,
            }) catch continue;
        }
        // Synthetic execution-status event
        idx.indexEvent(.{
            .transaction_digest = tx_digest,
            .event_type = @tagName(result.status),
            .contents = &.{},
            .timestamp = now,
            .event_index = result.events.len,
        }) catch return;
    }

    pub fn executeTransaction(self: *Self, tx: pipeline.Transaction) !ExecutionResult {
        if (self.state != .running) return error.NotRunning;
        var ctx = self.txExecContext();
        const result = TxExecutionCoordinator.executeOne(&ctx, tx) catch |err| switch (err) {
            error.TransactionAlreadyExecuted => return error.TransactionAlreadyExecuted,
            error.InvalidSequence => return error.InvalidSequence,
            else => return err,
        };
        NodeStatsCoordinator.onTransactionsExecuted(&self.stats, 1, result.gas_used);
        self.indexExecutionResult(result.digest, result);
        return result;
    }

    pub fn executeTransactionBatch(self: *Self, txs: []const pipeline.Transaction) ![]ExecutionResult {
        if (self.state != .running) return error.NotRunning;
        var ctx = self.txExecContext();
        const results = TxExecutionCoordinator.executeBatch(&ctx, txs) catch |err| switch (err) {
            error.TransactionAlreadyExecuted => return error.TransactionAlreadyExecuted,
            error.InvalidSequence => return error.InvalidSequence,
            else => return err,
        };
        const gas_sum = NodeStatsCoordinator.gasSum(results);
        NodeStatsCoordinator.onTransactionsExecuted(&self.stats, results.len, gas_sum);
        for (results) |result| {
            self.indexExecutionResult(result.digest, result);
        }
        return results;
    }

    pub fn getTransactionReceipt(self: *Self, digest: [32]u8) ?pipeline.TransactionReceipt {
        return self.txn_history.get(digest);
    }

    pub fn getExecutionResult(self: *Self, digest: [32]u8) ?ExecutionResult {
        return self.execution_results.get(digest);
    }

    pub fn getExecutorStats(self: *Self) ExecutorStats {
        const snap = NodeStatsCoordinator.snapshot(&self.stats);
        const stats = NodeMetricsCoordinator.buildExecutorStats(
            snap.transactions_executed,
            snap.total_gas_used,
            self.config.parallel_execution,
        );
        return .{
            .transactions_executed = stats.transactions_executed,
            .total_gas_used = stats.total_gas_used,
            .parallelism = stats.parallelism,
        };
    }

    pub fn submitTransaction(self: *Self, tx: pipeline.Transaction, gas_price: u64) !TxnAdmission.SubmitDecision {
        const admission = self.txAdmissionContext();
        const decision = try TxnAdmission.validateForSubmit(&admission, tx);
        if (decision == .duplicate) return .duplicate;
        self.txn_pool.add(tx, gas_price) catch |err| switch (err) {
            error.DuplicateTransaction => return .duplicate,
            else => return err,
        };
        return .accepted;
    }

    pub fn getTxnPoolStats(self: *Self) TxnPoolStats {
        return TxnPoolCoordinator.getTxnPoolStats(self.txn_pool);
    }

    pub fn cleanupExpiredTransactions(self: *Self) usize {
        return TxnPoolCoordinator.cleanupExpiredTransactions(self.txn_pool);
    }

    pub fn getPendingTxnCount(self: *Self) usize {
        return TxnPoolCoordinator.getPendingTxnCount(self.txn_pool);
    }

    pub fn getCommittedBlock(self: *Self, hash: [32]u8) ?Mysticeti.Block {
        return self.committed_blocks.get(hash);
    }

    pub fn isRunning(self: *Self) bool {
        return self.state == .running;
    }

    /// M4 reserved hook: submit stake/unstake/reward/slash operation envelope.
    pub fn submitStakeOperation(self: *Self, input: MainnetExtensionHooks.StakeOperationInput) !u64 {
        return self.mainnet_hooks.submitStakeOperation(input);
    }

    /// M4 reserved hook: submit governance proposal envelope.
    pub fn submitGovernanceProposal(self: *Self, input: MainnetExtensionHooks.GovernanceProposalInput) !u64 {
        return self.mainnet_hooks.submitGovernanceProposal(input);
    }

    /// M4 checkpoint proof with Ed25519 signature(s) from `authority.signing_key` plus `checkpoint_proof_extra_signing_seeds`.
    pub fn buildCheckpointProof(self: *Self, req: MainnetExtensionHooks.CheckpointProofRequest) !MainnetExtensionHooks.CheckpointProof {
        const M = MainnetExtensionHooks;
        const state_root = try self.mainnet_hooks.computeStateRoot();
        const msg = M.m4ProofSigningMessage(state_root, req.sequence, req.object_id);
        const proof_bytes = try self.allocator.dupe(u8, &msg);
        errdefer self.allocator.free(proof_bytes);

        const primary = self.config.authority.signing_key orelse return error.MissingSigningKey;

        var pairs = std.ArrayList(M.ProofSigPair).empty;
        defer pairs.deinit(self.allocator);

        try appendM4CheckpointProofSig(self.allocator, &pairs, primary, proof_bytes);
        for (self.config.authority.checkpoint_proof_extra_signing_seeds) |sk| {
            if (std.mem.eql(u8, &sk, &primary)) continue;
            try appendM4CheckpointProofSig(self.allocator, &pairs, sk, proof_bytes);
        }

        const signatures = try M.encodeProofSignatureList(self.allocator, pairs.items);
        errdefer self.allocator.free(signatures);

        var bls_pubkeys = std.ArrayList(Bls.PublicKey).empty;
        var bls_sigs = std.ArrayList(Bls.Signature).empty;
        defer bls_pubkeys.deinit(self.allocator);
        defer bls_sigs.deinit(self.allocator);
        var bls_bitmap = std.ArrayList(u8).empty;
        defer bls_bitmap.deinit(self.allocator);

        // Use BLS signing seeds directly as private keys.  Previously the code
        // incorrectly used Ed25519 public-key bytes as BLS private keys, which
        // are public and allow anyone to forge BLS signatures.
        if (self.config.authority.bls_signing_seed) |seed| {
            try bls_pubkeys.append(self.allocator, Bls.derivePublicKey(seed));
            try bls_sigs.append(self.allocator, Bls.sign(seed, proof_bytes));
            try bls_bitmap.append(self.allocator, 1);
        }
        for (self.config.authority.extra_bls_signing_seeds) |seed| {
            try bls_pubkeys.append(self.allocator, Bls.derivePublicKey(seed));
            try bls_sigs.append(self.allocator, Bls.sign(seed, proof_bytes));
            try bls_bitmap.append(self.allocator, 1);
        }

        const bls_signature = if (bls_sigs.items.len > 0) blk: {
            const bls_sig_arr = Bls.aggregateSig(bls_sigs.items);
            break :blk try self.allocator.dupe(u8, &bls_sig_arr);
        } else try self.allocator.alloc(u8, 0);
        errdefer if (bls_signature.len > 0) self.allocator.free(bls_signature);
        const bls_signer_bitmap = try bls_bitmap.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(bls_signer_bitmap);

        return .{
            .sequence = req.sequence,
            .object_id = req.object_id,
            .state_root = state_root,
            .proof_bytes = proof_bytes,
            .signatures = signatures,
            .bls_signature = bls_signature,
            .bls_signer_bitmap = bls_signer_bitmap,
        };
    }

    pub fn freeCheckpointProof(self: *Self, proof: MainnetExtensionHooks.CheckpointProof) void {
        self.allocator.free(proof.proof_bytes);
        self.allocator.free(proof.signatures);
        if (proof.bls_signature.len > 0) self.allocator.free(proof.bls_signature);
        self.allocator.free(proof.bls_signer_bitmap);
    }

    pub fn applyEquivocationEvidence(
        self: *Self,
        validator: [32]u8,
        delegator: [32]u8,
        round: u64,
        evidence_payload: []const u8,
        slash_amount: u64,
    ) !bool {
        return self.mainnet_hooks.applyEquivocationEvidence(
            validator,
            delegator,
            round,
            evidence_payload,
            slash_amount,
        );
    }

    /// M4: validator stake tracked by mainnet hooks (after WAL replay / live ops).
    pub fn getM4ValidatorStake(self: *const Self, validator: [32]u8) u64 {
        return self.mainnet_hooks.getValidatorStake(validator);
    }

    /// M4: cumulative slash amount applied through mainnet hooks.
    pub fn getM4TotalSlashed(self: *const Self) u64 {
        return self.mainnet_hooks.getTotalSlashed();
    }

    pub fn getM4CurrentEpoch(self: *const Self) u64 {
        return self.mainnet_hooks.getCurrentEpoch();
    }

    pub fn getM4ValidatorSetHash(self: *const Self) [32]u8 {
        return self.mainnet_hooks.getValidatorSetHash();
    }

    /// Phase 2: advance epoch, sync stake changes to quorum, execute approved proposals.
    pub fn advanceEpoch(self: *Self) !void {
        const sp = self.stake_pool orelse return error.NotRunning;
        const quorum = self.quorum orelse return error.NotRunning;
        const epoch_bridge = self.epoch_bridge orelse return error.NotRunning;

        // Sync stake_pool changes into quorum
        var it = sp.validators.iterator();
        while (it.next()) |entry| {
            try quorum.updateValidatorStake(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Advance epoch via bridge
        try epoch_bridge.handleEpochChange(sp.getTotalStake(), sp.validators.count());

        // Update mainnet hooks epoch
        const new_epoch = self.epoch_manager.?.getCurrentEpoch().number;
        try self.mainnet_hooks.advanceEpoch(new_epoch);

        // Execute approved governance proposals
        for (self.mainnet_hooks.proposals.items) |*p| {
            if (p.status == .approved) {
                self.mainnet_hooks.executeProposal(p.id) catch continue;
            }
        }

        // Rotate validator set hash
        var hash_ctx = std.crypto.hash.Blake3.init(.{});
        for (quorum.members.items) |member| {
            if (member.is_active) {
                hash_ctx.update(&member.id);
                var stake_buf: [16]u8 = undefined;
                std.mem.writeInt(u128, &stake_buf, member.stake, .big);
                hash_ctx.update(&stake_buf);
            }
        }
        var new_hash: [32]u8 = undefined;
        hash_ctx.final(&new_hash);
        try self.mainnet_hooks.rotateValidatorSet(new_hash);
    }

    /// Get an object from the object store
    pub fn getObject(self: *Self, id: core.ObjectID) !?ObjectStore.Object {
        return ObjectStoreCoordinator.getObject(self.object_store, id) catch |err| switch (err) {
            error.ObjectStoreNotAvailable => error.ObjectStoreNotAvailable,
            else => err,
        };
    }

    /// Put an object into the object store
    pub fn putObject(self: *Self, object: ObjectStore.Object) !void {
        return ObjectStoreCoordinator.putObject(self.object_store, object) catch |err| switch (err) {
            error.ObjectStoreNotAvailable => error.ObjectStoreNotAvailable,
            else => err,
        };
    }

    /// Delete an object from the object store
    pub fn deleteObject(self: *Self, id: core.ObjectID) !void {
        return ObjectStoreCoordinator.deleteObject(self.object_store, id) catch |err| switch (err) {
            error.ObjectStoreNotAvailable => error.ObjectStoreNotAvailable,
            else => err,
        };
    }
};

pub const TxnPoolStats = TxnPoolCoordinator.TxnPoolStats;

const ExecutionResult = @import("../pipeline/Executor.zig").ExecutionResult;

test "Node initialization" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_init";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }
    try std.testing.expect(node.state == .initializing);
}

test "Node info" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_info";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }
    const info = node.getNodeInfo();
    try std.testing.expect(info.checkpoint_sequence == 0);
}

test "Node start/stop" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_start_stop";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }
    try node.start();
    try std.testing.expect(node.state == .running);
    node.stop();
    try std.testing.expect(node.state == .stopped);
}

test "Node recoverFromDisk does not crash" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_recover";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    // recoverFromDisk should not error even with empty disk
    try node.recoverFromDisk();
    try std.testing.expect(node.state == .initializing);
}

test "Node start calls recoverFromDisk" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_start_recover";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    // start() should call recoverFromDisk() internally
    try node.start();
    try std.testing.expect(node.state == .running);

    // Node should be operational after start
    const info = node.getNodeInfo();
    try std.testing.expect(info.checkpoint_sequence == 0);

    node.stop();
    try std.testing.expect(node.state == .stopped);
}

test "Node mainnet extension hooks execute protocol state transitions" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_hooks";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    config.authority.signing_key = [_]u8{0x77} ** 32;
    config.authority.stake = 1_000_000_000;
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    const stake_id = try node.submitStakeOperation(.{
        .validator = [_]u8{1} ** 32,
        .delegator = [_]u8{2} ** 32,
        .amount = 100,
        .action = .stake,
    });
    try std.testing.expectEqual(@as(u64, 1), stake_id);

    const proposal_id = try node.submitGovernanceProposal(.{
        .proposer = [_]u8{3} ** 32,
        .title = "reserve-governance",
        .description = "M4 placeholder",
        .kind = .parameter_change,
    });
    try std.testing.expectEqual(@as(u64, 1), proposal_id);

    const slash_id = try node.submitStakeOperation(.{
        .validator = [_]u8{1} ** 32,
        .delegator = [_]u8{2} ** 32,
        .amount = 10,
        .action = .slash,
        .metadata = "test-equivocation",
    });
    try std.testing.expectEqual(@as(u64, 2), slash_id);

    const proof = try node.buildCheckpointProof(.{
        .sequence = 1,
        .object_id = [_]u8{4} ** 32,
    });
    defer node.freeCheckpointProof(proof);
    try std.testing.expectEqual(@as(u64, 1), proof.sequence);
    try std.testing.expectEqual(@as(usize, 80), proof.proof_bytes.len);
    try std.testing.expect(std.mem.startsWith(u8, proof.signatures, "k3s1"));
}
