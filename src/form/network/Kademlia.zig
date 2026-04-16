//! Kademlia-inspired Routing Table for peer discovery
//!
//! Reference: libp2p Kademlia DHT
//! 
//! This is a simplified implementation suitable for blockchain consensus:
//! - Buckets of 20 peers based on XOR distance
//! - Local peer ID as reference point
//! - Ping/pong for peer liveness checks
//! 
//! Key differences from full Kademlia DHT:
//! - Used for direct peer connections, not distributed storage
//! - Fixed bucket size (k=20)
//! - Simplified refresh logic

const std = @import("std");
const core = @import("../../core.zig");

pub const KBucket = struct {
    const Self = @This();

    /// XOR distance type - lower values = closer to us
    pub const Distance = u256;

    allocator: std.mem.Allocator,
    local_peer_id: [32]u8,
    peers: std.AutoArrayHashMapUnmanaged([32]u8, PeerEntry),
    bucket_index: u8,

    pub const PeerEntry = struct {
        peer_id: [32]u8,
        address: []const u8,
        port: u16,
        last_seen: i64,
        successful_pings: u32,
        failed_pings: u32,
    };

    pub fn init(allocator: std.mem.Allocator, local_peer_id: [32]u8, bucket_index: u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .local_peer_id = local_peer_id,
            .peers = .empty,
            .bucket_index = bucket_index,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.address);
        }
        self.peers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Compute XOR distance between two peer IDs
    pub fn xorDistance(a: [32]u8, b: [32]u8) Distance {
        var result: Distance = 0;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            result = (result << 8) | @as(Distance, a[i] ^ b[i]);
        }
        return result;
    }

    /// Get distance from local peer
    pub fn distanceFromLocal(self: *Self, peer_id: [32]u8) Distance {
        return xorDistance(self.local_peer_id, peer_id);
    }

    /// Add a peer to this bucket
    pub fn addPeer(self: *Self, peer_id: [32]u8, address: []const u8, port: u16) !void {
        const entry = PeerEntry{
            .peer_id = peer_id,
            .address = try self.allocator.dupe(u8, address),
            .port = port,
            .last_seen = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .successful_pings = 0,
            .failed_pings = 0,
        };
        try self.peers.put(self.allocator, peer_id, entry);
    }

    /// Remove a peer from this bucket
    pub fn removePeer(self: *Self, peer_id: [32]u8) void {
        if (self.peers.getPtr(peer_id)) |entry| {
            self.allocator.free(entry.address);
            _ = self.peers.swapRemove(peer_id);
        }
    }

    /// Update peer last_seen timestamp
    pub fn touchPeer(self: *Self, peer_id: [32]u8) void {
        if (self.peers.getPtr(peer_id)) |entry| {
            entry.last_seen = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        }
    }

    /// Record successful ping
    pub fn recordPingSuccess(self: *Self, peer_id: [32]u8) void {
        if (self.peers.getPtr(peer_id)) |entry| {
            entry.successful_pings += 1;
            entry.last_seen = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        }
    }

    /// Record failed ping
    pub fn recordPingFailure(self: *Self, peer_id: [32]u8) void {
        if (self.peers.getPtr(peer_id)) |entry| {
            entry.failed_pings += 1;
        }
    }

    /// Check if peer is responsive (most pings successful)
    pub fn isPeerResponsive(self: *Self, peer_id: [32]u8) bool {
        if (self.peers.get(peer_id)) |entry| {
            return entry.successful_pings > entry.failed_pings;
        }
        return false;
    }

    pub fn peerCount(self: *Self) usize {
        return self.peers.count();
    }
};

