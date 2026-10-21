//! Test Cluster - Multi-node testing infrastructure for zknot3
//!
//! Provides a test cluster of nodes that can communicate and be used
//! for integration testing of consensus, networking, and Move execution.

const std = @import("std");
const root = @import("../../src/root.zig");

const ObjectID = root.core.ObjectID;
const ObjectStore = root.form.storage.ObjectStore;
const CheckpointSequence = root.form.storage.CheckpointSequence;
const Mysticeti = root.form.consensus.Mysticeti;
const Quorum = root.form.consensus.Quorum;
const QuorumConfig = root.form.consensus.QuorumConfig;
const Signature = @import("../../src/property/Signature.zig");
const Validator = root.form.consensus.Validator.Validator;
const HTTPServer = root.form.network.HTTPServer;
const RPCServer = root.form.network.RPCServer;
const P2PNode = root.form.network.P2P.P2PNode;
const PeerManager = root.form.network.P2P.PeerManager;
const Transport = root.form.network.Transport;
const Indexer = root.app.Indexer.Indexer;
const EpochManager = root.metric.Epoch.EpochManager;
const StakePool = root.metric.Stake.StakePool;
const Ingress = root.pipeline.Ingress;
const Executor = root.pipeline.Executor;
const Egress = root.pipeline.Egress;
const Config = root.app.Config;
const NetworkConfig = @import("../../src/app/Config.zig").NetworkConfig;
const NodeDependencies = root.app.NodeDependencies;
const Node = root.app.Node;

/// Base ports for a test cluster. High enough to avoid a developer's local
/// node (default 9003/8083) but low enough to stay below the ephemeral range
/// that macOS/Linux hand out randomly.
///
/// `TestCluster.init` derives node ports from these plus the node index. Each
/// *test* must therefore use a different cluster base, or a second cluster in
/// the same process will fail with `error.AddressInUse`. Tests should call
/// `uniqueCluster` rather than hard-coding a base.
/// Stake assigned to each genesis validator in a test cluster.
pub const genesis_stake: u64 = 1_000_000_000_000;

pub const base_rpc_port: u16 = 19003;
pub const base_p2p_port: u16 = 18083;

/// Monotonic counter handing out non-overlapping port bases, so multiple
/// clusters created in one test binary never collide.
var cluster_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Next free port base for a cluster.
fn nextClusterBase() struct { rpc: u16, p2p: u16 } {
    const n = cluster_seq.fetchAdd(1, .monotonic);
    // 40 ports of separation keeps every cluster well clear of the next.
    const step: u32 = 40;
    // Offset the base by pid so separate `zig build` processes (and concurrent
    // jobs on one runner) do not all start from the same port and race. Linux
    // keeps closed listeners in TIME_WAIT, so a fixed base makes a rerun collide
    // with the previous run's sockets.
    const pid = std.c.getpid();
    const jitter: u32 = @as(u32, @intCast(@mod(@as(i64, pid), 97))) * step;
    const off = (n * step + jitter) % 4000;
    return .{
        .rpc = base_rpc_port + @as(u16, @intCast(off)),
        .p2p = base_p2p_port + @as(u16, @intCast(off)),
    };
}

/// Test node configuration
pub const TestNodeConfig = struct {
    /// RPC port. Must be unique per node in a cluster.
    port: u16 = 0,
    /// P2P port. Must be unique per node and different from `port`.
    p2p_port: u16 = 0,
    /// Enable validator mode. Validators require a signing key, which
    /// `TestNode.init` derives from `key_seed`.
    is_validator: bool = true,
    /// Validator stake. The cluster gives every node the same stake by default
    /// so that quorum thresholds are predictable (4 equal validators =>
    /// a quorum needs 3).
    stake: u64 = 1000000000, // 1 KNOT3 worth in MIST
    /// Human-readable name, also used to derive a distinct key.
    name: []const u8 = "test-validator",
    /// Seed for the validator's signing key. Each node in a cluster must get a
    /// distinct seed, otherwise they share an identity and BFT safety checks
    /// become meaningless.
    key_seed: [32]u8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    /// Data directory. Must be unique per node so nodes do not share state.
    /// When null, `TestNode.init` provisions a unique temp directory.
    data_dir: ?[]const u8 = null,
    /// Genesis validator set. `Node.init` bootstraps `stake_pool` from this, and
    /// without it a node's quorum has zero total stake and no validators.
    known_validators: []const NetworkConfig.KnownValidator = &.{},
};

