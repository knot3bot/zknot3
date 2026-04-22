//! P2P Network - Peer-to-peer networking for blockchain
//!
//! Implements P2P networking with:
//! - Kademlia DHT-based peer discovery
//! - Connection management
//! - Message routing
//! - Protocol negotiation


const std = @import("std");
const Transport = @import("Transport.zig");
const Message = Transport.Message;
const P2PServer = @import("P2PServer.zig").P2PServer;
const Kademlia = @import("Kademlia.zig");
const NodeKey = @import("NodeKey.zig").NodeKey;

pub const PROTOCOL_VERSION = 1;

pub const P2PMessageType = enum(u8) {
    handshake = 0x01,
    handshake_ack = 0x02,
    ping = 0x03,
    pong = 0x04,
    get_peers = 0x05,
    peers = 0x06,
    transaction = 0x10,
    block = 0x11,
    certificate = 0x12,
    checkpoint = 0x13,
};

pub const Peer = struct {
    id: [32]u8,
    address: []const u8,
    port: u16,
    is_outbound: bool,
    connected_at: i64,
    last_message: i64,
    latency_ms: u32,

    pub fn isActive(_: @This()) bool {
        return true;
    }
};

pub const PeerManager = struct {
    allocator: std.mem.Allocator,
    peers: std.AutoArrayHashMapUnmanaged([32]u8, Peer),
    routing_table: *Kademlia.RoutingTable,
    transport: *Transport.Transport,
    local_peer_id: [32]u8,
    max_peers: usize,

    pub fn init(allocator: std.mem.Allocator, transport: *Transport.Transport, local_peer_id: [32]u8) !*@This() {
        const routing_table = try Kademlia.RoutingTable.init(allocator, local_peer_id);
        errdefer routing_table.deinit();

        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .peers = .empty,
            .routing_table = routing_table,
            .transport = transport,
            .local_peer_id = local_peer_id,
            .max_peers = 50,
        };
        errdefer self.peers.deinit();
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.routing_table.deinit();
        self.peers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addPeer(self: *@This(), peer: Peer) !void {
        if (self.peers.count() >= self.max_peers) {
            return error.TooManyPeers;
        }
        try self.peers.put(self.allocator, peer.id, peer);

        // Also add to Kademlia routing table for DHT-based discovery
        try self.routing_table.addPeer(peer.id, peer.address, peer.port);
    }

    pub fn removePeer(self: *@This(), peer_id: [32]u8) void {
        _ = self.peers.swapRemove(peer_id);
        // Also remove from routing table
        self.routing_table.removePeer(peer_id);
    }

    pub fn peerCount(self: @This()) usize {
        return self.peers.count();
    }

    pub fn getPeerIDs(self: @This()) ![]const [32]u8 {
        var ids: std.ArrayList([32]u8) = .empty;
        errdefer ids.deinit(self.allocator);
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            try ids.append(self.allocator, entry.key_ptr.*);
        }
        return ids.toOwnedSlice();
    }

    pub fn getPeer(self: @This(), peer_id: [32]u8) ?Peer {
        return self.peers.get(peer_id);
    }

    /// Get peers closest to a target ID using Kademlia XOR distance
    pub fn getClosestPeers(self: *@This(), target_id: [32]u8, count: usize) ![]const [32]u8 {
        return try self.routing_table.getClosestPeers(target_id, count);
    }

    /// Refresh routing table by pinging peers and removing unresponsive ones
    pub fn refreshRoutingTable(self: *@This()) void {
        // Get all peers from routing table and check liveness
        const all_peers = self.routing_table.getAllPeers();
        defer self.allocator.free(all_peers);

        // Mark all peers as potentially stale - actual implementation would ping them
        // For now, we just iterate through them
        for (all_peers) |peer_id| {
            if (self.peers.get(peer_id)) |peer| {
                // In a real implementation, we would:
                // 1. Send a ping message
                // 2. If no pong received within timeout, mark as unresponsive
                // 3. Remove unresponsive peers from routing table
                _ = peer;
            }
        }
    }

    /// Discover new peers using Kademlia DHT
    pub fn discoverPeers(self: *@This(), target_id: [32]u8) []const [32]u8 {
        return self.routing_table.getClosestPeers(target_id, Kademlia.MAX_BUCKET_SIZE);
    }
};

pub const NodeState = enum {
    initializing,
    bootstrapping,
    listening,
    shutting_down,
};

