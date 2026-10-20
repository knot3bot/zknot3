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
const Genesis = @import("Genesis.zig");
const CutoverSignals = @import("CutoverSignals.zig");
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
const Marketplace = @import("../property/move_vm/marketplace.zig").Marketplace;
const AgentMessaging = @import("../property/move_vm/agent_messaging.zig").AgentMessaging;
const AgentRegistry = @import("../property/move_vm/agent_registry.zig").AgentRegistry;
const StateSnapshot = @import("../form/storage/StateSnapshot.zig");
const wal_mod = @import("../form/storage/WAL.zig");
const WAL = wal_mod.WAL;
const WalRecordType = wal_mod.WalRecordType;
const SigCrypto = @import("../property/crypto/Signature.zig");
const Bls = core.Bls;

/// Move one validator's pool balance to `target`. Increases are recorded as
/// self-stake. Decreases drain self-stake first, then delegated stake.
fn setPoolVotingPower(pool: *StakePool, validator: [32]u8, target: u128) !void {
    const current = pool.getVotingPower(validator);
    if (target == current) return;
    if (target > current) {
        try pool.addStake(validator, target - current, true);
        return;
    }
    var delta = current - target;
    const self_stake = pool.validator_self_stake.get(validator) orelse 0;
    const from_self = @min(self_stake, delta);
    if (from_self > 0) {
        try pool.removeStake(validator, from_self, true);
        delta -= from_self;
    }
    if (delta > 0) try pool.removeStake(validator, delta, false);
}

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
    BrokenCheckpointChain,
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
    /// Deep copy of the configuration handed to `init`. The node owns it: callers
    /// commonly heap-allocate the config and free it as soon as `init` returns,
    /// and a borrowed `*const Config` would dangle on every later access
    /// (`deinit` included). Backing storage lives in `config_arena`.
    config: *const Config,
    config_arena: std.heap.ArenaAllocator,
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
    /// Owned domain services whose clocks follow `syncExecutorEpoch`.
    marketplace: ?*Marketplace = null,
    agent_messaging: ?*AgentMessaging = null,
    agent_registry: ?*AgentRegistry = null,
    runtime_metrics: ?*RuntimeMetrics.RuntimeMetricsCollector = null,
    mainnet_hooks: *MainnetExtensionHooks.Manager,
    /// M4 protocol WAL (separate from LSM); optional if init fails.
    m4_wal: ?*WAL = null,
    /// Wall-clock seconds of the last successful periodic `m4_gas_snapshot`.
    /// `0` means never flushed this process; used by `maybeAppendGasSnapshotWal`.
    last_gas_snapshot_at: i64 = 0,
    /// Epoch management (Phase 0: default primary path)
    epoch_manager: ?*EpochManager = null,
    stake_pool: ?*StakePool = null,
    quorum: ?*Quorum = null,
    epoch_bridge: ?*EpochConsensusBridge = null,
    /// Phase 1: optional indexer for object/event queries
    indexer: ?*Indexer = null,
    /// Phase 1: atomic trace ID counter for observability
    trace_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Blake3 of the loaded genesis body. All-zero when no file is configured.
    genesis_digest: [32]u8 = @splat(0),
    cutover: CutoverSignals.State = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const Config,
        deps: NodeDependencies,
    ) !*Self {
        // Own the configuration before anything else: every field below reads it.
        //
        // Ownership hand-off: every resource built here is stored on `self_ptr`
        // and freed by `deinit`. Until `errdefer self_ptr.deinit()` is armed
        // further down, the local guards must release them instead — otherwise
        // both fire and the same allocation is freed twice.
        var config_arena = std.heap.ArenaAllocator.init(allocator);
        const owned_config = try config_arena.allocator().create(Config);
        owned_config.* = try config.dupe(config_arena.allocator());

        var locals_owned_by_node = false;
        errdefer if (!locals_owned_by_node) config_arena.deinit();

        const txn_pool = try pipeline.TxnPool.init(allocator, .{});
        var txn_pool_owned_locally = true;
        errdefer if (txn_pool_owned_locally) txn_pool.deinit();
        // Parallelism is worker-thread count, not txs-per-block. Cap to the
        // Executor pool limit so Node.init does not spawn thousands of threads.
        const exec = try pipeline.Executor.init(allocator, .{
            .parallelism = @min(
                @as(usize, owned_config.consensus.max_txs_per_block),
                pipeline.Executor.MAX_WORKER_POOL_SIZE,
            ),
            .max_gas = owned_config.vm.max_gas_budget,
        });
        var exec_owned_locally = true;
        errdefer if (exec_owned_locally) exec.deinit();

        // Wire Executor gas ledger when enabled. Allowlist can be seeded immediately;
        // local authority pubkey is seeded after `resolveSigningKey` (may still be null here).
        // No zero-key seeding — if no 32-byte local address is available, allowlist only.
        if (owned_config.vm.enforce_gas_payment) {
            exec.enforce_gas_payment = true;
            const seed_amount = owned_config.vm.initial_gas_balance;
            for (owned_config.authority.gas_station_allowlist) |addr| {
                try exec.setGasBalance(addr, seed_amount);
            }
        }

        // Phase 2: set up native function registry for Move VM.
        // On success `exec` owns the registry (`Executor.deinit` frees it), so
        // these errdefers must not outlive the block.
        {
            const vm_registry = try allocator.create(property.move_vm.Registry);
            errdefer allocator.destroy(vm_registry);
            vm_registry.* = property.move_vm.Registry.init(allocator);
            errdefer vm_registry.deinit();
            try vm_registry.registerSuiFramework();
            exec.registry = vm_registry;
        }

        const marketplace = try Marketplace.init(allocator);
        var marketplace_owned_locally = true;
        errdefer if (marketplace_owned_locally) marketplace.deinit();
        const agent_messaging = try AgentMessaging.init(allocator);
        var agent_messaging_owned_locally = true;
        errdefer if (agent_messaging_owned_locally) agent_messaging.deinit();
        const agent_registry = try AgentRegistry.init(allocator);
        var agent_registry_owned_locally = true;
        errdefer if (agent_registry_owned_locally) agent_registry.deinit();
        exec.marketplace = marketplace;
        exec.agent_messaging = agent_messaging;
        exec.agent_registry = agent_registry;

        const self_ptr = try allocator.create(Self);
        // `deinit` ends in `allocator.destroy(self)`, so once it is armed below
        // this guard must stand down or the two errdefers double-free.
        var self_destroyed = false;
        errdefer if (!self_destroyed) allocator.destroy(self_ptr);

        self_ptr.allocator = allocator;
        self_ptr.config = owned_config;
        self_ptr.config_arena = config_arena;
        self_ptr.state = .initializing;
        self_ptr.deps = deps;
        self_ptr.object_store = null;
        const cp_path = try std.fmt.allocPrint(allocator, "{s}/{s}/sequence.bin", .{ owned_config.storage.data_dir, owned_config.storage.checkpoint_store_path });
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
        self_ptr.marketplace = marketplace;
        self_ptr.agent_messaging = agent_messaging;
        self_ptr.agent_registry = agent_registry;
        self_ptr.runtime_metrics = null;
        self_ptr.runtime_metrics = try RuntimeMetrics.RuntimeMetricsCollector.init(allocator, 100);
        // Needed only until `deinit` is armed below, which tears down
        // `runtime_metrics` itself; errdefers run in reverse order.
        errdefer if (!self_destroyed) {
            if (self_ptr.runtime_metrics) |rm| {
                rm.deinit();
                allocator.destroy(rm);
            }
        };
        self_ptr.mainnet_hooks = try MainnetExtensionHooks.Manager.init(allocator);
        self_ptr.m4_wal = null;
        self_ptr.last_gas_snapshot_at = 0;
        // allocator.create(Self) yields undefined memory: field defaults do
        // NOT apply. The blanket errdefer below runs deinit on partially
        // initialized state, so every optional member must be explicitly
        // nulled here (deinit dereferences them) — this was a segfault on
        // any init error between this point and their real assignment.
        self_ptr.epoch_manager = null;
        self_ptr.genesis_digest = @splat(0);
        self_ptr.cutover = .{};
        self_ptr.stake_pool = null;
        self_ptr.quorum = null;
        self_ptr.epoch_bridge = null;
        self_ptr.indexer = null;

        errdefer self_ptr.deinit();
        // From here `deinit` owns the node, its config arena, the executor and
        // the txn pool; the local guards above stand down.
        self_destroyed = true;
        locals_owned_by_node = true;
        exec_owned_locally = false;
        txn_pool_owned_locally = false;
        marketplace_owned_locally = false;
        agent_messaging_owned_locally = false;
        agent_registry_owned_locally = false;

        self_ptr.object_store = try ObjectStore.init(
            allocator,
            .{},
            owned_config.storage.data_dir,
        );
        if (self_ptr.object_store) |store| {
            self_ptr.executor.attachObjectStore(store);
        }

        // Phase 0: initialize epoch bridge as the default primary path
        const epoch_manager = try EpochManager.init(allocator, .{
            .duration_seconds = owned_config.consensus.epoch_duration_secs,
            .min_validators = owned_config.consensus.min_validators,
            .max_validators = owned_config.consensus.max_validators,
        }, self_ptr.started_at);
        errdefer epoch_manager.deinit();

        const stake_pool = try StakePool.init(allocator);
        errdefer stake_pool.deinit();

        const quorum = try Quorum.init(allocator);
        errdefer quorum.deinit();

        const epoch_bridge = try EpochConsensusBridge.init(allocator, epoch_manager, stake_pool, quorum);
        errdefer epoch_bridge.deinit();

        // Phase 0: bootstrap validator stake from config known_validators into stake_pool
        for (owned_config.network.known_validators) |kv| {
            if (kv.stake > 0) {
                const pk = std.fmt.parseInt(u256, kv.public_key_hex, 16) catch |err| {
                    Log.err("[init] invalid validator public_key_hex: {s}", .{@errorName(err)});
                    continue;
                };
                var validator_id: [32]u8 = undefined;
                std.mem.writeInt(u256, &validator_id, pk, .big);
                stake_pool.addStake(validator_id, kv.stake, true) catch |err| {
                    Log.err("[init] failed to add stake for validator: {s}", .{@errorName(err)});
                    continue;
                };
            }
        }

        self_ptr.epoch_manager = epoch_manager;
        self_ptr.syncExecutorEpoch();
        self_ptr.stake_pool = stake_pool;
        // Publish the pool so `votingPowerOf` (a free function, required by the
        // ingress API) can resolve authoritative vote weights.
        active_stake_pool = stake_pool;
        self_ptr.quorum = quorum;
        self_ptr.epoch_bridge = epoch_bridge;
        self_ptr.deps.epoch_bridge = epoch_bridge;

        // Phase 1: initialize indexer for object/event queries
        const indexer = try Indexer.init(allocator, .{});
        self_ptr.indexer = indexer;
        self_ptr.deps.indexer = indexer;

        const m4_base = try std.fmt.allocPrint(allocator, "{s}/m4_state", .{owned_config.storage.data_dir});
        defer allocator.free(m4_base);
        if (WAL.init(allocator, m4_base)) |wal_val| {
            const m4_wal_ptr = try allocator.create(WAL);
            m4_wal_ptr.* = wal_val;
            self_ptr.m4_wal = m4_wal_ptr;
            self_ptr.mainnet_hooks.setM4Wal(m4_wal_ptr);
            self_ptr.wireGasBalanceWalHook();
        } else |err| {
            Log.warn("M4 WAL init failed: {s}", .{@errorName(err)});
        }

        try @import("Config.zig").Config.resolveSigningKey(&owned_config.authority, allocator);
        // Seed local gas payer after signing key resolution (Ed25519 pubkey as address).
        if (owned_config.vm.enforce_gas_payment) {
            if (owned_config.authority.signing_key) |sk| {
                if (std.crypto.sign.Ed25519.KeyPair.generateDeterministic(sk)) |kp| {
                    try self_ptr.executor.setGasBalance(kp.public_key.toBytes(), owned_config.vm.initial_gas_balance);
                } else |_| {
                    Log.warn("[init] enforce_gas_payment: cannot derive local pubkey; seeded allowlist only", .{});
                }
            } else {
                Log.warn("[init] enforce_gas_payment: no local signing_key; seeded allowlist only", .{});
            }
        }
        const loaded_genesis = try Genesis.load(allocator, owned_config.network.genesis_path, owned_config.is_dev);
        self_ptr.genesis_digest = loaded_genesis.digest;
        if (std.mem.eql(u8, owned_config.network.transport, "quic") and !@import("quic_options").enabled) {
            return error.QuicTransportRequiresBuildFlag;
        }

        if (owned_config.network.p2p_enabled) {
            // Same u256 big-endian decode as stake bootstrap / genesisValidatorId
            // so the handshake Ed25519 peer key matches configured hex. Invalid
            // entries are skipped; an empty result refuses advertised redial.
            const kvs = owned_config.network.known_validators;
            const known_keys = try self_ptr.config_arena.allocator().alloc([32]u8, kvs.len);
            var nkeys: usize = 0;
            for (kvs) |kv| {
                const pk = std.fmt.parseInt(u256, kv.public_key_hex, 16) catch |err| {
                    Log.warn("[init] invalid known_validator public_key_hex for redial trust: {s}", .{@errorName(err)});
                    continue;
                };
                std.mem.writeInt(u256, &known_keys[nkeys], pk, .big);
                nkeys += 1;
            }
            const p2p_config = P2PServer_module.P2PServerConfig{
                .bind_address = owned_config.network.p2p_address,
                .max_connections = 256,
                .bootstrap_peers = owned_config.network.bootstrap_peers,
                .dial_bootstrap = true,
                .transport_type = if (std.mem.eql(u8, owned_config.network.transport, "quic")) .quic else .tcp,
                .genesis_digest = self_ptr.genesis_digest,
                .validator_key = owned_config.authority.signing_key,
                .allow_unauthenticated_handshake = owned_config.allow_unauthenticated_p2p,
                .max_messages_per_second_per_peer = owned_config.network.p2p_max_messages_per_peer_per_second,
                .max_messages_per_second_per_type = owned_config.network.p2p_max_messages_per_type_per_second,
                .peer_score_ban_threshold = owned_config.network.p2p_peer_score_ban_threshold,
                .peer_ban_seconds = owned_config.network.p2p_peer_ban_seconds,
                .max_peers_per_16 = owned_config.network.p2p_max_peers_per_16,
                .max_peers_per_48 = owned_config.network.p2p_max_peers_per_48,
                .reserved_outbound_slots = owned_config.network.p2p_reserved_outbound_slots,
                .peer_rotation_interval_secs = owned_config.network.p2p_peer_rotation_interval_secs,
                .inbound_ratio_limit = owned_config.network.p2p_inbound_ratio_limit,
                .advertise_address = owned_config.network.resolveP2pAdvertiseAddress(),
                .known_validator_keys = known_keys[0..nkeys],
            };

            self_ptr.p2p_server = try P2PServer.init(allocator, p2p_config);
        }

        return self_ptr;
    }

    pub fn deinit(self: *Self) void {
        if (active_stake_pool == self.stake_pool) active_stake_pool = null;
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
        // Truncate WAL after checkpoint — data is safely in SSTables.
        // Clean shutdown writes ONE m4_gas_snapshot (plus m4ss) instead of
        // flushing every account as m4_gas_balance — runtime still logs
        // per-op balances and may append periodic m4_gas_snapshot (see
        // maybeAppendGasSnapshotWal); skip appendAllGasBalancesWal here.
        // Gas snapshot must run before executor.deinit (accounts live there).
        if (self.m4_wal) |w| {
            w.truncate() catch |err| {
                Log.warn("[WARN] Failed to truncate WAL after checkpoint: {s}", .{@errorName(err)});
            };
        }
        self.mainnet_hooks.appendStateSnapshotWal() catch |err| {
            Log.warn("[WARN] Failed to append M4 state snapshot on shutdown: {s}", .{@errorName(err)});
        };
        self.appendGasSnapshotWal() catch |err| {
            Log.warn("[WARN] Failed to append gas snapshot to M4 WAL on shutdown: {s}", .{@errorName(err)});
        };
        self.checkpoint_store.deinit();
        self.txn_pool.deinit();
        self.executor.marketplace = null;
        self.executor.agent_messaging = null;
        self.executor.agent_registry = null;
        self.executor.setGasBalanceWalHook(null, null);
        self.executor.deinit();
        if (self.marketplace) |mp| mp.deinit();
        if (self.agent_messaging) |am| am.deinit();
        if (self.agent_registry) |reg| reg.deinit();
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
        // Release the owned config last: components torn down above (object
        // store, P2P server) still hold string slices pointing into the arena.
        self.config_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        try NodeLifecycleCoordinator.runStart(self);
    }

    /// Validate node configuration before starting
    pub fn validateConfig(self: *Self) !void {
        const cfg = self.config;
        if (cfg.network.rpc_port == 0) return error.InvalidConfig;
        if (cfg.storage.data_dir.len == 0) return error.InvalidConfig;
        // Validator-specific checks
        if (cfg.consensus.validator_enabled) {
            if (cfg.consensus.vote_quorum == 0) return error.InvalidConfig;
            if (cfg.consensus.min_validators < 4) return error.InvalidConfig;
            if (cfg.consensus.max_validators < cfg.consensus.min_validators) return error.InvalidConfig;
            if (cfg.authority.signing_key == null) return error.InvalidConfig;
            if (cfg.authority.stake == 0) return error.InvalidConfig;
            if (!cfg.network.p2p_enabled) return error.InvalidConfig;
        }
        if (std.mem.eql(u8, cfg.network.transport, "quic") and !@import("quic_options").enabled) {
            return error.QuicTransportRequiresBuildFlag;
        }
        // Network: non-loopback bind requires admin token
        if (!std.mem.eql(u8, cfg.network.bind_address, "127.0.0.1") and
            cfg.network.admin_token.len == 0) return error.InvalidConfig;
        // Gas price sanity
        if (cfg.vm.min_gas_price == 0) return error.InvalidConfig;
        if (cfg.vm.max_gas_budget < cfg.vm.min_gas_price) return error.InvalidConfig;
        // Storage thresholds
        if (cfg.storage.cache_size == 0) return error.InvalidConfig;
        // Max connections must be > 0 if P2P enabled
        if (cfg.network.p2p_enabled and cfg.network.max_connections == 0) return error.InvalidConfig;
        if (cfg.network.p2p_inbound_ratio_limit > 100) return error.InvalidConfig;
        // Consensus budget sanity
        if (cfg.consensus.epoch_duration_secs == 0) return error.InvalidConfig;
    }

    pub fn stop(self: *Self) void {
        self.state = .shutting_down;
        if (self.p2p_server) |server| {
            server.stop();
        }

        // Drain pending blocks with a bounded deadline (5 seconds).
        // The consensus event loop in main.zig will continue processing
        // commits during the drain window via the normal poll loop.
        const drain_deadline = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
            break :blk ts.sec + 5;
        };
        while (self.pending_blocks.count() > 0) {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
            if (ts.sec >= drain_deadline) {
                Log.warn("[Node.stop] drain timeout — {} blocks uncommitted", .{
                    self.pending_blocks.count(),
                });
                break;
            }
            // Yield to the OS scheduler while waiting for blocks to drain
            std.atomic.spinLoopHint();
        }

        self.state = .stopped;
    }

    /// Get P2P server if available
    pub fn getP2PServer(self: *Self) ?*P2PServer {
        return self.p2p_server;
    }

    fn noteCheckpointAdvanced(self: *Self) void {
        const epoch = if (self.epoch_manager) |em| em.getCurrentEpoch().number else 0;
        self.cutover.noteCheckpoint(epoch);
    }

    pub fn cutoverGauges(self: *Self) CutoverSignals.Gauges {
        const epoch = if (self.epoch_manager) |em| em.getCurrentEpoch().number else 0;
        const bans = if (self.p2p_server) |p2p| p2p.getRateLimitStats().banned_peers_total else 0;
        return self.cutover.gauges(epoch, bans);
    }

    fn monotonicElapsedNs(started: std.c.timespec, ended: std.c.timespec) u64 {
        const s = @as(i128, ended.sec - started.sec) * std.time.ns_per_s + @as(i128, ended.nsec - started.nsec);
        if (s <= 0) return 0;
        if (s > std.math.maxInt(u64)) return std.math.maxInt(u64);
        return @intCast(s);
    }

    /// Recover node state from disk (checkpoint + WAL)
    pub fn recoverFromDisk(self: *Self) !void {
        var started: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &started);
        defer {
            var ended: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ended);
            self.cutover.noteRecovery(monotonicElapsedNs(started, ended));
        }
        try NodeLifecycleCoordinator.recoverFromDisk(self.object_store);
        // Phase 2+: replay M4 WAL to restore stake/governance/epoch state
        try self.replayMainnetM4Wal();

        // Phase 3: recover checkpoint sequence state from disk if exists
        const cp_path = std.fmt.allocPrint(self.allocator, "{s}/{s}/sequence.bin", .{ self.config.storage.data_dir, self.config.storage.checkpoint_store_path }) catch null;
        if (cp_path) |p| {
            defer self.allocator.free(p);
            if (CheckpointSequence.load(p)) |recovered_cs| {
                self.checkpoint_store.deinit();
                self.checkpoint_store = recovered_cs;
                Log.info("Loaded checkpoint sequence state from disk (seq: {})", .{self.checkpoint_store.getLatestSequence()});
            } else |err| {
                if (err != error.FileNotFound) {
                    Log.warn("Failed to recover checkpoint sequence from {s}: {s}", .{ p, @errorName(err) });
                }
            }
        }
    }

    /// Replay M4 extension WAL into `mainnet_hooks` / executor after object-store recovery.
    /// Temporarily clears hooks + gas WAL callback so replay does not append duplicates.
    pub fn replayMainnetM4Wal(self: *Self) !void {
        const w = self.m4_wal orelse return;
        self.mainnet_hooks.setM4Wal(null);
        self.executor.setGasBalanceWalHook(null, null);
        defer {
            self.mainnet_hooks.setM4Wal(w);
            self.wireGasBalanceWalHook();
        }

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
                    .m4_gas_balance => {
                        const payload = value orelse return error.InvalidWalPayload;
                        if (payload.len != 40) return error.InvalidWalPayload;
                        var addr: [32]u8 = undefined;
                        @memcpy(&addr, payload[0..32]);
                        const amount = std.mem.readInt(u64, payload[32..40], .big);
                        // Hook cleared above — setGasBalance must not re-append.
                        try node.executor.setGasBalance(addr, amount);
                    },
                    .m4_gas_snapshot => {
                        const payload = value orelse return error.InvalidWalPayload;
                        // Hook cleared above — wipe+set must not re-append.
                        try node.applyGasSnapshotPayload(payload);
                    },
                    else => {},
                }
            }
        };

        const result = try w.replayWithOptions(Cb.onReplay, self, .{
            .max_record_type = 20,
            .validate_types = true,
            .skip_corrupted = self.config.storage.recovery_skip_corrupted,
        });
        if (result.errors > 0) return error.ReadFailed;
    }

    fn wireGasBalanceWalHook(self: *Self) void {
        if (self.m4_wal == null) {
            self.executor.setGasBalanceWalHook(null, null);
            return;
        }
        const Cb = struct {
            fn onChanged(ctx: *anyopaque, addr: [32]u8, balance: u64) anyerror!void {
                const node: *Self = @ptrCast(@alignCast(ctx));
                try node.appendGasBalanceWal(addr, balance);
            }
        };
        self.executor.setGasBalanceWalHook(self, Cb.onChanged);
    }

    /// Append absolute gas balance to M4 WAL. No-op when WAL absent.
    /// Payload: `address[32] || amount_be64[8]`.
    pub fn appendGasBalanceWal(self: *Self, addr: [32]u8, balance: u64) !void {
        const w = self.m4_wal orelse return;
        var payload: [40]u8 = undefined;
        @memcpy(payload[0..32], &addr);
        std.mem.writeInt(u64, payload[32..40], balance, .big);
        try w.logExtensionRecord(.m4_gas_balance, &payload);
    }

    /// Append full gas ledger snapshot for fast recovery.
    /// Payload: `u32_be count || count * (address[32] || amount_be64[8])`, addresses sorted.
    /// Clean shutdown uses this instead of `appendAllGasBalancesWal`.
    /// Periodic runtime flushes (`maybeAppendGasSnapshotWal`) also call this —
    /// append-only, never truncates — so crash recovery can skip long
    /// `m4_gas_balance` tails while per-op records still cover the gap.
    pub fn appendGasSnapshotWal(self: *Self) !void {
        const w = self.m4_wal orelse return;
        const count = self.executor.gas_accounts.count();
        const Entry = struct { addr: [32]u8, amount: u64 };
        const entries = try self.allocator.alloc(Entry, count);
        defer self.allocator.free(entries);
        var i: usize = 0;
        var it = self.executor.gas_accounts.iterator();
        while (it.next()) |entry| : (i += 1) {
            entries[i] = .{ .addr = entry.key_ptr.*, .amount = entry.value_ptr.* };
        }
        std.mem.sort(Entry, entries, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, &a.addr, &b.addr) == .lt;
            }
        }.lessThan);

        const payload_len = 4 + count * 40;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);
        std.mem.writeInt(u32, payload[0..4], @intCast(count), .big);
        var off: usize = 4;
        for (entries) |e| {
            @memcpy(payload[off .. off + 32], &e.addr);
            std.mem.writeInt(u64, payload[off + 32 ..][0..8], e.amount, .big);
            off += 40;
        }
        try w.logExtensionRecord(.m4_gas_snapshot, payload);
    }

    /// Append `m4_gas_snapshot` when `storage.gas_snapshot_interval_secs` has
    /// elapsed since `last_gas_snapshot_at`. Append-only (no WAL truncate).
    /// No-op when interval is `0`, M4 WAL is absent, or the interval has not
    /// elapsed. Empty ledgers are still snapshotted (valid wipe baseline).
    pub fn maybeAppendGasSnapshotWal(self: *Self) void {
        const interval = self.config.storage.gas_snapshot_interval_secs;
        if (interval <= 0) return;
        if (self.m4_wal == null) return;

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const now: i64 = ts.sec;
        if (self.last_gas_snapshot_at != 0 and now - self.last_gas_snapshot_at < interval) return;

        self.appendGasSnapshotWal() catch |err| {
            Log.warn("[WARN] Periodic gas snapshot WAL append failed: {s}", .{@errorName(err)});
            return;
        };
        self.last_gas_snapshot_at = now;
    }

    /// Replace `executor.gas_accounts` from an `m4_gas_snapshot` payload (true restore).
    fn applyGasSnapshotPayload(self: *Self, payload: []const u8) !void {
        if (payload.len < 4) return error.InvalidWalPayload;
        const count = std.mem.readInt(u32, payload[0..4], .big);
        const expected = 4 + @as(usize, count) * 40;
        if (payload.len != expected) return error.InvalidWalPayload;

        self.executor.gas_accounts.clearRetainingCapacity();
        var off: usize = 4;
        var n: u32 = 0;
        while (n < count) : (n += 1) {
            var addr: [32]u8 = undefined;
            @memcpy(&addr, payload[off .. off + 32]);
            const amount = std.mem.readInt(u64, payload[off + 32 ..][0..8], .big);
            off += 40;
            // Caller must clear gas WAL hook during replay so this does not re-append.
            try self.executor.setGasBalance(addr, amount);
        }
    }

    /// Flush every in-memory gas account as absolute M4 records.
    /// Not used on clean shutdown (prefer `appendGasSnapshotWal`); kept for
    /// callers that need a per-account absolute dump without a snapshot.
    fn appendAllGasBalancesWal(self: *Self) !void {
        if (self.m4_wal == null) return;
        var it = self.executor.gas_accounts.iterator();
        while (it.next()) |entry| {
            try self.appendGasBalanceWal(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    pub fn getNodeInfo(self: *Self) NodeInfo {
        const epoch_info = self.getEpochInfo();
        return .{
            .version = "0.16.0",
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

        // Latency estimates from summary data (wall-clock instrumentation pending).
        // These are derived from execution throughput rather than measured directly.
        const est_latency_ms: f64 = if (tps > 0) 1000.0 / tps else 0;
        const user = RuntimeMetrics.UserMetrics{
            .latency_p50 = est_latency_ms,
            .latency_p99 = est_latency_ms * 3.0,
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
            @as([32]u8, @splat(0)),
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

    pub fn advanceRound(self: *Self) error{ArithmeticOverflow}!void {
        self.consensus_round = std.math.add(u64, self.consensus_round, 1) catch return error.ArithmeticOverflow;
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
            &votingPowerOf,
        );
    }

    /// Authoritative voting weight for a validator id, read from the genesis
    /// stake pool. Passed to vote ingress so a vote's weight comes from local
    /// state rather than from the wire.
    fn votingPowerOf(validator: [32]u8) u128 {
        const pool = active_stake_pool orelse return 0;
        return pool.getVotingPower(validator);
    }

    /// Set by `Node.init` so `votingPowerOf` (a free function, as the ingress
    /// API requires) can reach this node's stake pool. A process hosts exactly
    /// one node, so a single pointer is unambiguous.
    threadlocal var active_stake_pool: ?*StakePool = null;

    pub fn tryCommitBlocks(self: *Self) !?Mysticeti.CommitCertificate {
        if (self.state != .running) return error.NotRunning;

        // Check round timeout — advances round if stalled
        if (self.consensus_integration) |ci| {
            ci.mysticeti.checkRoundTimeout(self.config.consensus.round_timeout_secs);
        }

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
                    if (typed_ctx.node.checkpoint_store.advance()) |_| {
                        typed_ctx.node.noteCheckpointAdvanced();
                        const cp_path = std.fmt.allocPrint(typed_ctx.node.allocator, "{s}/{s}/sequence.bin", .{ typed_ctx.node.config.storage.data_dir, typed_ctx.node.config.storage.checkpoint_store_path }) catch null;
                        if (cp_path) |p| {
                            defer typed_ctx.node.allocator.free(p);
                            typed_ctx.node.checkpoint_store.save(p) catch |err| {
                                Log.warn("[WARN] Failed to save checkpoint sequence: {s}", .{@errorName(err)});
                            };
                        }
                    } else |err| {
                        Log.warn("[WARN] Failed to advance checkpoint sequence: {s}", .{@errorName(err)});
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
            self.totalStakeForQuorum(),
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
    /// Resolve the canonical id for the i-th genesis validator.
    ///
    /// Vote weights and `stake_pool` keys are both derived from
    /// `known_validators[i].public_key_hex`. The validator identity used by
    /// consensus must therefore come from the same place -- deriving it from
    /// `authority.signing_key` instead produced an id that was never in the
    /// stake pool, so the node's own weight looked like zero and it refused to
    /// vote. Returns null when the index is out of range or the hex is invalid.
    pub fn genesisValidatorId(self: *const Self, index: usize) ?[32]u8 {
        const kv = self.config.network.known_validators;
        if (index >= kv.len) return null;
        const pk = std.fmt.parseInt(u256, kv[index].public_key_hex, 16) catch return null;
        var id: [32]u8 = undefined;
        std.mem.writeInt(u256, &id, pk, .big);
        return id;
    }

    /// The id this node should vote as: the genesis entry that matches its own
    /// configured `validator_index`, falling back to the id derived from its
    /// signing key when no genesis table is configured.
    pub fn selfValidatorId(self: *const Self, signing_key: [32]u8) [32]u8 {
        if (self.genesisValidatorId(self.config.authority.validator_index)) |id| return id;
        const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(signing_key) catch
            return @as([32]u8, @splat(0));
        return kp.public_key.toBytes();
    }

    /// Total stake the quorum threshold is measured against. Read from the
    /// genesis-backed stake pool; 0 means "no stake table", which makes every
    /// stake-weighted quorum check fail closed.
    pub fn totalStakeForQuorum(self: *const Self) u128 {
        const pool = self.stake_pool orelse return 0;
        return pool.getTotalStake();
    }

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
                    if (typed_ctx.node.checkpoint_store.advance()) |_| {
                        typed_ctx.node.noteCheckpointAdvanced();
                        const cp_path = std.fmt.allocPrint(typed_ctx.node.allocator, "{s}/{s}/sequence.bin", .{ typed_ctx.node.config.storage.data_dir, typed_ctx.node.config.storage.checkpoint_store_path }) catch null;
                        if (cp_path) |p| {
                            defer typed_ctx.node.allocator.free(p);
                            typed_ctx.node.checkpoint_store.save(p) catch |err| {
                                Log.warn("[WARN] Failed to save checkpoint sequence: {s}", .{@errorName(err)});
                            };
                        }
                    } else |err| {
                        Log.warn("[WARN] Failed to advance checkpoint sequence: {s}", .{@errorName(err)});
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
            self.totalStakeForQuorum(),
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
            for (results) |res| {
                res.deinit(self.allocator);
            }
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
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
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
        const now = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            break :blk ts.sec;
        };
        // Phase 2: index VM-emitted events
        for (result.events) |evt| {
            idx.indexEvent(.{
                .transaction_digest = tx_digest,
                .event_type = evt.event_type,
                .contents = evt.payload,
                .timestamp = now,
                .event_index = evt.event_index,
            }) catch |err| {
                Log.err("[indexer] failed to index event for tx={x}: {s}", .{ tx_digest, @errorName(err) });
            };
        }
        // Synthetic execution-status event
        idx.indexEvent(.{
            .transaction_digest = tx_digest,
            .event_type = @tagName(result.status),
            .contents = &.{},
            .timestamp = now,
            .event_index = result.events.len,
        }) catch |err| {
            Log.err("[indexer] failed to index synthetic event for tx={x}: {s}", .{ tx_digest, @errorName(err) });
        };
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

    /// Dry-run / simulate a transaction without committing state changes.
    /// Returns execution effects (gas used, events, output objects) enabling
    /// AI agents to preview outcomes before submission. Essential for PTB composition.
    pub fn dryRunTransaction(self: *Self, tx: pipeline.Transaction) !ExecutionResult {
        // Execute in a sandbox: execute normally but skip state commit + indexing.
        // The underlying executor does not persist results — only the caller (commitBlock)
        // writes to the object store. So dry-run is a natural fit: just execute + return.
        var ctx = self.txExecContext();
        return TxExecutionCoordinator.executeOne(&ctx, tx);
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

    /// Credit gas ledger for `addr` by `amount`. Returns the new balance.
    /// Persists absolute balance via M4 WAL when present.
    pub fn creditGas(self: *Self, addr: [32]u8, amount: u64) !u64 {
        try self.executor.creditGasBalance(addr, amount);
        const balance = self.executor.getGasBalance(addr);
        try self.appendGasBalanceWal(addr, balance);
        return balance;
    }

    /// Read gas ledger balance; unset addresses are 0.
    pub fn getGasBalance(self: *const Self, addr: [32]u8) u64 {
        return self.executor.getGasBalance(addr);
    }

    /// M4 reserved hook: submit stake/unstake/reward/slash operation envelope.
    /// The resulting validator stake is copied into `stake_pool` so consensus
    /// voting power follows the same number.
    pub fn submitStakeOperation(self: *Self, input: MainnetExtensionHooks.StakeOperationInput) !u64 {
        const id = try self.mainnet_hooks.submitStakeOperation(input);
        try self.syncValidatorVotingPower(input.validator);
        return id;
    }

    pub fn scheduledSlashAmount(self: *const Self, validator: [32]u8) u64 {
        return self.mainnet_hooks.scheduledSlashAmount(validator);
    }

    fn syncValidatorVotingPower(self: *Self, validator: [32]u8) !void {
        const pool = self.stake_pool orelse return;
        const target: u128 = self.mainnet_hooks.getValidatorStake(validator);
        try setPoolVotingPower(pool, validator, target);
    }

    fn syncAllM4VotingPower(self: *Self) !void {
        const pool = self.stake_pool orelse return;
        var it = self.mainnet_hooks.validator_stake.iterator();
        while (it.next()) |entry| {
            try setPoolVotingPower(pool, entry.key_ptr.*, entry.value_ptr.*);
        }
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

        const primary = self.config.authority.signing_key orelse {
            self.cutover.noteProof(false);
            return error.MissingSigningKey;
        };
        var proof_recorded = false;
        errdefer if (!proof_recorded) self.cutover.noteProof(false);

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

        proof_recorded = true;
        self.cutover.noteProof(true);
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
        const applied = try self.mainnet_hooks.applyEquivocationEvidence(
            validator,
            delegator,
            round,
            evidence_payload,
            slash_amount,
        );
        if (applied) {
            try self.syncValidatorVotingPower(validator);
            self.suspendIfJailed(validator);
        }
        return applied;
    }

    pub fn validatorIsJailed(self: *const Self, validator: [32]u8) bool {
        return self.mainnet_hooks.isJailed(validator);
    }

    fn suspendIfJailed(self: *Self, validator: [32]u8) void {
        if (!self.mainnet_hooks.isJailed(validator)) return;
        const quorum = self.quorum orelse return;
        quorum.setMemberActive(validator, false);
    }

    fn reapplyJails(self: *Self) void {
        const quorum = self.quorum orelse return;
        var it = self.mainnet_hooks.jailed_until.iterator();
        while (it.next()) |entry| {
            if (self.mainnet_hooks.isJailed(entry.key_ptr.*)) {
                quorum.setMemberActive(entry.key_ptr.*, false);
            }
        }
    }

    /// Replace object-store state with a verified snapshot, then require every
    /// later checkpoint to continue from that snapshot's checkpoint digest.
    pub fn fastSyncFromSnapshot(self: *Self, bytes: []const u8, later: []const StateSnapshot.ChainLink) !StateSnapshot.Header {
        const store = self.object_store orelse return error.ObjectStoreNotAvailable;
        const hdr = try StateSnapshot.header(bytes);
        if (!StateSnapshot.verifyContinuation(hdr.checkpoint_digest, later)) return error.BrokenCheckpointChain;
        return store.importStateSnapshot(bytes);
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

    fn syncExecutorEpoch(self: *Self) void {
        const em = self.epoch_manager orelse return;
        const epoch = em.getCurrentEpoch();
        const ms: u64 = if (epoch.start_time > 0)
            std.math.mul(u64, @as(u64, @intCast(epoch.start_time)), 1000) catch std.math.maxInt(u64)
        else
            0;
        self.executor.setEpoch(epoch.number, ms);
        self.mainnet_hooks.setClock(epoch.start_time);
    }

    /// Phase 2: advance epoch, sync stake changes to quorum, execute approved proposals.
    pub fn advanceEpoch(self: *Self) !void {
        const sp = self.stake_pool orelse return error.NotRunning;
        const quorum = self.quorum orelse return error.NotRunning;
        const epoch_bridge = self.epoch_bridge orelse return error.NotRunning;

        if (self.config.consensus.epoch_reward > 0) {
            _ = try self.mainnet_hooks.distributeEpochRewards(self.config.consensus.epoch_reward);
            try self.syncAllM4VotingPower();
        }

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
        self.syncExecutorEpoch();
        self.reapplyJails();

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

test "Node wires enforce_gas_payment and seeds allowlist plus local pubkey" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_gas_ledger";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};

    const sponsor: [32]u8 = @splat(0xA1);
    const seed_sk: [32]u8 = @splat(0x42);
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_sk);
    const local_addr = kp.public_key.toBytes();

    const allowlist = try allocator.dupe([32]u8, &[_][32]u8{sponsor});
    defer allocator.free(allowlist);

    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    config.vm.enforce_gas_payment = true;
    config.vm.initial_gas_balance = 777_000;
    config.authority.signing_key = seed_sk;
    config.authority.gas_station_allowlist = allowlist;

    const node = try Node.init(allocator, config, .{});
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    try std.testing.expect(node.executor.enforce_gas_payment);
    try std.testing.expectEqual(@as(u64, 777_000), node.executor.getGasBalance(sponsor));
    try std.testing.expectEqual(@as(u64, 777_000), node.executor.getGasBalance(local_addr));
    try std.testing.expect(node.executor.object_store != null);
}

test "Node creditGas and getGasBalance wrappers" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_gas_credit";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};

    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    // enforce_gas_payment stays false (default); ledger APIs still work.

    const node = try Node.init(allocator, config, .{});
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    const addr: [32]u8 = @splat(0xB2);
    try std.testing.expectEqual(@as(u64, 0), node.getGasBalance(addr));
    try std.testing.expectEqual(@as(u64, 1000), try node.creditGas(addr, 1000));
    try std.testing.expectEqual(@as(u64, 1500), try node.creditGas(addr, 500));
    try std.testing.expectEqual(@as(u64, 1500), node.getGasBalance(addr));
}

test "Node gas balance M4 WAL credit survives restart replay" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_gas_wal_restart";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};

    const addr: [32]u8 = @splat(0xC3);
    const addr2: [32]u8 = @splat(0xC4);

    {
        const config = try allocator.create(Config);
        config.* = Config.default();
        config.storage.data_dir = test_dir;
        const node = try Node.init(allocator, config, .{});
        defer {
            node.deinit();
            allocator.destroy(config);
        }
        try node.start();
        try std.testing.expect(node.m4_wal != null);
        try std.testing.expectEqual(@as(u64, 2000), try node.creditGas(addr, 2000));
        try std.testing.expectEqual(@as(u64, 500), try node.creditGas(addr2, 500));
        try std.testing.expectEqual(@as(u64, 2500), try node.creditGas(addr, 500));
        // Absolute set via executor hook also WAL-logs.
        try node.executor.setGasBalance(addr2, 42);
        try std.testing.expectEqual(@as(u64, 42), node.getGasBalance(addr2));
    }

    {
        const config2 = try allocator.create(Config);
        config2.* = Config.default();
        config2.storage.data_dir = test_dir;
        const node2 = try Node.init(allocator, config2, .{});
        defer {
            node2.deinit();
            allocator.destroy(config2);
            std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
        }
        try node2.start();
        try std.testing.expectEqual(@as(u64, 2500), node2.getGasBalance(addr));
        try std.testing.expectEqual(@as(u64, 42), node2.getGasBalance(addr2));
    }
}

test "Node gas snapshot WAL restores exact map on clean restart" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_gas_snapshot_wal";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};

    // Unsorted insert order; snapshot sorts addresses. `addr_gone` is removed
    // before shutdown so clean-shutdown snapshot must not revive it.
    const addr_hi: [32]u8 = @splat(0xF0);
    const addr_lo: [32]u8 = @splat(0x01);
    const addr_mid: [32]u8 = @splat(0x80);
    const addr_gone: [32]u8 = @splat(0xEE);

    {
        const config = try allocator.create(Config);
        config.* = Config.default();
        config.storage.data_dir = test_dir;
        const node = try Node.init(allocator, config, .{});
        defer {
            node.deinit();
            allocator.destroy(config);
        }
        try node.start();
        try std.testing.expect(node.m4_wal != null);
        try node.executor.setGasBalance(addr_hi, 300);
        try node.executor.setGasBalance(addr_lo, 100);
        try node.executor.setGasBalance(addr_mid, 200);
        try node.executor.setGasBalance(addr_gone, 999);
        _ = node.executor.gas_accounts.remove(addr_gone);
        // Explicit snapshot + clean deinit (truncate → m4ss → m4_gas_snapshot).
        try node.appendGasSnapshotWal();
    }

    {
        const config2 = try allocator.create(Config);
        config2.* = Config.default();
        config2.storage.data_dir = test_dir;
        const node2 = try Node.init(allocator, config2, .{});
        defer {
            node2.deinit();
            allocator.destroy(config2);
            std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
        }
        try node2.start();
        try std.testing.expectEqual(@as(u64, 100), node2.getGasBalance(addr_lo));
        try std.testing.expectEqual(@as(u64, 200), node2.getGasBalance(addr_mid));
        try std.testing.expectEqual(@as(u64, 300), node2.getGasBalance(addr_hi));
        try std.testing.expectEqual(@as(u64, 0), node2.getGasBalance(addr_gone));
        try std.testing.expectEqual(@as(usize, 3), node2.executor.gas_accounts.count());
    }
}

test "Node maybeAppendGasSnapshotWal respects interval and last_*" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_gas_snapshot_maybe";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};

    // interval=0 → always no-op; last_gas_snapshot_at stays 0.
    {
        const config = try allocator.create(Config);
        config.* = Config.default();
        config.storage.data_dir = test_dir;
        config.storage.gas_snapshot_interval_secs = 0;
        const node = try Node.init(allocator, config, .{});
        defer {
            node.deinit();
            allocator.destroy(config);
        }
        try node.start();
        try std.testing.expect(node.m4_wal != null);
        try std.testing.expectEqual(@as(i64, 0), node.last_gas_snapshot_at);
        node.maybeAppendGasSnapshotWal();
        try std.testing.expectEqual(@as(i64, 0), node.last_gas_snapshot_at);
    }

    // interval=1: recent last_* skips; aged last_* appends and advances stamp.
    {
        const config = try allocator.create(Config);
        config.* = Config.default();
        config.storage.data_dir = test_dir;
        config.storage.gas_snapshot_interval_secs = 1;
        const node = try Node.init(allocator, config, .{});
        defer {
            node.deinit();
            allocator.destroy(config);
        }
        try node.start();
        try std.testing.expect(node.m4_wal != null);

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const now: i64 = ts.sec;

        node.last_gas_snapshot_at = now;
        node.maybeAppendGasSnapshotWal();
        try std.testing.expectEqual(now, node.last_gas_snapshot_at);

        node.last_gas_snapshot_at = now - 10;
        node.maybeAppendGasSnapshotWal();
        try std.testing.expect(node.last_gas_snapshot_at >= now);
    }
}

test "Node gas snapshot wipe replaces in-memory map on replay" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_gas_snapshot_wipe";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};

    const a: [32]u8 = @splat(0x11);
    const b: [32]u8 = @splat(0x22);
    const stale: [32]u8 = @splat(0x33);

    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    const node = try Node.init(allocator, config, .{});
    defer {
        node.deinit();
        allocator.destroy(config);
    }
    try node.start();
    try node.executor.setGasBalance(a, 10);
    try node.executor.setGasBalance(b, 20);
    try node.appendGasSnapshotWal();

    // Pollute live map without appending WAL (hook off); snapshot replay must wipe.
    node.executor.setGasBalanceWalHook(null, null);
    try node.executor.setGasBalance(stale, 777);
    try node.executor.setGasBalance(a, 1);
    try node.replayMainnetM4Wal();
    try std.testing.expectEqual(@as(u64, 10), node.getGasBalance(a));
    try std.testing.expectEqual(@as(u64, 20), node.getGasBalance(b));
    try std.testing.expectEqual(@as(u64, 0), node.getGasBalance(stale));
    try std.testing.expectEqual(@as(usize, 2), node.executor.gas_accounts.count());
}

test "Node round advance refuses to wrap" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_round_overflow";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    const node = try Node.init(allocator, config, .{});
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    node.consensus_round = std.math.maxInt(u64) - 1;
    try node.advanceRound();
    try std.testing.expectEqual(std.math.maxInt(u64), node.consensus_round);
    try std.testing.expectError(error.ArithmeticOverflow, node.advanceRound());
    try std.testing.expectEqual(std.math.maxInt(u64), node.consensus_round);
}

test "Node outlives the caller-owned Config it was initialized from" {
    // Regression: `Node` used to retain a borrowed `*const Config`. Callers
    // routinely release the config as soon as `init` returns (and `defer` runs
    // in reverse order, so `deinit` came after the free), leaving `deinit` to
    // read poisoned memory. Every string here is heap-allocated and freed
    // *before* the node is used, so a shallow copy cannot survive.
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_config_ownership";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};

    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = try allocator.dupe(u8, test_dir);
    config.network.p2p_address = try allocator.dupe(u8, "127.0.0.1:0");
    config.network.known_validators = &.{
        .{ .public_key_hex = "0a0b0c", .name = "ownership-probe", .stake = 1 },
    };

    const node = try Node.init(allocator, config, NodeDependencies{});

    // Release every string the caller owned; the node must never touch them.
    allocator.free(config.storage.data_dir);
    allocator.free(config.network.p2p_address);
    allocator.destroy(config);

    try std.testing.expectEqualStrings(test_dir, node.config.storage.data_dir);
    try std.testing.expectEqualStrings("ownership-probe", node.config.network.known_validators[0].name);

    try node.start();
    _ = node.getNodeInfo();
    node.stop();
    node.deinit();
}

test "Node.init releases the owned config copy when init fails" {
    // The arena holding the config copy must be reclaimed on the error path,
    // whichever stage of `init` fails.
    const allocator = std.testing.allocator;
    // `createDir` does not create parents, so a missing grandparent makes
    // `ObjectStore.init` fail after the config copy was handed to the node.
    const missing_parent = "/tmp/node_test_init_failure_parent";
    std.Io.Dir.cwd().deleteTree(std.testing.io, missing_parent) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, missing_parent) catch {};
    const bad_data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{missing_parent});
    defer allocator.free(bad_data_dir);

    const config = try allocator.create(Config);
    defer allocator.destroy(config);
    config.* = Config.default();
    config.storage.data_dir = bad_data_dir;

    // std.testing.allocator reports the leak if the arena is not reclaimed.
    try std.testing.expectError(
        error.FileNotFound,
        Node.init(allocator, config, NodeDependencies{}),
    );
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
    config.authority.signing_key = @as([32]u8, @splat(0x77));
    config.authority.stake = 1_000_000_000;
    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    const stake_id = try node.submitStakeOperation(.{
        .validator = @as([32]u8, @splat(1)),
        .delegator = @as([32]u8, @splat(2)),
        .amount = 100,
        .action = .stake,
    });
    try std.testing.expectEqual(@as(u64, 1), stake_id);
    try std.testing.expectEqual(@as(u128, 100), node.stake_pool.?.getVotingPower(@as([32]u8, @splat(1))));

    const proposal_id = try node.submitGovernanceProposal(.{
        .proposer = @as([32]u8, @splat(3)),
        .title = "reserve-governance",
        .description = "M4 placeholder",
        .kind = .parameter_change,
    });
    try std.testing.expectEqual(@as(u64, 1), proposal_id);

    const slash_id = try node.submitStakeOperation(.{
        .validator = @as([32]u8, @splat(1)),
        .delegator = @as([32]u8, @splat(2)),
        .amount = 10,
        .action = .slash,
        .metadata = "test-equivocation",
    });
    try std.testing.expectEqual(@as(u64, 2), slash_id);
    try std.testing.expectEqual(@as(u128, 90), node.stake_pool.?.getVotingPower(@as([32]u8, @splat(1))));

    const proof = try node.buildCheckpointProof(.{
        .sequence = 1,
        .object_id = @as([32]u8, @splat(4)),
    });
    defer node.freeCheckpointProof(proof);
    try std.testing.expectEqual(@as(u64, 1), proof.sequence);
    try std.testing.expectEqual(@as(usize, 80), proof.proof_bytes.len);
    try std.testing.expect(std.mem.startsWith(u8, proof.signatures, "k3s1"));
}