/// A single test node in the cluster
pub const TestNode = struct {
    allocator: std.mem.Allocator,
    config: Config,
    node: *Node,
    port: u16,
    p2p_port: u16,
    /// True when this node owns a temp dir it must remove on deinit.
    owns_data_dir: bool,
    /// Buffers owned by this node and freed on deinit.
    owned_name: []const u8,
    owned_p2p_address: []const u8,
    owned_peer_id: []const u8,

    /// Build a config that actually satisfies `Config.validate`. The previous
    /// version of this file set fields that no longer exist (`.network.address`,
    /// `.network.port`, `.consensus.validator_enabled` at the wrong level) and
    /// left `signing_key` null, so `Node.validateConfig` rejected every
    /// validator. It compiled only because no test referenced this code, so
    /// nothing ever type-checked it.
    pub fn makeConfig(allocator: std.mem.Allocator, cfg: TestNodeConfig) !Config {
        var data_dir_buf: [64]u8 = undefined;

        const config = Config{
            .is_dev = true,
            .is_validator = cfg.is_validator,
            .network = .{
                .bind_address = "127.0.0.1",
                .rpc_port = cfg.port,
                .p2p_enabled = true,
                // `P2PServer` binds `bind_address` verbatim and falls back to
                // port 8083 when no port is present, so the port must be part
                // of this string or every node in the cluster fights over 8083.
                .p2p_address = try allocator.print(
                    "127.0.0.1:{d}",
                    .{cfg.p2p_port},
                ),
                .p2p_port = cfg.p2p_port,
                // Loopback binding does not require an admin token, and an
                // empty token would make every write RPC fail.
                .admin_token = "",
                // Each node needs its own metrics port or they collide.
                .metrics_enabled = false,
                // Distinct local peer ids, or peers would reject each other.
                // Duplicated: the caller may free `cfg.name` as soon as
                // `TestNode.init` returns, so aliasing it here would leave a
                // dangling slice in the node's config.
                .local_peer_id = try allocator.dupe(u8, cfg.name),
                .known_validators = cfg.known_validators,
            },
            .consensus = .{
                .validator_enabled = cfg.is_validator,
                // A 4-validator cluster is the BFT minimum; keep the range wide
                // enough that `validate` accepts it.
                .min_validators = 4,
                .target_validators = 4,
                .max_validators = 8,
                .vote_quorum = 3,
            },
            .storage = .{
                .data_dir = blk: {
                    if (cfg.data_dir) |d| break :blk d;
                    // Unique per node: same port prefix, distinct suffix.
                    const n = std.mem.print(&data_dir_buf, "/tmp/zknot3-cluster-{s}-{d}", .{
                        cfg.name, cfg.port,
                    }) catch return error.NoSpaceLeft;
                    break :blk try allocator.dupe(u8, n);
                },
                // Keep the test footprint small; the defaults are sized for
                // production nodes.
                .cache_size = 4 * 1024 * 1024,
            },
            .authority = .{
                // Duplicated so the node owns this buffer; the caller keeps
                // ownership of `cfg.name`.
                .name = try allocator.dupe(u8, cfg.name),
                .stake = cfg.stake,
                // Required for validators: Node.validateConfig rejects a
                // validator without a signing key.
                .signing_key = if (cfg.is_validator) deriveSigningKey(cfg.key_seed) else null,
            },
            // Loopback test cluster; unauthenticated P2P would otherwise be
            // rejected outside dev mode.
            .allow_unauthenticated_p2p = false,
        };

        // Never let two nodes in one cluster share an RPC port, and never let
        // RPC collide with P2P — Config.validate rejects both.
        if (config.network.rpc_port == config.network.p2p_port) return error.PortConflict;

        return config;
    }

    /// Deterministic 32-byte signing key for a test validator.
    fn deriveSigningKey(seed: [32]u8) [32]u8 {
        var out: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(&seed, &out, .{});
        return out;
    }

    pub fn init(allocator: std.mem.Allocator, cfg: TestNodeConfig) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);

        const config = try makeConfig(allocator, cfg);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .node = undefined,
            .port = cfg.port,
            .p2p_port = cfg.p2p_port,
            .owns_data_dir = cfg.data_dir == null,
            .owned_name = config.authority.name,
            .owned_p2p_address = config.network.p2p_address,
            .owned_peer_id = config.network.local_peer_id,
        };

        // `Node.init` takes a `NodeDependencies` bag; the other integration tests pass
        // an empty one and let the node build its own components.
        self.node = try Node.init(allocator, &self.config, NodeDependencies{});
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.node.deinit();
        // Only clean up the path when we allocated it in `makeConfig`.
        if (self.owns_data_dir) {
            // Remove the tree before freeing the path buffer.
            std.Io.Dir.cwd().deleteTree(std.testing.io, self.config.storage.data_dir) catch {};
            self.allocator.free(self.config.storage.data_dir);
            self.config.storage.data_dir = "";
        }
        self.allocator.free(self.owned_name);
        self.owned_name = "";
        // Only owned when `makeConfig` allocated it (not a caller-supplied one).
        if (self.owns_data_dir) {
            self.allocator.free(self.owned_p2p_address);
            self.owned_p2p_address = "";
        }
        self.allocator.free(self.owned_peer_id);
        self.owned_peer_id = "";
        self.allocator.destroy(self);
    }

    /// Start the node. Validators only pass `Config.validate` once a signing
    /// key and a unique data dir are configured, which `init` now handles.
    pub fn start(self: *@This()) !void {
        try self.node.start();
    }

    pub fn stop(self: *@This()) void {
        self.node.stop();
    }
};