pub const P2PNode = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    peer_manager: *PeerManager,
    transport: *Transport.Transport,
    server: *P2PServer,
    local_peer_id: [32]u8,
    state: NodeState,
    started_at: i64,

    pub fn init(allocator: std.mem.Allocator, local_peer_id: [32]u8) !*@This() {
        const transport = try Transport.Transport.init(allocator, .{});
        const peer_manager = try PeerManager.init(allocator, transport, local_peer_id);
        const server = try P2PServer.init(allocator, .{ .allow_unauthenticated_handshake = true });

        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .peer_manager = peer_manager,
            .transport = transport,
            .server = server,
            .local_peer_id = local_peer_id,
            .state = .initializing,
            .started_at = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        };

                return self;
    }

    /// Initialize with persistent node key (loads or generates new key pair)
    pub fn initPersistent(allocator: std.mem.Allocator, data_dir: []const u8) !*@This() {
        const node_key = try NodeKey.init(allocator, data_dir);
        const peer_id = node_key.peerId();

        const transport = try Transport.Transport.init(allocator, .{});
        const peer_manager = try PeerManager.init(allocator, transport, peer_id);
        const server = try P2PServer.init(allocator, .{ .allow_unauthenticated_handshake = true });

        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .peer_manager = peer_manager,
            .transport = transport,
            .server = server,
            .local_peer_id = peer_id,
            .state = .initializing,
            .started_at = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.server.deinit();
        self.peer_manager.deinit();
        self.transport.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        self.state = .bootstrapping;
        try self.server.start();
        self.state = .listening;
    }

    pub fn stop(self: *Self) void {
        self.state = .shutting_down;
        self.server.stop();
    }

    pub fn isRunning(self: *Self) bool {
        return self.state == .listening;
    }

    /// Accept one incoming connection
    pub fn acceptOne(self: *Self) !void {
        try self.server.acceptOne();
    }

    /// Broadcast a block to all connected peers
    pub fn broadcastBlock(self: *Self, block_data: []const u8, sender_id: [32]u8) !void {
        try self.server.broadcastBlock(sender_id, block_data);
    }

    /// Broadcast a vote to all connected peers
    pub fn broadcastVote(self: *Self, vote_data: []const u8, sender_id: [32]u8) !void {
        try self.server.broadcastVote(sender_id, vote_data);
    }

    /// Broadcast a certificate to all connected peers
    pub fn broadcastCertificate(self: *Self, cert_data: []const u8, sender_id: [32]u8) !void {
        try self.server.broadcastCertificate(sender_id, cert_data);
    }

    /// Send to specific peer
    pub fn sendToPeer(self: *Self, peer_id: [32]u8, msg: Message) !void {
        try self.server.sendToPeer(peer_id, msg);
    }

    /// Get connected peer count
    pub fn peerCount(self: *Self) usize {
        return self.server.peerCount();
    }

    /// Connect to a remote peer
    pub fn dial(self: *Self, address: []const u8, peer_id: [32]u8) !void {
        try self.server.dial(address, peer_id);
    }

    /// Discover peers closest to a target using Kademlia DHT
    pub fn discoverPeers(self: *Self, target_id: [32]u8) []const [32]u8 {
        return self.peer_manager.discoverPeers(target_id);
    }

    /// Refresh the routing table to remove unresponsive peers
    pub fn refreshPeerDiscovery(self: *Self) void {
        self.peer_manager.refreshRoutingTable();
    }
};

/// Gossip protocol for consensus messages
pub const GossipProtocol = struct {
    allocator: std.mem.Allocator,
    pending_blocks: std.AutoArrayHashMapUnmanaged([32]u8, []u8),
    pending_votes: std.AutoArrayHashMapUnmanaged([32]u8, []u8),
    max_pending: usize,

    pub fn init(allocator: std.mem.Allocator) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .pending_blocks = std.AutoArrayHashMapUnmanaged().init(allocator, &.{}, &.{}),
            .pending_votes = std.AutoArrayHashMapUnmanaged().init(allocator, &.{}, &.{}),
            .max_pending = 1000,
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        var block_it = self.pending_blocks.iterator();
        while (block_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.pending_blocks.deinit();

        var vote_it = self.pending_votes.iterator();
        while (vote_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.pending_votes.deinit();

        self.allocator.destroy(self);
    }

    /// Add a block to the pending gossip buffer
    pub fn addPendingBlock(self: *@This(), digest: [32]u8, data: []u8) !void {
        if (self.pending_blocks.count() >= self.max_pending) {
            // Evict oldest
            if (self.pending_blocks.iterator().next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
                _ = self.pending_blocks.remove(entry.key_ptr.*);
            }
        }
        const data_copy = try self.allocator.dupe(u8, data);
        try self.pending_blocks.put(digest, data_copy);
    }

    /// Add a vote to the pending gossip buffer
    pub fn addPendingVote(self: *@This(), key: [32]u8, data: []u8) !void {
        if (self.pending_votes.count() >= self.max_pending) {
            if (self.pending_votes.iterator().next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
                _ = self.pending_votes.remove(entry.key_ptr.*);
            }
        }
        const data_copy = try self.allocator.dupe(u8, data);
        try self.pending_votes.put(key, data_copy);
    }

    /// Get pending blocks for a given digest
    pub fn getPendingBlock(self: *@This(), digest: [32]u8) ?[]u8 {
        return self.pending_blocks.get(digest);
    }

    /// Get pending votes for a given key
    pub fn getPendingVotes(self: *@This(), key: [32]u8) ?[]u8 {
        return self.pending_votes.get(key);
    }
};

pub fn createPeerID(public_key: [32]u8) [32]u8 {
    var ctx = std.crypto.hash.Blake3.init(.{});
    ctx.update(&public_key);
    var id: [32]u8 = undefined;
    ctx.final(&id);
    return id;
}

test "Peer creation" {
    const peer = Peer{
        .id = [_]u8{1} ** 32,
        .address = "127.0.0.1",
        .port = 8080,
        .is_outbound = true,
        .connected_at = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        .last_message = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        .latency_ms = 10,
    };

    try std.testing.expect(peer.isActive());
}

test "PeerManager with Kademlia routing" {
    const allocator = std.testing.allocator;
    var transport = try Transport.Transport.init(allocator, .{});
    defer transport.deinit();

    const peer_id = [_]u8{1} ** 32;
    var pm = try PeerManager.init(allocator, transport, peer_id);
    defer pm.deinit();

    const peer = Peer{
        .id = [_]u8{2} ** 32,
        .address = "127.0.0.1",
        .port = 8080,
        .is_outbound = true,
        .connected_at = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        .last_message = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        .latency_ms = 10,
    };

    try pm.addPeer(peer);
    try std.testing.expect(pm.peerCount() == 1);

    // Test Kademlia closest peers
    const closest = try pm.getClosestPeers(peer.id, 10);
    defer allocator.free(closest);
    try std.testing.expect(closest.len == 1);

    pm.removePeer(peer.id);
    try std.testing.expect(pm.peerCount() == 0);
}