test "fast sync replaces object state only when the checkpoint chain continues" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/node_test_fast_sync";
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};
    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = test_dir;
    const node = try Node.init(allocator, config, NodeDependencies{});
    defer {
        node.deinit();
        allocator.destroy(config);
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    const store = node.object_store orelse return error.ObjectStoreNotAvailable;
    const id = core.ObjectID.hash("fast-sync");
    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const owner = core.Ownership.ownedBy(@as([32]u8, @splat(1)));
    const data = try allocator.dupe(u8, "kept");
    defer allocator.free(data);
    try store.put(.{ .id = id, .version = version, .ownership = owner, .data = data, .type_tag = 1 });

    const anchor = @as([32]u8, @splat(0x44));
    const blob = try store.exportStateSnapshot(3, anchor);
    defer allocator.free(blob);

    const stale = try allocator.dupe(u8, "stale");
    defer allocator.free(stale);
    try store.put(.{ .id = core.ObjectID.hash("stale"), .version = version, .ownership = owner, .data = stale, .type_tag = 1 });

    const broken = [_]StateSnapshot.ChainLink{
        .{ .digest = @as([32]u8, @splat(0x55)), .previous_digest = @as([32]u8, @splat(0x01)) },
    };
    try std.testing.expectError(error.BrokenCheckpointChain, node.fastSyncFromSnapshot(blob, &broken));

    const later = [_]StateSnapshot.ChainLink{
        .{ .digest = @as([32]u8, @splat(0x55)), .previous_digest = anchor },
    };
    const hdr = try node.fastSyncFromSnapshot(blob, &later);
    try std.testing.expectEqual(@as(u64, 3), hdr.checkpoint_sequence);
    const restored = (try store.get(id)).?;
    defer {
        var copy = restored;
        copy.deinit(allocator);
    }
    try std.testing.expectEqualStrings("kept", restored.data);
    try std.testing.expect((try store.get(core.ObjectID.hash("stale"))) == null);
}