/// Test cluster - manages multiple nodes for integration testing
pub const TestCluster = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(*TestNode),
    genesis_checkpoint: CheckpointSequence,
    /// Genesis validator table. Each node's `Config.network.known_validators`
    /// points into this, so it must outlive every node.
    genesis: []NetworkConfig.KnownValidator,
    /// Backing hex strings for `genesis[i].public_key_hex`, owned here.
    genesis_hex: [][]u8,

    /// Create a new test cluster with the specified number of nodes.
    ///
    /// Ports are offset per node index so a cluster does not collide with
    /// itself, and each node gets a distinct key seed so the four validators
    /// are four different identities rather than one identity cloned four
    /// times. Base ports are high and unlikely to clash with a developer's
    /// running node.
    /// Create a cluster bound to an explicit port base. Callers should prefer
    /// `initUnique`, which picks a base that cannot collide with other
    /// clusters in the same process.
    pub fn init(
        allocator: std.mem.Allocator,
        num_nodes: usize,
        rpc_base: u16,
        p2p_base: u16,
    ) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .nodes = .empty,
            .genesis_checkpoint = CheckpointSequence.init(),
            .genesis = &.{},
            .genesis_hex = &.{},
        };
        errdefer self.nodes.deinit(allocator);

        // Genesis validator set, shared by every node in the cluster.
        // `Node.init` bootstraps `stake_pool` from this; without it a node has
        // zero total stake and no validators, so no quorum can ever form.
        const genesis = try allocator.alloc(NetworkConfig.KnownValidator, num_nodes);
        errdefer allocator.free(genesis);
        const hex_bufs = try allocator.alloc([]u8, num_nodes);
        errdefer allocator.free(hex_bufs);
        for (0..num_nodes) |g| {
            // `public_key_hex` is parsed as a u256 and written into a 32-byte
            // id, so it must be 64 hex digits. A distinct leading byte keeps
            // the derived validator ids unique.
            // 64 hex digits = 32-byte validator id. `Node.init` parses this as
            // a u256 and writes it big-endian into the id.
            // `known_validators[i].public_key_hex` must be the validator's
            // actual Ed25519 public key -- that is what `stake_pool` is keyed by
            // and what `receiveVote` resolves a voter's weight from. Deriving it
            // from the same seed the validator signs with keeps a single
            // identity across the genesis table, the stake pool and the votes.
            const keys = validatorKey(@intCast(g));
            var hex_buf: [64]u8 = undefined;
            const written = std.mem.print(&hex_buf, "{x}", .{keys.pubkey[0..]}) catch return error.NoSpaceLeft;
            const hex = try allocator.dupe(u8, written);
            hex_bufs[g] = hex;
            genesis[g] = .{ .public_key_hex = hex, .name = "", .stake = genesis_stake };
        }

        // Hand ownership to the cluster so it lives as long as the nodes do.
        self.genesis = genesis;
        self.genesis_hex = hex_bufs;

        var i: usize = 0;
        while (i < num_nodes) : (i += 1) {
            const name = try allocator.print("validator-{d}", .{i});
            defer allocator.free(name);
            // Distinct identity per node: seed the key from the index.
            var seed = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
            seed[0] = @intCast(i + 1);

            const cfg = TestNodeConfig{
                .known_validators = genesis,
                .port = rpc_base + @as(u16, @intCast(i * 10)),
                .p2p_port = p2p_base + @as(u16, @intCast(i * 10)),
                .is_validator = true,
                .stake = 1000000000,
                .name = name,
                .key_seed = seed,
            };
            // `TestNode.init` duplicates the name, so the local buffer can be
            // released as soon as the node is constructed.
            const node = try TestNode.init(allocator, cfg);
            try self.nodes.append(allocator, node);
        }

        return self;
    }

    pub fn deinit(self: *@This()) void {
        // Each node owns and frees its own duplicated name and data dir.
        for (self.nodes.items) |node| {
            node.deinit();
        }
        self.nodes.deinit(self.allocator);
        // Free genesis only after every node (which references it) is gone.
        for (self.genesis_hex) |h| self.allocator.free(h);
        self.allocator.free(self.genesis_hex);
        self.allocator.free(self.genesis);
        self.genesis_checkpoint.deinit();
        self.allocator.destroy(self);
    }

    /// Start all nodes in the cluster
    pub fn startAll(self: *@This()) !void {
        for (self.nodes.items) |node| {
            try node.start();
        }
    }

    /// Get node by index
    pub fn getNode(self: *@This(), idx: usize) ?*TestNode {
        if (idx >= self.nodes.items.len) return null;
        return self.nodes.items[idx];
    }

    /// Get the total number of nodes
    pub fn nodeCount(self: *@This()) usize {
        return self.nodes.items.len;
    }

    /// Create a simple 4-node test cluster (2f+1 for BFT)
    pub fn create4NodeCluster(allocator: std.mem.Allocator) !*@This() {
        return try init(allocator, 4);
    }

    /// Create a single node for simple tests
    pub fn createSingleNode(allocator: std.mem.Allocator) !*@This() {
        const b = nextClusterBase();
        return try init(allocator, 1, b.rpc, b.p2p);
    }

    /// Create a cluster on a port base unique to this call. Use this in tests
    /// that may run alongside other cluster-building tests.
    pub fn initUnique(allocator: std.mem.Allocator, num_nodes: usize) !*@This() {
        const b = nextClusterBase();
        return try init(allocator, num_nodes, b.rpc, b.p2p);
    }
};

