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

/// Max peers sharing one IPv4 /16, IPv6 /48, or the shared unresolved
/// (hostname / unparseable) prefix inside a single KBucket.
/// Callers (e.g. `PeerManager.addPeer`) should pass a DNS-resolved dial
/// string when possible so hostname peers hit IP prefix caps instead.
pub const MAX_PEERS_PER_PREFIX: usize = 4;
/// Classic Kademlia k parameter (peers per bucket).
pub const MAX_BUCKET_SIZE: usize = 20;

/// Parsed address prefix used for bucket diversity checks.
/// Hostnames and unparseable forms share one synthetic `.unknown` prefix so
/// they cannot unbounded-fill a bucket (no DNS; not geo-diverse).
const AddressPrefix = union(enum) {
    ipv4_16: u16,
    ipv6_48: [6]u8,
    /// Hostname or unparseable address — all share one diversity budget.
    unknown,

    fn eql(self: AddressPrefix, other: AddressPrefix) bool {
        return switch (self) {
            .unknown => other == .unknown,
            .ipv4_16 => |a| switch (other) {
                .ipv4_16 => |b| a == b,
                else => false,
            },
            .ipv6_48 => |a| switch (other) {
                .ipv6_48 => |b| std.mem.eql(u8, &a, &b),
                else => false,
            },
        };
    }
};

/// Strip optional `:port` / `[host]:port` wrapper, returning the host part.
fn hostFromAddress(address: []const u8) []const u8 {
    if (address.len == 0) return address;
    if (address[0] == '[') {
        if (std.mem.indexOfScalar(u8, address, ']')) |end| {
            return address[1..end];
        }
        return address;
    }
    // IPv4 host:port has exactly one ':'; bare IPv6 has more.
    if (std.mem.count(u8, address, ":") == 1) {
        if (std.mem.lastIndexOfScalar(u8, address, ':')) |idx| {
            return address[0..idx];
        }
    }
    return address;
}

fn ipv4Prefix16FromHost(host: []const u8) ?u16 {
    const addr = std.Io.net.IpAddress.parseIp4(host, 0) catch return null;
    return switch (addr) {
        .ip4 => |ip| blk: {
            const prefix = std.mem.readInt(u16, ip.bytes[0..2], .big);
            break :blk if (prefix == 0) null else prefix;
        },
        .ip6 => null,
    };
}

