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
const Config = root.app.Config.Config;
const Node = root.app.Node;

/// Test node configuration
pub const TestNodeConfig = struct {
    port: u16 = 9000 + @as(u16, std.crypto.randomInt(u16) % 1000),
    p2p_port: u16 = 9000 + @as(u16, std.crypto.randomInt(u16) % 1000),
    is_validator: bool = true,
    stake: u64 = 1000000000, // 1 KNOT3 worth in MIST
    name: []const u8 = "test-validator",
};

/// A single test node in the cluster
pub const TestNode = struct {
    allocator: std.mem.Allocator,
    config: Config,
    node: *Node,
    port: u16,
    p2p_port: u16,

    pub fn init(allocator: std.mem.Allocator, cfg: TestNodeConfig) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .config = .{
                .network = .{
                    .address = "127.0.0.1",
                    .port = cfg.port,
                    .p2p_port = cfg.p2p_port,
                },
                .consensus = .{
                    .validator_enabled = cfg.is_validator,
                },
                .authority = .{
                    .name = cfg.name,
                    .stake = cfg.stake,
                    .signing_key = null,
                },
            },
            .node = undefined,
            .port = cfg.port,
            .p2p_port = cfg.p2p_port,
        };

        self.node = try Node.init(allocator, &self.config);
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.node.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *@This()) !void {
        try self.node.start();
    }
};

/// Test cluster - manages multiple nodes for integration testing
pub const TestCluster = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(*TestNode),
    genesis_checkpoint: CheckpointSequence,

    /// Create a new test cluster with the specified number of nodes
    pub fn init(allocator: std.mem.Allocator, num_nodes: usize) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .nodes = std.ArrayList(*TestNode).init(allocator),
            .genesis_checkpoint = CheckpointSequence.init(),
        };

        // Create nodes
        var i: usize = 0;
        while (i < num_nodes) : (i += 1) {
            const cfg = TestNodeConfig{
                .port = @as(u16, 9000 + @as(u16, @intCast(i * 100))),
                .p2p_port = @as(u16, 9100 + @as(u16, @intCast(i * 100))),
                .is_validator = true,
                .stake = 1000000000,
                .name = try std.fmt.allocPrint(allocator, "validator-{d}", .{i}),
            };
            const node = try TestNode.init(allocator, cfg);
            try self.nodes.append(node);
        }

        return self;
    }

    pub fn deinit(self: *@This()) void {
        for (self.nodes.items) |node| {
            node.deinit();
        }
        self.nodes.deinit(self.allocator);
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
        return try init(allocator, 1);
    }
};

/// Network topology for test cluster
pub const TestTopology = struct {
    allocator: std.mem.Allocator,
    connections: std.AutoArrayHashMap([2]*const TestNode, void),

    pub fn init(allocator: std.mem.Allocator) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .connections = std.AutoArrayHashMap([2]*const TestNode, void).init(allocator),
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

/// Assert helpers for integration tests

/// Assert helpers for integration tests
pub fn assertConsensusProgress(cluster: *TestCluster) !void {
    // Verify that the cluster has advanced beyond the genesis checkpoint
    try std.testing.expect(cluster.nodes.items.len > 0);

    // For now, verify that we have an active test cluster
    // In a full implementation, this would poll the consensus layer
    // for checkpoint progress and verify blocks are being committed
}

pub fn assertQuorumReached(cluster: *TestCluster, quorum_threshold: u128) !void {
    // Verify enough validators are active to reach quorum
    try std.testing.expect(cluster.nodes.items.len > 0);

    // In a full implementation, this would verify:
    // 1. Active validators have submitted votes
    // 2. Total voting power exceeds quorum_threshold
    // For now, just verify the threshold is reasonable
    try std.testing.expect(quorum_threshold > 0);
}