/// Network topology for test cluster
pub const TestTopology = struct {
    allocator: std.mem.Allocator,
    connections: std.AutoArrayHashMapUnmanaged([2]*const TestNode, void),

    pub fn init(allocator: std.mem.Allocator) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .connections = std.AutoArrayHashMapUnmanaged().init(allocator, &.{}, &.{}),
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.connections.deinit();
        self.allocator.destroy(self);
    }

    /// Connect two nodes bidirectionally
    pub fn connect(self: *@This(), a: *TestNode, b: *TestNode) !void {
        const key = if (@intFromPtr(a) < @intFromPtr(b)) .{ a, b } else .{ b, a };
        try self.connections.put(key, {});
    }

    /// Create a full mesh topology (all nodes connected to all others)
    pub fn createFullMesh(cluster: *TestCluster) !void {
        for (cluster.nodes.items) |node_a| {
            for (cluster.nodes.items) |node_b| {
                if (node_a != node_b) {
                    try connect(node_a, node_b);
                }
            }
        }
    }
};

/// Test transaction builder
pub const TestTransaction = struct {
    sender: [32]u8,
    sequence: u64,
    program: []const u8,
    gas_budget: u64,

    /// Build a simple "ld_true; ret" Move bytecode
    pub fn simpleReturn() []const u8 {
        return &.{ 0x31, 0x01 }; // ld_true; ret
    }

    /// Build a KNOT3 transfer bytecode
    pub fn transfer(recipient: ObjectID, amount: u64) []const u8 {
        _ = recipient;
        _ = amount;
        // Simplified - actual Move bytecode would be more complex
        return &.{ 0x31, 0x01 };
    }
};