fn ipv6Prefix48FromHost(host: []const u8) ?[6]u8 {
    const addr = std.Io.net.IpAddress.parseIp6(host, 0) catch return null;
    return switch (addr) {
        .ip4 => null,
        .ip6 => |ip| blk: {
            if (std.mem.eql(u8, &ip.bytes, &@as([16]u8, @splat(0)))) break :blk null;
            // IPv4-mapped ::ffff:a.b.c.d → treat as IPv4 /16 (handled separately).
            if (std.mem.eql(u8, ip.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                break :blk null;
            }
            break :blk ip.bytes[0..6].*;
        },
    };
}

fn ipv4MappedPrefix16FromHost(host: []const u8) ?u16 {
    const addr = std.Io.net.IpAddress.parseIp6(host, 0) catch return null;
    return switch (addr) {
        .ip4 => null,
        .ip6 => |ip| blk: {
            if (!std.mem.eql(u8, ip.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                break :blk null;
            }
            const prefix = std.mem.readInt(u16, ip.bytes[12..14], .big);
            break :blk if (prefix == 0) null else prefix;
        },
    };
}

/// Extract diversity prefix from an address string (`"a.b.c.d:port"`, `[v6]:port`, …).
/// Hostnames and unparseable forms yield `.unknown` (shared unresolved budget).
fn parseAddressPrefix(address: []const u8) AddressPrefix {
    const host = hostFromAddress(address);
    if (ipv4Prefix16FromHost(host)) |p| return .{ .ipv4_16 = p };
    if (ipv4MappedPrefix16FromHost(host)) |p| return .{ .ipv4_16 = p };
    if (ipv6Prefix48FromHost(host)) |p| return .{ .ipv6_48 = p };
    return .unknown;
}

fn nowSecs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

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

    fn countPeersWithPrefix(self: *Self, prefix: AddressPrefix) usize {
        var n: usize = 0;
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            if (parseAddressPrefix(entry.value_ptr.address).eql(prefix)) n += 1;
        }
        return n;
    }

    /// Add a peer to this bucket. Enforces `MAX_PEERS_PER_PREFIX` per IPv4 /16,
    /// IPv6 /48, or the shared unresolved (hostname) prefix. Re-adding an
    /// existing peer_id refreshes its entry without re-checking diversity.
    pub fn addPeer(self: *Self, peer_id: [32]u8, address: []const u8, port: u16) !void {
        if (self.peers.getPtr(peer_id)) |existing| {
            const new_addr = try self.allocator.dupe(u8, address);
            self.allocator.free(existing.address);
            existing.address = new_addr;
            existing.port = port;
            existing.last_seen = nowSecs();
            return;
        }

        const prefix = parseAddressPrefix(address);
        if (self.countPeersWithPrefix(prefix) >= MAX_PEERS_PER_PREFIX) {
            return error.PrefixDiversityLimit;
        }

        const entry = PeerEntry{
            .peer_id = peer_id,
            .address = try self.allocator.dupe(u8, address),
            .port = port,
            .last_seen = nowSecs(),
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
            entry.last_seen = nowSecs();
        }
    }

    /// Record successful ping
    pub fn recordPingSuccess(self: *Self, peer_id: [32]u8) void {
        if (self.peers.getPtr(peer_id)) |entry| {
            entry.successful_pings += 1;
            entry.last_seen = nowSecs();
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

    allocator: std.mem.Allocator,
    local_peer_id: [32]u8,
    buckets: [BUCKET_COUNT]?*KBucket,

    pub fn init(allocator: std.mem.Allocator, local_peer_id: [32]u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .local_peer_id = local_peer_id,
            .buckets = @as([BUCKET_COUNT]?*KBucket, @splat(null)),
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
    pub fn getAllPeers(self: *Self) ![]const [32]u8 {
        var result: std.ArrayList([32]u8) = .empty;
        errdefer result.deinit(self.allocator);

        for (self.buckets) |bucket| {
            if (bucket) |b| {
                var it = b.peers.iterator();
                while (it.next()) |entry| {
                    try result.append(self.allocator, entry.key_ptr.*);
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
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

    /// Find peers closest to target with distance-based ranking.
    /// Returns peers sorted by XOR distance (closest first). When network I/O
    /// is available, this becomes the iterative FIND_NODE lookup. Currently
    /// returns the best local results ranked by proximity.
    pub fn iterativeFindNode(self: *Self, target_id: [32]u8, alpha: usize) ![]const [32]u8 {
        const k = @min(alpha, MAX_BUCKET_SIZE);
        const peers = try self.getClosestPeers(target_id, k);
        // Results are already sorted by XOR distance from getClosestPeers.
        // Full iterative lookup would recursively query each peer for even
        // closer peers until convergence (Kademlia alpha=3 convergence).
        return peers;
    }

    /// Estimate how close the local routing table is to a target.
    /// Returns 0.0-1.0 where 1.0 means we have peers in the target's bucket.
    pub fn proximityScore(self: *const Self, target_id: [32]u8) f64 {
        const bucket_idx = getBucketIndex(target_id, self.local_peer_id);
        var peer_count: usize = 0;
        if (self.buckets[bucket_idx]) |bucket| {
            peer_count = bucket.peerCount();
        }
        if (peer_count >= MAX_BUCKET_SIZE) return 1.0;
        return @as(f64, @floatFromInt(peer_count)) / @as(f64, @floatFromInt(MAX_BUCKET_SIZE));
    }
};

/// Kademlia wire protocol message types.
pub const KadMessageType = enum(u8) {
    ping = 0x01,
    pong = 0x02,
    find_node = 0x03,
    nodes = 0x04,
};

/// A decoded Kademlia protocol message.
pub const KadMessage = struct {
    msg_type: KadMessageType,
    sender_id: [32]u8,
    /// For FIND_NODE: the target ID being searched.
    /// For NODES: empty (peers are in the peers field).
    target_id: ?[32]u8,
    /// For NODES responses: list of peer IDs close to the target.
    peers: []const [32]u8,

    pub fn deinit(self: *KadMessage, allocator: std.mem.Allocator) void {
        if (self.peers.len > 0) allocator.free(self.peers);
        self.* = undefined;
    }
};

/// Encode a Kademlia message for wire transmission.
/// Format: [msg_type: u8][sender_id: 32][target_id: 32][peer_count: u16][peers...]
pub fn encodeKadMessage(allocator: std.mem.Allocator, msg: KadMessage) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, @backingInt(msg.msg_type));
    try buf.appendSlice(allocator, &msg.sender_id);
    const tid = msg.target_id orelse @as([32]u8, @splat(0));
    try buf.appendSlice(allocator, &tid);
    const peer_count: u16 = @intCast(msg.peers.len);
    var count_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &count_bytes, peer_count, .big);
    try buf.appendSlice(allocator, &count_bytes);
    for (msg.peers) |peer| {
        try buf.appendSlice(allocator, &peer);
    }

    return buf.toOwnedSlice(allocator);
}

/// Decode a Kademlia wire message.
pub fn decodeKadMessage(allocator: std.mem.Allocator, data: []const u8) !KadMessage {
    if (data.len < 1 + 32 + 32 + 2) return error.MessageTooShort;
    const msg_type: KadMessageType = @fromBackingInt(@intCast(data[0]));
    var sender_id: [32]u8 = undefined;
    @memcpy(&sender_id, data[1..33]);
    var target_id: [32]u8 = undefined;
    @memcpy(&target_id, data[33..65]);
    const peer_count = std.mem.readInt(u16, data[65..67], .big);
    const peers_start = 67;

    const has_target = !std.mem.eql(u8, &target_id, &(@as([32]u8, @splat(0))));
    var peers: []const [32]u8 = &.{};
    if (peer_count > 0 and data.len >= peers_start + peer_count * 32) {
        const raw = try allocator.alloc([32]u8, peer_count);
        errdefer allocator.free(raw);
        for (0..peer_count) |i| {
            @memcpy(&raw[i], data[peers_start + i * 32 .. peers_start + (i + 1) * 32]);
        }
        peers = raw;
    }

    return KadMessage{
        .msg_type = msg_type,
        .sender_id = sender_id,
        .target_id = if (has_target) target_id else null,
        .peers = peers,
    };
}

test "KBucket distance calculation" {
    const a = @as([32]u8, @splat(0x00));
    const b = @as([32]u8, @splat(0xff));

    const dist = KBucket.xorDistance(a, b);
    try std.testing.expect(dist > 0);
}

test "RoutingTable init and deinit" {
    const allocator = std.testing.allocator;
    const local_id = @as([32]u8, @splat(0x12));

    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    try std.testing.expect(rt.totalPeers() == 0);
}

test "RoutingTable add/remove peer" {
    const allocator = std.testing.allocator;
    const local_id = @as([32]u8, @splat(0x12));

    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    const peer_id = @as([32]u8, @splat(0x34));
    try rt.addPeer(peer_id, "127.0.0.1", 8083);

    try std.testing.expect(rt.totalPeers() == 1);

    rt.removePeer(peer_id);
    try std.testing.expect(rt.totalPeers() == 0);
}

test "RoutingTable closest peers" {
    const allocator = std.testing.allocator;
    const local_id = @as([32]u8, @splat(0x00));

    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Add several peers
    const peer1 = @as([32]u8, @splat(0x01));
    const peer2 = @as([32]u8, @splat(0x10));
    const peer3 = @as([32]u8, @splat(0xff));

    try rt.addPeer(peer1, "127.0.0.1", 8083);
    try rt.addPeer(peer2, "127.0.0.1", 8084);
    try rt.addPeer(peer3, "127.0.0.1", 8085);

    const closest = try rt.getClosestPeers(peer1, 2);
    defer allocator.free(closest);

    try std.testing.expect(closest.len == 2);
}

test "KadMessage encode/decode round-trip" {
    const allocator = std.testing.allocator;

    const sender_id = @as([32]u8, @splat(0xAB));
    const target_id = @as([32]u8, @splat(0xCD));
    const peers = [_][32]u8{ @as([32]u8, @splat(0x01)), @as([32]u8, @splat(0x02)) };

    // Test FIND_NODE message
    const msg = KadMessage{
        .msg_type = .find_node,
        .sender_id = sender_id,
        .target_id = target_id,
        .peers = &.{},
    };

    const encoded = try encodeKadMessage(allocator, msg);
    defer allocator.free(encoded);

    var decoded = try decodeKadMessage(allocator, encoded);

    try std.testing.expectEqual(msg.msg_type, decoded.msg_type);
    try std.testing.expect(std.mem.eql(u8, &sender_id, &decoded.sender_id));
    try std.testing.expect(decoded.target_id != null);
    try std.testing.expect(std.mem.eql(u8, &target_id, &decoded.target_id.?));
    try std.testing.expectEqual(@as(usize, 0), decoded.peers.len);
    decoded.deinit(allocator);

    // Test NODES response with peer list
    const nodes_msg = KadMessage{
        .msg_type = .nodes,
        .sender_id = sender_id,
        .target_id = null,
        .peers = &peers,
    };

    const encoded2 = try encodeKadMessage(allocator, nodes_msg);
    defer allocator.free(encoded2);

    var decoded2 = try decodeKadMessage(allocator, encoded2);
    defer decoded2.deinit(allocator);

    try std.testing.expectEqual(KadMessageType.nodes, decoded2.msg_type);
    try std.testing.expect(decoded2.target_id == null);
    try std.testing.expectEqual(@as(usize, 2), decoded2.peers.len);
    try std.testing.expect(std.mem.eql(u8, &peers[0], &decoded2.peers[0]));
}

test "KadMessage ping/pong" {
    const allocator = std.testing.allocator;
    const sender = @as([32]u8, @splat(0xEE));

    const ping = KadMessage{
        .msg_type = .ping,
        .sender_id = sender,
        .target_id = null,
        .peers = &.{},
    };
    const encoded = try encodeKadMessage(allocator, ping);
    defer allocator.free(encoded);

    var decoded = try decodeKadMessage(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(KadMessageType.ping, decoded.msg_type);

    const pong = KadMessage{
        .msg_type = .pong,
        .sender_id = sender,
        .target_id = null,
        .peers = &.{},
    };
    const encoded2 = try encodeKadMessage(allocator, pong);
    defer allocator.free(encoded2);

    var decoded2 = try decodeKadMessage(allocator, encoded2);
    defer decoded2.deinit(allocator);

    try std.testing.expectEqual(KadMessageType.pong, decoded2.msg_type);
}

/// Peer IDs that share bucket 255 when local_id is all zeros (MSB of byte0 set).
fn peerIdInFarBucket(n: u8) [32]u8 {
    var id: [32]u8 = @splat(0);
    id[0] = 0x80 | (n & 0x7f);
    id[31] = n;
    return id;
}

test "parseAddressPrefix ipv4 host:port and ipv4-mapped" {
    try std.testing.expect(parseAddressPrefix("172.20.0.4:8083").eql(.{ .ipv4_16 = 0xac14 }));
    try std.testing.expect(parseAddressPrefix("172.20.1.9").eql(.{ .ipv4_16 = 0xac14 }));
    try std.testing.expect(parseAddressPrefix("10.1.2.3:9").eql(.{ .ipv4_16 = 0x0a01 }));
    try std.testing.expect(parseAddressPrefix("::ffff:172.20.0.4").eql(.{ .ipv4_16 = 0xac14 }));
    try std.testing.expect(parseAddressPrefix("peer.example.com:8083") == .unknown);
}

test "parseAddressPrefix ipv6 /48" {
    const p = parseAddressPrefix("[2001:db8:abcd::1]:8083");
    try std.testing.expect(p == .ipv6_48);
    try std.testing.expectEqual(@as(u8, 0x20), p.ipv6_48[0]);
    try std.testing.expectEqual(@as(u8, 0x01), p.ipv6_48[1]);
    try std.testing.expectEqual(@as(u8, 0x0d), p.ipv6_48[2]);
    try std.testing.expectEqual(@as(u8, 0xb8), p.ipv6_48[3]);
    try std.testing.expectEqual(@as(u8, 0xab), p.ipv6_48[4]);
    try std.testing.expectEqual(@as(u8, 0xcd), p.ipv6_48[5]);

    const same = parseAddressPrefix("2001:db8:abcd::99");
    try std.testing.expect(same.eql(p));
    const other = parseAddressPrefix("2001:db8:abce::1");
    try std.testing.expect(!other.eql(p));
}

test "KBucket ipv4 /16 prefix diversity limit" {
    const allocator = std.testing.allocator;
    const local_id = @as([32]u8, @splat(0x00));

    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Fill MAX_PEERS_PER_PREFIX from 172.20/16 into the same far bucket.
    var i: u8 = 0;
    while (i < MAX_PEERS_PER_PREFIX) : (i += 1) {
        var addr_buf: [32]u8 = undefined;
        const addr = try std.fmt.bufPrint(&addr_buf, "172.20.0.{d}:8083", .{i + 1});
        try rt.addPeer(peerIdInFarBucket(i), addr, 8083);
    }
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX), rt.totalPeers());

    // Fifth peer from the same /16 must be rejected.
    try std.testing.expectError(
        error.PrefixDiversityLimit,
        rt.addPeer(peerIdInFarBucket(MAX_PEERS_PER_PREFIX), "172.20.9.9:8083", 8083),
    );
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX), rt.totalPeers());

    // A different /16 in the same bucket is still admitted.
    try rt.addPeer(peerIdInFarBucket(MAX_PEERS_PER_PREFIX + 1), "10.0.0.1:8083", 8083);
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX + 1), rt.totalPeers());
}