/// Routing table managing multiple KBuckets
pub const RoutingTable = struct {
    const Self = @This();
    const BUCKET_COUNT = 256; // One bucket per bit of XOR distance
    const MAX_BUCKET_SIZE = 20;

    allocator: std.mem.Allocator,
    local_peer_id: [32]u8,
    buckets: [BUCKET_COUNT]?*KBucket,

    pub fn init(allocator: std.mem.Allocator, local_peer_id: [32]u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .local_peer_id = local_peer_id,
            .buckets = [_]?*KBucket{null} ** BUCKET_COUNT,
        };

        // Initialize all buckets
        for (&self.buckets, 0..BUCKET_COUNT) |*bucket, i| {
            bucket.* = try KBucket.init(allocator, local_peer_id, @intCast(i));
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.buckets) |bucket| {
            if (bucket) |b| {
                b.deinit();
            }
        }
        self.allocator.destroy(self);
    }

    /// Get bucket index for a peer ID (most significant differing bit)
    fn getBucketIndex(peer_id: [32]u8, local_id: [32]u8) u8 {
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const diff = peer_id[i] ^ local_id[i];
            if (diff != 0) {
                return @intCast(7 - @clz(diff) + (31 - i) * 8);
            }
        }
        return 0;
    }

    /// Add a peer to the routing table
    pub fn addPeer(self: *Self, peer_id: [32]u8, address: []const u8, port: u16) !void {
        const bucket_idx = getBucketIndex(peer_id, self.local_peer_id);
        const bucket = self.buckets[bucket_idx] orelse return;

        // Check if bucket is full
        if (bucket.peerCount() >= MAX_BUCKET_SIZE) {
            // Try to remove unresponsive peers
            var it = bucket.peers.iterator();
            while (it.next()) |entry| {
                if (!bucket.isPeerResponsive(entry.key_ptr.*)) {
                    bucket.removePeer(entry.key_ptr.*);
                    break;
                }
            }
        }

        // Still full? Can't add
        if (bucket.peerCount() >= MAX_BUCKET_SIZE) {
            return error.BucketFull;
        }

        try bucket.addPeer(peer_id, address, port);
    }

    /// Remove a peer from the routing table
    pub fn removePeer(self: *Self, peer_id: [32]u8) void {
        const bucket_idx = getBucketIndex(peer_id, self.local_peer_id);
        if (self.buckets[bucket_idx]) |bucket| {
            bucket.removePeer(peer_id);
        }
    }

    /// Get all known peer IDs
    pub fn getAllPeers(self: *Self) []const [32]u8 {
        var result = std.ArrayList([32]u8).init(self.allocator);
        
        for (self.buckets) |bucket| {
            if (bucket) |b| {
                                var it = b.peers.iterator();
                                while (it.next()) |entry| {
                                        try result.append(entry.key_ptr.*);
                                }
                        }
                }
        
                return result.toOwnedSlice();
    }

    /// Get peers closest to a target ID
    pub fn getClosestPeers(self: *Self, target_id: [32]u8, count: usize) ![]const [32]u8 {
        const PeerEntry = struct { id: [32]u8, dist: KBucket.Distance };
        var peers = std.ArrayList(PeerEntry).empty;
        defer peers.deinit(self.allocator);

        for (self.buckets) |bucket| {
            if (bucket) |b| {
                var it = b.peers.iterator();
                while (it.next()) |entry| {
                    const dist = KBucket.xorDistance(target_id, entry.key_ptr.*);
                    try peers.append(self.allocator, .{ .id = entry.key_ptr.*, .dist = dist });
                }
            }
        }

        // Sort by distance
        std.sort.pdq(PeerEntry, peers.items, {}, struct {
            fn lessThan(_: void, a: PeerEntry, b: PeerEntry) bool {
                return a.dist < b.dist;
            }
        }.lessThan);

        // Return top 'count' peers
        const result_len = @min(count, peers.items.len);
        var result = std.ArrayList([32]u8).empty;
        for (peers.items[0..result_len]) |peer| {
            try result.append(self.allocator, peer.id);
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// Total peer count across all buckets
    pub fn totalPeers(self: *Self) usize {
        var total: usize = 0;
        for (self.buckets) |bucket| {
            if (bucket) |b| {
                total += b.peerCount();
            }
        }
        return total;
    }
};

test "KBucket distance calculation" {
    const a = [_]u8{0x00} ** 32;
    const b = [_]u8{0xff} ** 32;
    
    const dist = KBucket.xorDistance(a, b);
    try std.testing.expect(dist > 0);
}

test "RoutingTable init and deinit" {
    const allocator = std.testing.allocator;
    const local_id = [_]u8{0x12} ** 32;
    
    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();
    
    try std.testing.expect(rt.totalPeers() == 0);
}

test "RoutingTable add/remove peer" {
    const allocator = std.testing.allocator;
    const local_id = [_]u8{0x12} ** 32;
    
    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();
    
    const peer_id = [_]u8{0x34} ** 32;
    try rt.addPeer(peer_id, "127.0.0.1", 8080);
    
    try std.testing.expect(rt.totalPeers() == 1);
    
    rt.removePeer(peer_id);
    try std.testing.expect(rt.totalPeers() == 0);
}

test "RoutingTable closest peers" {
    const allocator = std.testing.allocator;
    const local_id = [_]u8{0x00} ** 32;
    
    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();
    
    // Add several peers
    const peer1 = [_]u8{0x01} ** 32;
    const peer2 = [_]u8{0x10} ** 32;
    const peer3 = [_]u8{0xff} ** 32;
    
    try rt.addPeer(peer1, "127.0.0.1", 8080);
    try rt.addPeer(peer2, "127.0.0.1", 8081);
    try rt.addPeer(peer3, "127.0.0.1", 8082);
    
    const closest = try rt.getClosestPeers(peer1, 2);
    defer allocator.free(closest);
    
    try std.testing.expect(closest.len == 2);
}