/// Snapshot helpers backed by `Node.getNodeInfo`, the only public window into
/// node state. The assertions these replace previously checked
/// `nodes.len > 0` and therefore verified nothing at all.
pub fn committedCount(node: *TestNode) usize {
    return node.node.getNodeInfo().committed_blocks;
}

pub fn pendingCount(node: *TestNode) usize {
    return node.node.getNodeInfo().pending_blocks;
}

/// Total stake the node's quorum tracks.
pub fn totalStake(node: *TestNode) u128 {
    return node.node.getNodeInfo().total_stake;
}

/// Number of validators the node knows about.
pub fn validatorCount(node: *TestNode) usize {
    return node.node.getNodeInfo().validator_count;
}

/// True once `start()` has completed and the node is serving.
pub fn isRunning(node: *TestNode) bool {
    return std.mem.eql(u8, node.node.getNodeInfo().state, "running");
}

/// Assert that at least one block has been committed cluster-wide.
pub fn assertConsensusProgress(cluster: *TestCluster) !void {
    try std.testing.expect(cluster.nodes.items.len > 0);
    var progressed = false;
    for (cluster.nodes.items) |node| {
        if (committedCount(node) > 0) progressed = true;
    }
    try std.testing.expect(progressed);
}

/// Assert that `threshold` is a meaningful quorum bound for this cluster: it
/// must be positive and must not exceed the total stake the cluster's
/// validators are configured with.
///
/// Note this deliberately uses the *configured* stake, not the node's live
/// quorum view: a node started in a test has no genesis validator set yet, so
/// `totalStake(node)` is 0.
pub fn assertQuorumReached(cluster: *TestCluster, threshold: u128) !void {
    try std.testing.expect(cluster.nodes.items.len > 0);
    try std.testing.expect(threshold > 0);

    // Every node must expose a validator set, and the threshold must fit inside
    // the stake those validators actually carry.
    for (cluster.nodes.items) |node| {
        try std.testing.expect(validatorCount(node) > 0);
        try std.testing.expect(threshold <= totalStake(node));
    }
}

test "cluster: TestNode config satisfies Config.validate" {
    const allocator = std.testing.allocator;
    var node = try TestNode.init(allocator, .{
        .port = base_rpc_port + 2,
        .p2p_port = base_p2p_port + 2,
        .is_validator = true,
        .name = "solo-validator",
        .key_seed = @splat(7),
    });
    defer node.deinit();

    try node.config.validate();
    try node.node.validateConfig();
}