test "KBucket ipv6 /48 prefix diversity limit" {
    const allocator = std.testing.allocator;
    const local_id = @as([32]u8, @splat(0x00));

    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    var i: u8 = 0;
    while (i < MAX_PEERS_PER_PREFIX) : (i += 1) {
        var addr_buf: [64]u8 = undefined;
        const addr = try std.fmt.bufPrint(&addr_buf, "[2001:db8:abcd::{d}]:9000", .{i + 1});
        try rt.addPeer(peerIdInFarBucket(i), addr, 9000);
    }
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX), rt.totalPeers());

    try std.testing.expectError(
        error.PrefixDiversityLimit,
        rt.addPeer(peerIdInFarBucket(MAX_PEERS_PER_PREFIX), "[2001:db8:abcd::99]:9000", 9000),
    );

    // Different /48 may join the same bucket.
    try rt.addPeer(peerIdInFarBucket(MAX_PEERS_PER_PREFIX + 1), "[2001:db8:abce::1]:9000", 9000);
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX + 1), rt.totalPeers());
}

test "KBucket prefix diversity allows refresh of existing peer" {
    const allocator = std.testing.allocator;
    const local_id = @as([32]u8, @splat(0x00));
    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    var i: u8 = 0;
    while (i < MAX_PEERS_PER_PREFIX) : (i += 1) {
        var addr_buf: [32]u8 = undefined;
        const addr = try std.fmt.bufPrint(&addr_buf, "172.20.0.{d}", .{i + 1});
        try rt.addPeer(peerIdInFarBucket(i), addr, 8083);
    }

    // Refreshing an existing peer_id must not hit PrefixDiversityLimit.
    try rt.addPeer(peerIdInFarBucket(0), "172.20.0.1:9999", 9999);
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX), rt.totalPeers());
}