// ---------------------------------------------------------------------------
// Multi-node tests
//
// These start real `Node` instances on real loopback ports and drive the real
// consensus ingress path (`receiveBlock` / `receiveVote` / `tryCommitBlocks`).
// Each node is a distinct validator with a distinct signing key and its own
// data directory.
// ---------------------------------------------------------------------------

/// Deterministic Ed25519 keypair for validator `idx`.
fn validatorKey(idx: u8) struct { pubkey: [32]u8, privkey: [32]u8 } {
    // Must match how the test cluster builds its genesis table: seed `i+1`
    // repeated, whose derived public key is `known_validators[i]`. `Seed` is
    // `@splat(idx + 1)` so both sides agree.
    const priv: [32]u8 = @splat(idx + 1);
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(priv) catch unreachable;
    return .{ .pubkey = kp.public_key.toBytes(), .privkey = priv };
}

/// Start a 4-validator cluster. Each node binds its own RPC and P2P ports.
fn startCluster(allocator: std.mem.Allocator) !*TestCluster {
    const cluster = try TestCluster.initUnique(allocator, 4);
    errdefer cluster.deinit();
    try cluster.startAll();
    return cluster;
}

test "cluster: 4 validators start on distinct ports with distinct identities" {
    const allocator = std.testing.allocator;
    var cluster = try startCluster(allocator);
    defer cluster.deinit();

    try std.testing.expectEqual(@as(usize, 4), cluster.nodeCount());

    // Every node must actually be serving.
    for (cluster.nodes.items) |node| {
        try std.testing.expect(isRunning(node));
    }

    // Ports and identities must be distinct, otherwise the "cluster" is one
    // node wearing four hats and every consensus assertion below is vacuous.
    var seen_ports = std.AutoHashMap(u16, void).init(allocator);
    defer seen_ports.deinit();
    var seen_peers = std.StringHashMap(void).init(allocator);
    defer seen_peers.deinit();
    var seen_keys = std.AutoHashMap([32]u8, void).init(allocator);
    defer seen_keys.deinit();

    for (cluster.nodes.items) |node| {
        // `fetchPut` yields the previous value, so a null result proves this
        // identifier had not been seen before.
        try std.testing.expect((try seen_ports.fetchPut(node.port, {})) == null);
        try std.testing.expect((try seen_peers.fetchPut(node.config.network.local_peer_id, {})) == null);
        try std.testing.expect((try seen_keys.fetchPut(node.config.authority.signing_key.?, {})) == null);
        // Data dirs must not be shared, or nodes overwrite each other's state.
        try std.testing.expect(node.config.storage.data_dir.len > 0);
    }

    // 4 equal-stake validators: quorum needs 3 of 4.
    try std.testing.expectEqual(@as(usize, 4), validatorCount(cluster.nodes.items[0]));
}

/// Build a signed vote for `block` from validator `idx`, using the same
/// signing message and 96-byte field convention as `Mysticeti.createVote`.
fn makeVote(
    node: *TestNode,
    idx: usize,
    block: *const Mysticeti.Block,
) !Mysticeti.Vote {
    // The voter id must be the genesis id: `receiveVote` now resolves each
    // voter's weight from the stake pool, which is keyed by
    // `known_validators[i].public_key_hex`. A freshly derived keypair id would
    // carry zero weight and be dropped.
    const voter = node.node.genesisValidatorId(idx) orelse return error.TestUnexpectedResult;
    const keys = validatorKey(@intCast(idx));
    const message = Mysticeti.QuorumCertificate.signedMessage(block.round, block.digest);
    // Sign through the project's own Ed25519 wrapper -- the same primitive
    // `Vote.verifySignature` checks against.
    const ed = try Signature.Ed25519.sign(keys.privkey, &message);
    var wide: [96]u8 = @splat(0);
    @memcpy(wide[0..64], &ed);
    return Mysticeti.Vote{
        .voter = voter,
        .stake = 0, // overwritten by the receiver with the authoritative weight
        .round = block.round,
        .block_digest = block.digest,
        .signature = wide,
    };
}

test "cluster: a block proposed and voted by 3 of 4 validators reaches quorum" {
    const allocator = std.testing.allocator;
    var cluster = try startCluster(allocator);
    defer cluster.deinit();

    const proposer = cluster.nodes.items[0];
    const node_allocator = proposer.node.allocator;
    const stake_each: u128 = proposer.config.authority.stake;

    // The proposer creates a block and serializes it for the peers.
    const block = (try proposer.node.proposeBlock("multi-node-payload")) orelse
        return error.TestUnexpectedResult;
    const block_bytes = try block.serialize(node_allocator);
    defer node_allocator.free(block_bytes);

    // Deliver the proposal through the real ingress path.
    for (cluster.nodes.items[1..]) |peer| {
        try peer.node.receiveBlock(block_bytes);
    }
    // Every node now holds the pending block.
    for (cluster.nodes.items) |node| {
        try std.testing.expect(pendingCount(node) > 0);
    }

    // Three of four validators sign and vote -- exactly the BFT minimum.
    // The fourth abstains, so this also proves 2-of-4 would be insufficient.
    var accepted: usize = 0;
    var rejected: usize = 0;
    for (0..3) |i| {
        const vote = try makeVote(proposer, i, block);
        // Must pass the node's own signature check.
        try std.testing.expect(vote.verifySignature());

        const vote_bytes = try vote.serialize(node_allocator);
        defer node_allocator.free(vote_bytes);

        for (cluster.nodes.items) |target| {
            const res = try target.node.receiveVote(vote_bytes);
            switch (res) {
                .accepted => accepted += 1,
                .duplicate => {},
                .ignored_invalid => rejected += 1,
                .equivocation => return error.TestUnexpectedResult,
            }
        }
    }

    // Each vote must be accepted by the proposer and by all three peers: a
    // node that rejected one would hold a different view of the block, and the
    // quorum arithmetic below would prove nothing. A duplicate is acceptable
    // only if it came from a node that had already seen that exact vote.
    try std.testing.expectEqual(@as(usize, 12), accepted);
    try std.testing.expectEqual(@as(usize, 0), rejected);

    // Quorum arithmetic on the unified threshold: with 4 equal stakes a quorum
    // needs 3 of 4.
    //
    // The node bootstraps its stake pool from the genesis validator set, so the
    // live quorum view must now carry all 4 validators and their stake. Before
    // `TestCluster` supplied `known_validators` these were 0 and no quorum
    // could ever form.
    const live_total = totalStake(proposer);
    try std.testing.expectEqual(@as(usize, 4), validatorCount(proposer));
    try std.testing.expectEqual(@as(u128, genesis_stake * 4), live_total);

    // Every node must agree on the validator set, otherwise they cannot agree
    // on quorum.
    for (cluster.nodes.items) |n| {
        try std.testing.expectEqual(@as(usize, 4), validatorCount(n));
        try std.testing.expectEqual(live_total, totalStake(n));
    }

    // The quorum threshold is denominated in the genesis validators' stake
    // (1e12 each), while the votes above carry each node's configured
    // `authority.stake` (1e9). Both scales are checked, but the accept/reject
    // boundary is only meaningful in the denomination the node uses.
    const cluster_total = live_total;
    const thr = QuorumConfig.thresholdOf(cluster_total);

    // 2 of 4 genesis stakes is not a strict majority; 3 of 4 is.
    const two_gen = @as(u128, genesis_stake) * 2;
    const three_gen = @as(u128, genesis_stake) * 3;
    try std.testing.expect(!QuorumConfig.accepts(two_gen, cluster_total));
    try std.testing.expect(QuorumConfig.accepts(three_gen, cluster_total));
    try std.testing.expect(three_gen > thr);

    // 3 of 4 voters also exceeds the threshold measured in the *vote* scale,
    // because 3/4 > 2/3 regardless of the unit.
    const vote_total = stake_each * 4;
    try std.testing.expect(!QuorumConfig.accepts(stake_each * 2, vote_total));
    try std.testing.expect(QuorumConfig.accepts(stake_each * 3, vote_total));

    try assertQuorumReached(cluster, thr);
}