test "KBucket unresolved hostname prefix diversity limit" {
    const allocator = std.testing.allocator;
    const local_id = @as([32]u8, @splat(0x00));
    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Distinct hostnames share one synthetic unresolved prefix.
    var i: u8 = 0;
    while (i < MAX_PEERS_PER_PREFIX) : (i += 1) {
        var addr_buf: [64]u8 = undefined;
        const addr = try std.fmt.bufPrint(&addr_buf, "peer{d}.example.com:8083", .{i});
        try rt.addPeer(peerIdInFarBucket(i), addr, 8083);
    }
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX), rt.totalPeers());

    try std.testing.expectError(
        error.PrefixDiversityLimit,
        rt.addPeer(peerIdInFarBucket(MAX_PEERS_PER_PREFIX), "overflow.example.com:8083", 8083),
    );
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX), rt.totalPeers());

    // Refresh of an existing hostname peer_id still allowed.
    try rt.addPeer(peerIdInFarBucket(0), "peer0.example.com:9999", 9999);
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX), rt.totalPeers());
}

test "KBucket hostname and ipv4 prefix caps are independent" {
    const allocator = std.testing.allocator;
    const local_id = @as([32]u8, @splat(0x00));
    const rt = try RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Fill IPv4 /16 budget.
    var i: u8 = 0;
    while (i < MAX_PEERS_PER_PREFIX) : (i += 1) {
        var addr_buf: [32]u8 = undefined;
        const addr = try std.fmt.bufPrint(&addr_buf, "172.20.0.{d}:8083", .{i + 1});
        try rt.addPeer(peerIdInFarBucket(i), addr, 8083);
    }

    // Hostnames use a separate unresolved budget — still admitted.
    var h: u8 = 0;
    while (h < MAX_PEERS_PER_PREFIX) : (h += 1) {
        var addr_buf: [64]u8 = undefined;
        const addr = try std.fmt.bufPrint(&addr_buf, "host{d}.example.net:8083", .{h});
        try rt.addPeer(peerIdInFarBucket(@as(u8, @intCast(MAX_PEERS_PER_PREFIX)) + h), addr, 8083);
    }
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX * 2), rt.totalPeers());

    // Fifth hostname rejected; fifth IP from same /16 still rejected.
    try std.testing.expectError(
        error.PrefixDiversityLimit,
        rt.addPeer(peerIdInFarBucket(@as(u8, @intCast(MAX_PEERS_PER_PREFIX * 2))), "extra.example.net:8083", 8083),
    );
    try std.testing.expectError(
        error.PrefixDiversityLimit,
        rt.addPeer(peerIdInFarBucket(@as(u8, @intCast(MAX_PEERS_PER_PREFIX * 2 + 1))), "172.20.9.9:8083", 8083),
    );
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX * 2), rt.totalPeers());

    // A different IPv4 /16 is still independent of both caps.
    try rt.addPeer(peerIdInFarBucket(@as(u8, @intCast(MAX_PEERS_PER_PREFIX * 2 + 2))), "10.0.0.1:8083", 8083);
    try std.testing.expectEqual(@as(usize, MAX_PEERS_PER_PREFIX * 2 + 1), rt.totalPeers());
}