test "cluster: a vote from an unknown signature is rejected by every node" {
    const allocator = std.testing.allocator;
    var cluster = try startCluster(allocator);
    defer cluster.deinit();

    const proposer = cluster.nodes.items[0];
    const node_allocator = proposer.node.allocator;

    const block = (try proposer.node.proposeBlock("forged-vote-payload")) orelse
        return error.TestUnexpectedResult;
    const block_bytes = try block.serialize(node_allocator);
    defer node_allocator.free(block_bytes);
    for (cluster.nodes.items[1..]) |peer| {
        try peer.node.receiveBlock(block_bytes);
    }

    // Forge a vote: correct shape, valid stake, but signed by the wrong key.
    var forged = try makeVote(proposer, 0, block);
    forged.voter = @splat(0xEE);
    // Self-check must fail: the signature does not match the claimed voter.
    try std.testing.expect(!forged.verifySignature());

    const forged_bytes = try forged.serialize(node_allocator);
    defer node_allocator.free(forged_bytes);

    // No node may accept it.
    for (cluster.nodes.items) |target| {
        const res = try target.node.receiveVote(forged_bytes);
        try std.testing.expect(res == .ignored_invalid);
    }
}

test "cluster: an equivocating voter yields equivocation evidence" {
    const allocator = std.testing.allocator;
    var cluster = try startCluster(allocator);
    defer cluster.deinit();

    const proposer = cluster.nodes.items[0];
    const node_allocator = proposer.node.allocator;

    // Two competing blocks in the same round.
    const block_a = (try proposer.node.proposeBlock("fork-A")) orelse
        return error.TestUnexpectedResult;
    // NOTE: no `deinit` for block_a/block_b — `Node.proposeBlock` and
    // `receiveBlock` both hand ownership to the node's `pending_blocks` map,
    // which frees them. Deiniting here would double-free.
    const a_bytes = try block_a.serialize(node_allocator);
    defer node_allocator.free(a_bytes);

    var block_b = try Mysticeti.Block.create(
        @as([32]u8, @splat(2)),
        block_a.round,
        "fork-B",
        &.{},
        node_allocator,
    );
    // block_b is created locally and then ingested by `receiveBlock`, which
    // deserializes its own copy into the pending map. Our instance is
    // therefore ours to free.
    defer block_b.deinit(node_allocator);
    const b_bytes = try block_b.serialize(node_allocator);
    defer node_allocator.free(b_bytes);

    try proposer.node.receiveBlock(a_bytes);
    try proposer.node.receiveBlock(b_bytes);

    // The same validator signs both forks in the same round.
    const vote_a = try makeVote(proposer, 0, block_a);
    const a_vote = try vote_a.serialize(node_allocator);
    defer node_allocator.free(a_vote);
    const vote_b = try makeVote(proposer, 0, &block_b);
    const b_vote = try vote_b.serialize(node_allocator);
    defer node_allocator.free(b_vote);

    // First vote is accepted; the second is flagged as equivocation.
    const first = try proposer.node.receiveVote(a_vote);
    try std.testing.expect(first == .accepted);
    const second = try proposer.node.receiveVote(b_vote);
    switch (second) {
        .equivocation => |ev| {
            try std.testing.expectEqual(vote_a.voter, ev.voter);
            try std.testing.expect(!std.mem.eql(u8, &ev.first_block_digest, &ev.conflicting_block_digest));
            // The evidence must actually name the two conflicting forks.
            try std.testing.expectEqual(block_a.digest, ev.first_block_digest);
            try std.testing.expect(!std.mem.eql(u8, &ev.first_signature, &ev.conflicting_signature));
        },
        else => return error.TestUnexpectedResult,
    }
}
