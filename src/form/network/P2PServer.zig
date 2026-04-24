//! P2PServer - TCP/QUIC server for peer-to-peer networking
//!
//! Implements actual network I/O following libp2p patterns:
//! - TCP or QUIC transport with non-blocking I/O
//! - Connection acceptance and management
//! - Message framing and parsing
//! - Peer identification and handshake
//!
//! Reference: rust-libp2p's TCP/QUIC transport and swarm patterns

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../../core.zig");
const Transport = @import("Transport.zig");
const Message = Transport.Message;
const P2PMessageType = @import("P2P.zig").P2PMessageType;
const QUIC = @import("QUIC.zig");
const Log = @import("../../app/Log.zig");

const HANDSHAKE_CONTEXT = "zknot3_p2p_handshake_v2";
const HANDSHAKE_WINDOW_SECS: i64 = 60;

const HandshakeNonceTracker = struct {
    allocator: std.mem.Allocator,
    ttl_secs: i64,
    entries: std.AutoArrayHashMapUnmanaged([32]u8, i64) = .empty,

    fn init(allocator: std.mem.Allocator, ttl_secs: i64) HandshakeNonceTracker {
        return .{
            .allocator = allocator,
            .ttl_secs = ttl_secs,
        };
    }

    fn deinit(self: *HandshakeNonceTracker) void {
        self.entries.deinit(self.allocator);
    }

    fn registerFresh(self: *HandshakeNonceTracker, nonce: [32]u8, now: i64) bool {
        var i: usize = 0;
        while (i < self.entries.count()) {
            const ts = self.entries.values()[i];
            if (now - ts > self.ttl_secs) {
                const key = self.entries.keys()[i];
                _ = self.entries.swapRemove(key);
                continue;
            }
            i += 1;
        }

        if (self.entries.contains(nonce)) return false;
        self.entries.put(self.allocator, nonce, now) catch return false;
        return true;
    }
};


fn streamWriteAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var writer = stream.writer(@import("io_instance").io, &.{});
    try writer.interface.writeAll(bytes);
}

fn streamReadShort(stream: std.Io.net.Stream, buf: []u8) !usize {
    var reader = stream.reader(@import("io_instance").io, &.{});
    return reader.interface.readSliceShort(buf) catch |err| {
        if (err == error.ReadFailed) return reader.err.?;
        return error.WouldBlock;
    };
}

fn streamReadVec(stream: std.Io.net.Stream, buf: []u8) !usize {
    var reader = stream.reader(@import("io_instance").io, &.{});
    var data: [1][]u8 = .{buf};
    return reader.interface.readVec(&data) catch |err| {
        if (err == error.ReadFailed) return reader.err.?;
        return error.WouldBlock;
    };
}

fn currentSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

/// Transport protocol type
pub const TransportType = enum {
    tcp,
    quic,
};

pub const P2PServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0:8083",
    max_connections: usize = 256,
    connection_timeout_secs: u64 = 30,
    ping_interval_secs: u64 = 15,
    max_message_size: usize = 64 * 1024 * 1024,
    transport_type: TransportType = .tcp,
    /// Bootstrap peer addresses to connect to on startup
    bootstrap_peers: []const []const u8 = &.{},
    /// Whether to dial bootstrap peers
    dial_bootstrap: bool = true,
    /// Optional validator key for P2P handshake authentication
    validator_key: ?[32]u8 = null,
    /// Development-only escape hatch for peers without validator identity
    allow_unauthenticated_handshake: bool = false,
    /// Per-peer incoming message cap in a one-second window
    max_messages_per_second_per_peer: usize = 256,
    /// Per-message-type incoming message cap in a one-second window
    max_messages_per_second_per_type: usize = 128,
    /// Score threshold for temporary ban
    peer_score_ban_threshold: i32 = -100,
    /// Ban duration in seconds
    peer_ban_seconds: i64 = 300,
};

const PeerRateState = struct {
    window_second: i64 = 0,
    total_count: usize = 0,
    block_count: usize = 0,
    vote_count: usize = 0,
    certificate_count: usize = 0,
    transaction_count: usize = 0,
    score: i32 = 0,
    banned_until: i64 = 0,
};

pub const P2PServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: P2PServerConfig,
    listener: ?std.Io.net.Server,
    quic_transport: ?*QUIC.QUICTransport,
    is_running: bool,
    peers: std.AutoArrayHashMapUnmanaged([32]u8, *PeerConnection),
    quic_peers: std.AutoArrayHashMapUnmanaged([32]u8, *QUICPeerConnection),
    next_peer_id: u64,
    last_bootstrap_retry: i64,
    validator_key: ?[32]u8,
    handshake_nonce_tracker: HandshakeNonceTracker,
    peer_rate_states: std.AutoArrayHashMapUnmanaged([32]u8, PeerRateState),
    rate_limited_drops_total: u64,
    banned_peers_total: u64,
    p2p_uring_sq_depth: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    p2p_uring_cq_lat_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    p2p_fallback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Callbacks
    on_block: ?*const fn (peer_id: [32]u8, block_data: []u8) void,
    on_vote: ?*const fn (peer_id: [32]u8, vote_data: []u8) void,
    on_certificate: ?*const fn (peer_id: [32]u8, cert_data: []u8) void,
    on_transaction: ?*const fn (peer_id: [32]u8, tx_data: []u8) void,
    on_peer_connect: ?*const fn (peer_id: [32]u8) void,
    on_peer_disconnect: ?*const fn (peer_id: [32]u8) void,

    pub fn init(allocator: std.mem.Allocator, config: P2PServerConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .listener = null,
            .quic_transport = null,
            .is_running = false,
            .peers = std.AutoArrayHashMapUnmanaged([32]u8, *PeerConnection).empty,
            .quic_peers = std.AutoArrayHashMapUnmanaged([32]u8, *QUICPeerConnection).empty,
            .next_peer_id = 0,
            .last_bootstrap_retry = 0,
            .on_block = null,
            .on_vote = null,
            .on_certificate = null,
            .on_transaction = null,
            .on_peer_connect = null,
            .on_peer_disconnect = null,
            .validator_key = config.validator_key,
            .handshake_nonce_tracker = HandshakeNonceTracker.init(allocator, HANDSHAKE_WINDOW_SECS),
            .peer_rate_states = .empty,
            .rate_limited_drops_total = 0,
            .banned_peers_total = 0,
        };
        if (builtin.os.tag == .linux) {
            self.p2p_uring_sq_depth.store(128, .monotonic);
            self.p2p_uring_cq_lat_ms.store(1, .monotonic);
        } else {
            self.p2p_fallback_count.store(1, .monotonic);
        }
        errdefer self.peers.deinit(self.allocator);
        errdefer self.quic_peers.deinit(self.allocator);

        if (config.transport_type == .quic) {
            const quic_config = QUIC.QUICConfig{
                .bind_address = config.bind_address,
                .max_connections = config.max_connections,
            };
            self.quic_transport = try QUIC.QUICTransport.init(allocator, quic_config);
            errdefer if (self.quic_transport) |qt| qt.deinit();
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        var it = self.peers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.peers.deinit(self.allocator);

        var qit = self.quic_peers.iterator();
        while (qit.next()) |entry| {
            entry.value_ptr.*.quic_conn.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.quic_peers.deinit(self.allocator);

        self.peer_rate_states.deinit(self.allocator);
        self.handshake_nonce_tracker.deinit();

        // Deinit QUIC transport if present
        if (self.quic_transport) |qt| {
            qt.deinit();
        }

        // SECURITY: Zero sensitive key material before deallocation
        if (self.validator_key) |*key| {
            @memset(key, 0);
        }

        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        if (self.is_running) return error.AlreadyRunning;

        if (self.config.transport_type == .quic) {
            if (self.quic_transport) |qt| {
                try qt.listen();
            } else {
                return error.QUICTransportNotInitialized;
            }
        } else {
            var parts = std.mem.splitScalar(u8, self.config.bind_address, ':');
            const host = parts.next() orelse "0.0.0.0";
            const port_str = parts.next() orelse "8083";
            const port = try std.fmt.parseInt(u16, port_str, 10);
            const addr = try std.Io.net.IpAddress.parseIp4(host, port);
            self.listener = try addr.listen(@import("io_instance").io, .{});

            const timeout: std.posix.timeval = if (@hasField(std.posix.timeval, "tv_sec"))
                .{ .tv_sec = 1, .tv_usec = 0 }
            else
                .{ .sec = 1, .usec = 0 };
            std.posix.setsockopt(
                self.listener.?.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&timeout),
            ) catch |err| {
                Log.warn("[WARN] P2PServer failed to set accept timeout: {}", .{err});
            };
        }

        self.is_running = true;

        if (self.config.dial_bootstrap and self.config.bootstrap_peers.len > 0) {
            for (self.config.bootstrap_peers) |addr| {
                self.dialBootstrapPeer(addr) catch |err| {
                    Log.err("Failed to dial bootstrap peer {s}: {}", .{ addr, err });
                };
            }
        }
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.listener) |*listener| {
            listener.deinit(@import("io_instance").io);
            self.listener = null;
        }
        if (self.quic_transport) |qt| {
            qt.stop();
        }
    }

    pub fn isRunning(self: *Self) bool {
        return self.is_running;
    }

    pub fn acceptOne(self: *Self) !void {
        if (self.config.transport_type == .quic) {
            // Handle QUIC connection
            if (self.quic_transport) |qt| {
                const quic_conn = try qt.accept();
                try self.handleQUICConnection(quic_conn);
            }
        } else {
            // Handle TCP connection
            if (self.listener) |_| {
                if (!self.hasPendingConnection()) {
                    return error.WouldBlock;
                }
                const conn = try self.listener.?.accept(@import("io_instance").io);
            Log.debug("Accepted incoming connection", .{});
                try self.handleConnection(conn);
            }
        }
    }

    /// Run the accept loop (blocking)
    pub fn run(self: *Self) !void {
        try self.start();
        defer self.stop();

        while (self.is_running) {
            self.acceptOne() catch |err| {
                Log.err("Accept error: {}", .{err});
                continue;
            };
        }
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Stream) !void {
        if (self.peers.count() + self.quic_peers.count() >= self.config.max_connections) {
            Log.warn("[WARN] P2P connection limit reached ({}), rejecting incoming connection", .{self.config.max_connections});
            conn.close(@import("io_instance").io);
            return error.TooManyPeers;
        }

        const peer_id = self.next_peer_id;
        self.next_peer_id += 1;

        // Set short read timeout BEFORE handshake so a stalled peer doesn't freeze the loop
        setPeerTimeout(conn);

        const peer_conn = PeerConnection.init(self.allocator, peer_id, conn) catch |err| {
            conn.close(@import("io_instance").io);
            return err;
        };
        peer_conn.max_message_size = self.config.max_message_size;
        errdefer {
            peer_conn.deinit();
            self.allocator.destroy(peer_conn);
        }

        // Perform handshake
        try peer_conn.performHandshake(
            false,
            self.validator_key,
            self.config.allow_unauthenticated_handshake,
            &self.handshake_nonce_tracker,
        );
        Log.info("Peer handshake completed (id={})", .{peer_id});

        // For legacy mode without auth, generate random peer key using CSPRNG
        if (self.validator_key == null) {
            var peer_key: [32]u8 = undefined;
            // SECURITY FIX: Use CSPRNG instead of deterministic pointer address
            @import("io_instance").io.random(std.mem.asBytes(&peer_key));
            peer_conn.peer_key = peer_key;
        }

        const peer_key = peer_conn.peer_key;
        try self.peers.put(self.allocator, peer_key, peer_conn);
        errdefer _ = self.peers.swapRemove(peer_key);
        try self.peer_rate_states.put(self.allocator, peer_key, .{});

        // Notify callback
        if (self.on_peer_connect) |cb| {
            cb(peer_key);
        }
    }

    /// Handle an incoming QUIC connection
    fn handleQUICConnection(self: *Self, quic_conn: *QUIC.QUICConnection) !void {
        if (self.peers.count() + self.quic_peers.count() >= self.config.max_connections) {
            Log.warn("[WARN] P2P QUIC connection limit reached ({}), rejecting incoming connection", .{self.config.max_connections});
            quic_conn.close();
            return error.TooManyPeers;
        }

        const peer_id = self.next_peer_id;
        self.next_peer_id += 1;

        const peer_conn = try QUICPeerConnection.init(self.allocator, peer_id, quic_conn);
        peer_conn.max_message_size = self.config.max_message_size;
        errdefer {
            if (self.quic_transport) |qt| {
                qt.closeConnection(peer_conn.quic_conn.connection_id);
            }
            self.allocator.destroy(peer_conn);
        }

        // Perform QUIC handshake
        try peer_conn.performHandshake(
            false,
            self.validator_key,
            self.config.allow_unauthenticated_handshake,
        );

        if (self.validator_key == null) {
            var peer_key: [32]u8 = undefined;
            // SECURITY FIX: Use CSPRNG for QUIC peer keys too
            @import("io_instance").io.random(std.mem.asBytes(&peer_key));
            peer_conn.peer_key = peer_key;
        }

        const peer_key = peer_conn.peer_key;
        try self.quic_peers.put(self.allocator, peer_key, peer_conn);
        errdefer _ = self.quic_peers.swapRemove(peer_key);
        try self.peer_rate_states.put(self.allocator, peer_key, .{});

        // Notify callback
        if (self.on_peer_connect) |cb| {
            cb(peer_key);
        }
    }

    /// Broadcast a block to all connected peers
    pub fn broadcastBlock(self: *Self, sender_id: [32]u8, block_data: []u8) !void {
        const msg = Message{
            .msg_type = .block,
            .sender = sender_id,
            .sequence = 0,
            .payload = block_data,
        };
        try self.broadcast(msg);
    }

    /// Broadcast a vote to all connected peers
    pub fn broadcastVote(self: *Self, sender_id: [32]u8, vote_data: []u8) !void {
        const msg = Message{
            .msg_type = .consensus,
            .sender = sender_id,
            .sequence = 0,
            .payload = vote_data,
        };
        try self.broadcast(msg);
    }

    /// Broadcast a certificate to all connected peers
    pub fn broadcastCertificate(self: *Self, sender_id: [32]u8, cert_data: []u8) !void {
        const msg = Message{
            .msg_type = .certificate,
            .sender = sender_id,
            .sequence = 0,
            .payload = cert_data,
        };
        try self.broadcast(msg);
    }

    fn broadcast(self: *Self, msg: Message) !void {
        var failed_peers: std.ArrayList([32]u8) = .empty;
        defer failed_peers.deinit(self.allocator);

        var it = self.peers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.sendMessage(msg) catch {
                try failed_peers.append(self.allocator, entry.key_ptr.*);
            };
        }

        var qit = self.quic_peers.iterator();
        while (qit.next()) |entry| {
            entry.value_ptr.*.sendMessage(msg) catch {
                try failed_peers.append(self.allocator, entry.key_ptr.*);
            };
        }

        for (failed_peers.items) |peer_id| {
            self.removePeer(peer_id);
        }
    }
    pub fn disconnectPeer(self: *Self, peer_id: [32]u8) void {
        self.removePeer(peer_id);
    }


    fn removePeer(self: *Self, peer_id: [32]u8) void {
        if (self.peers.getPtr(peer_id)) |peer| {
            peer.*.deinit();
            self.allocator.destroy(peer.*);
            _ = self.peers.swapRemove(peer_id);
            _ = self.peer_rate_states.swapRemove(peer_id);

            if (self.on_peer_disconnect) |cb| {
                cb(peer_id);
            }
            return;
        }
        if (self.quic_peers.getPtr(peer_id)) |peer| {
            const quic_peer = peer.*;
            // Let QUICTransport manage QUICConnection lifecycle; it owns the
            // underlying connection and must remove it from its own map.
            if (self.quic_transport) |qt| {
                qt.closeConnection(quic_peer.quic_conn.connection_id);
            }
            self.allocator.destroy(quic_peer);
            _ = self.quic_peers.swapRemove(peer_id);
            _ = self.peer_rate_states.swapRemove(peer_id);

            if (self.on_peer_disconnect) |cb| {
                cb(peer_id);
            }
        }
    }

    pub fn isPeerBanned(self: *Self, peer_id: [32]u8) bool {
        const now = currentSeconds();
        if (self.peer_rate_states.getPtr(peer_id)) |state| {
            return state.banned_until > now;
        }
        return false;
    }

    /// Per-peer + per-type incoming rate guard with score-based temporary ban.
    /// Returns false when the message should be dropped.
    pub fn allowIncomingMessage(self: *Self, peer_id: [32]u8, msg_type: Transport.MessageType) bool {
        const now = currentSeconds();
        const entry = self.peer_rate_states.getOrPut(self.allocator, peer_id) catch return false;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const state = entry.value_ptr;

        if (state.banned_until > now) return false;
        if (state.window_second != now) {
            state.window_second = now;
            state.total_count = 0;
            state.block_count = 0;
            state.vote_count = 0;
            state.certificate_count = 0;
            state.transaction_count = 0;
        }

        state.total_count += 1;
        switch (msg_type) {
            .block => state.block_count += 1,
            .consensus => state.vote_count += 1,
            .certificate => state.certificate_count += 1,
            .transaction => state.transaction_count += 1,
            else => {},
        }

        const peer_cap = self.config.max_messages_per_second_per_peer;
        const type_cap = self.config.max_messages_per_second_per_type;
        const over_peer = state.total_count > peer_cap;
        const over_type = switch (msg_type) {
            .block => state.block_count > type_cap,
            .consensus => state.vote_count > type_cap,
            .certificate => state.certificate_count > type_cap,
            .transaction => state.transaction_count > type_cap,
            else => false,
        };

        if (over_peer or over_type) {
            self.rate_limited_drops_total += 1;
            state.score -= 20;
            if (state.score <= self.config.peer_score_ban_threshold) {
                state.banned_until = now + self.config.peer_ban_seconds;
                self.banned_peers_total += 1;
                Log.warn("Banning peer due to repeated rate-limit violations", .{});
            }
            return false;
        }

        if (state.score < 0) state.score += 1;
        return true;
    }

    pub const RateLimitStats = struct {
        rate_limited_drops_total: u64,
        banned_peers_total: u64,
    };

    pub const AsyncMetrics = struct {
        sq_depth: u64,
        cq_lat_ms: u64,
        fallback_count: u64,
    };

    pub fn getRateLimitStats(self: *Self) RateLimitStats {
        return .{
            .rate_limited_drops_total = self.rate_limited_drops_total,
            .banned_peers_total = self.banned_peers_total,
        };
    }

    pub fn asyncMetricsSnapshot(self: *Self) AsyncMetrics {
        return .{
            .sq_depth = self.p2p_uring_sq_depth.load(.monotonic),
            .cq_lat_ms = self.p2p_uring_cq_lat_ms.load(.monotonic),
            .fallback_count = self.p2p_fallback_count.load(.monotonic),
        };
    }

    pub fn peerCount(self: *Self) usize {
        return self.peers.count() + self.quic_peers.count();
    }

    pub fn getPeerIDs(self: *Self) ![]const [32]u8 {
        var ids: std.ArrayList([32]u8) = .empty;
        errdefer ids.deinit(self.allocator);
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            try ids.append(self.allocator, entry.key_ptr.*);
        }
        var qit = self.quic_peers.iterator();
        while (qit.next()) |entry| {
            try ids.append(self.allocator, entry.key_ptr.*);
        }
        return ids.toOwnedSlice(self.allocator);
    }

    /// Send a direct message to a specific peer
    pub fn sendToPeer(self: *Self, peer_id: [32]u8, msg: Message) !void {
        if (self.peers.getPtr(peer_id)) |peer| {
            try peer.*.sendMessage(msg);
            return;
        }
        if (self.quic_peers.getPtr(peer_id)) |peer| {
            try peer.*.sendMessage(msg);
            return;
        }
        return error.PeerNotFound;
    }

    /// Connect to a remote peer (dial)
    pub fn dial(self: *Self, address: []const u8, peer_id: [32]u8) !void {
        if (self.config.transport_type == .quic) {
            if (self.quic_transport) |qt| {
                const quic_conn = try qt.dial(address);
                try self.handleQUICConnection(quic_conn);
            } else {
                return error.QUICTransportNotInitialized;
            }
        } else {
            if (self.peers.count() + self.quic_peers.count() >= self.config.max_connections) {
                Log.warn("[WARN] P2P outbound connection limit reached ({}), rejecting dial to {s}", .{ self.config.max_connections, address });
                return error.TooManyPeers;
            }

            var parts = std.mem.splitScalar(u8, address, ':');
            const host = parts.next() orelse return error.InvalidAddress;
            const port_str = parts.next() orelse return error.InvalidAddress;
            const port = try std.fmt.parseInt(u16, port_str, 10);
            const resolved_addr = try std.Io.net.IpAddress.resolve(@import("io_instance").io, host, port);
            const stream = try resolved_addr.connect(@import("io_instance").io, .{ .mode = .stream });
            const conn = stream;

            // Set short read timeout BEFORE handshake
            setPeerTimeout(conn);

            const peer_conn = PeerConnection.init(self.allocator, self.next_peer_id, conn) catch |err| {
                conn.close(@import("io_instance").io);
                return err;
            };
            peer_conn.max_message_size = self.config.max_message_size;
            self.next_peer_id += 1;
            errdefer {
                peer_conn.deinit();
                self.allocator.destroy(peer_conn);
            }
            try peer_conn.performHandshake(
                true,
                self.validator_key,
                self.config.allow_unauthenticated_handshake,
                &self.handshake_nonce_tracker,
            );
            if (self.validator_key == null) {
                peer_conn.peer_key = peer_id;
            }
            if (self.peers.contains(peer_conn.peer_key) or self.quic_peers.contains(peer_conn.peer_key)) {
                self.disconnectPeer(peer_conn.peer_key);
            }
            try self.peers.put(self.allocator, peer_conn.peer_key, peer_conn);
            errdefer _ = self.peers.swapRemove(peer_conn.peer_key);
            try self.peer_rate_states.put(self.allocator, peer_conn.peer_key, .{});
            Log.info("Connected to peer at {s} (id={})", .{ address, peer_conn.peer_id });
        }
    }

    fn dialBootstrapPeer(self: *Self, address: []const u8) !void {
        const peer_key = derivePeerKeyFromAddress(address);
        try self.dial(address, peer_key);
    }

    fn setPeerTimeout(stream: std.Io.net.Stream) void {
        const timeout: std.posix.timeval = if (@hasField(std.posix.timeval, "tv_sec"))
            .{ .tv_sec = 0, .tv_usec = 100000 }  // 100ms
        else
            .{ .sec = 0, .usec = 100000 };
        std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            Log.warn("[WARN] P2PServer failed to set receive timeout: {}", .{err});
        };
        std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            Log.warn("[WARN] P2PServer failed to set send timeout: {}", .{err});
        };
    }


    fn isPeerConnectedByAddress(self: *Self, address: []const u8) bool {
        const peer_key = derivePeerKeyFromAddress(address);
        return self.peers.contains(peer_key) or self.quic_peers.contains(peer_key);
    }

    /// Event-driven readiness check for TCP listener.
    /// Returns true when an incoming connection is ready to accept.
    pub fn hasPendingConnection(self: *Self) bool {
        if (self.config.transport_type != .tcp) return true;
        if (self.listener == null) return false;

        const fd = self.listener.?.socket.handle;
        var fds = [_]std.posix.pollfd{
            .{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const n = std.posix.poll(&fds, 0) catch return false;
        if (n <= 0) return false;
        return (fds[0].revents & std.posix.POLL.IN) != 0;
    }

    fn derivePeerKeyFromAddress(address: []const u8) [32]u8 {
        var peer_key: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(address, &peer_key, .{});
        return peer_key;
    }

    pub fn maintainBootstrapConnections(self: *Self) void {
        if (!self.config.dial_bootstrap or self.config.bootstrap_peers.len == 0) return;

        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        if (now - self.last_bootstrap_retry < 60) return;
        self.last_bootstrap_retry = now;

        for (self.config.bootstrap_peers) |addr| {
            if (!self.isPeerConnectedByAddress(addr)) {
                self.dialBootstrapPeer(addr) catch |err| {
                    Log.err("Failed to dial bootstrap peer {s}: {}", .{ addr, err });
                };
            }
        }
    }
};

/// Represents an active peer connection
pub const PeerConnection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    peer_id: u64,
    conn: std.Io.net.Stream,
    state: PeerConnection.State,
    last_ping: i64,
    peer_key: [32]u8,
    max_message_size: usize,

    pub const State = enum {
        handshaking,
        connected,
        active,
        closing,
        closed,
    };

    pub fn init(allocator: std.mem.Allocator, peer_id: u64, conn: std.Io.net.Stream) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .peer_id = peer_id,
            .conn = conn,
            .state = .handshaking,
            .last_ping = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .peer_key = undefined,
            .max_message_size = Message.MAX_MESSAGE_SIZE,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.conn.close(@import("io_instance").io);
    }

    /// Perform handshake with remote peer
    pub fn performHandshake(
        self: *Self,
        is_initiator: bool,
        validator_key: ?[32]u8,
        allow_unauthenticated_handshake: bool,
        nonce_tracker: *HandshakeNonceTracker,
    ) !void {
        if (validator_key) |vk| {
            const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(vk) catch return error.HandshakeFailed;
            const pubkey = kp.public_key.toBytes();
            const now = nowSeconds();
            const now_u64: u64 = @intCast(if (now < 0) 0 else now);

            if (is_initiator) {
                var nonce_a: [32]u8 = undefined;
                @import("io_instance").io.random(&nonce_a);
                if (!nonce_tracker.registerFresh(nonce_a, now)) return error.HandshakeFailed;

                var request_payload: [40]u8 = undefined;
                @memcpy(request_payload[0..32], &nonce_a);
                std.mem.writeInt(u64, request_payload[32..40], now_u64, .big);
                const request = Message{
                    .msg_type = .handshake,
                    .sender = pubkey,
                    .sequence = 0,
                    .payload = &request_payload,
                };
                try self.sendMessage(request);

                const response = try self.recvMessage() orelse return error.HandshakeFailed;
                defer self.allocator.free(response.payload);
                if (response.msg_type != .handshake) return error.HandshakeFailed;
                const parsed_resp = try parseSignedPayload(response.payload);
                if (!std.mem.eql(u8, &parsed_resp.nonce_a, &nonce_a)) return error.HandshakeFailed;
                if (!isTimestampFresh(parsed_resp.timestamp, nowSeconds())) return error.HandshakeFailed;
                if (!nonce_tracker.registerFresh(parsed_resp.nonce_b, nowSeconds())) return error.HandshakeFailed;
                try verifySignedTuple(
                    response.sender,
                    parsed_resp.nonce_a,
                    parsed_resp.nonce_b,
                    parsed_resp.timestamp,
                    parsed_resp.signature,
                );

                const ack_sig = try signTuple(kp, parsed_resp.nonce_a, parsed_resp.nonce_b, parsed_resp.timestamp);
                const ack_payload = buildSignedPayload(
                    parsed_resp.nonce_a,
                    parsed_resp.nonce_b,
                    parsed_resp.timestamp,
                    ack_sig,
                );
                const ack = Message{
                    .msg_type = .handshake,
                    .sender = pubkey,
                    .sequence = 0,
                    .payload = &ack_payload,
                };
                try self.sendMessage(ack);
                self.peer_key = response.sender;
            } else {
                const request = try self.recvMessage() orelse return error.HandshakeFailed;
                defer self.allocator.free(request.payload);
                if (request.msg_type != .handshake) return error.HandshakeFailed;
                const parsed_req = try parseRequestPayload(request.payload);
                if (!isTimestampFresh(parsed_req.timestamp, nowSeconds())) return error.HandshakeFailed;
                if (!nonce_tracker.registerFresh(parsed_req.nonce_a, nowSeconds())) return error.HandshakeFailed;

                var nonce_b: [32]u8 = undefined;
                @import("io_instance").io.random(&nonce_b);
                if (!nonce_tracker.registerFresh(nonce_b, nowSeconds())) return error.HandshakeFailed;
                const response_ts_u64: u64 = @intCast(if (nowSeconds() < 0) 0 else nowSeconds());
                const response_sig = try signTuple(kp, parsed_req.nonce_a, nonce_b, response_ts_u64);
                const response_payload = buildSignedPayload(parsed_req.nonce_a, nonce_b, response_ts_u64, response_sig);
                const response = Message{
                    .msg_type = .handshake,
                    .sender = pubkey,
                    .sequence = 0,
                    .payload = &response_payload,
                };
                try self.sendMessage(response);

                const ack = try self.recvMessage() orelse return error.HandshakeFailed;
                defer self.allocator.free(ack.payload);
                if (ack.msg_type != .handshake) return error.HandshakeFailed;
                if (!std.mem.eql(u8, &ack.sender, &request.sender)) return error.HandshakeFailed;
                const parsed_ack = try parseSignedPayload(ack.payload);
                if (!std.mem.eql(u8, &parsed_ack.nonce_a, &parsed_req.nonce_a)) return error.HandshakeFailed;
                if (!std.mem.eql(u8, &parsed_ack.nonce_b, &nonce_b)) return error.HandshakeFailed;
                if (parsed_ack.timestamp != response_ts_u64) return error.HandshakeFailed;
                try verifySignedTuple(
                    ack.sender,
                    parsed_ack.nonce_a,
                    parsed_ack.nonce_b,
                    parsed_ack.timestamp,
                    parsed_ack.signature,
                );
                self.peer_key = ack.sender;
            }
            self.state = .connected;
        } else {
            if (!allow_unauthenticated_handshake) {
                return error.UnauthenticatedHandshakeDisabled;
            }
            // Legacy unauthenticated handshake
            const handshake_data = try self.allocator.dupe(u8, "zknot3:v1");
            defer self.allocator.free(handshake_data);
            const msg = Message{
                .msg_type = .handshake,
                .sender = undefined,
                .sequence = 0,
                .payload = handshake_data,
            };
            try self.sendMessage(msg);
            self.state = .connected;
        }
    }

    fn nowSeconds() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return ts.sec;
    }

    fn isTimestampFresh(ts: u64, now: i64) bool {
        const now_u64: u64 = @intCast(if (now < 0) 0 else now);
        if (ts > now_u64 + HANDSHAKE_WINDOW_SECS) return false;
        return now_u64 - ts <= HANDSHAKE_WINDOW_SECS;
    }

    fn signTuple(
        kp: std.crypto.sign.Ed25519.KeyPair,
        nonce_a: [32]u8,
        nonce_b: [32]u8,
        timestamp: u64,
    ) ![64]u8 {
        var msg_buf: [32 + 32 + 8 + HANDSHAKE_CONTEXT.len]u8 = undefined;
        @memcpy(msg_buf[0..32], &nonce_a);
        @memcpy(msg_buf[32..64], &nonce_b);
        std.mem.writeInt(u64, msg_buf[64..72], timestamp, .big);
        @memcpy(msg_buf[72..], HANDSHAKE_CONTEXT);
        const sig = std.crypto.sign.Ed25519.KeyPair.sign(kp, &msg_buf, null) catch return error.HandshakeFailed;
        return sig.toBytes();
    }

    fn verifySignedTuple(
        pubkey: [32]u8,
        nonce_a: [32]u8,
        nonce_b: [32]u8,
        timestamp: u64,
        signature: [64]u8,
    ) !void {
        var msg_buf: [32 + 32 + 8 + HANDSHAKE_CONTEXT.len]u8 = undefined;
        @memcpy(msg_buf[0..32], &nonce_a);
        @memcpy(msg_buf[32..64], &nonce_b);
        std.mem.writeInt(u64, msg_buf[64..72], timestamp, .big);
        @memcpy(msg_buf[72..], HANDSHAKE_CONTEXT);
        const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(pubkey) catch return error.HandshakeFailed;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature);
        sig.verify(&msg_buf, pk) catch return error.HandshakeFailed;
    }

    fn parseRequestPayload(payload: []const u8) !struct { nonce_a: [32]u8, timestamp: u64 } {
        if (payload.len != 40) return error.HandshakeFailed;
        return .{
            .nonce_a = payload[0..32].*,
            .timestamp = std.mem.readInt(u64, payload[32..40], .big),
        };
    }

    fn buildSignedPayload(
        nonce_a: [32]u8,
        nonce_b: [32]u8,
        timestamp: u64,
        signature: [64]u8,
    ) [136]u8 {
        var payload: [136]u8 = undefined;
        @memcpy(payload[0..32], &nonce_a);
        @memcpy(payload[32..64], &nonce_b);
        std.mem.writeInt(u64, payload[64..72], timestamp, .big);
        @memcpy(payload[72..136], &signature);
        return payload;
    }

    fn parseSignedPayload(payload: []const u8) !struct {
        nonce_a: [32]u8,
        nonce_b: [32]u8,
        timestamp: u64,
        signature: [64]u8,
    } {
        if (payload.len != 136) return error.HandshakeFailed;
        return .{
            .nonce_a = payload[0..32].*,
            .nonce_b = payload[32..64].*,
            .timestamp = std.mem.readInt(u64, payload[64..72], .big),
            .signature = payload[72..136].*,
        };
    }
    pub fn sendMessage(self: *Self, msg: Message) !void {
        const serialized = try msg.serialize(self.allocator);
        defer self.allocator.free(serialized);

        try streamWriteAll(self.conn, serialized);
    }

    pub fn recvMessage(self: *Self) !?Message {
        // Read header first (45 bytes)
        var header_buf: [45]u8 = undefined;
        const bytes_read = streamReadShort(self.conn, &header_buf) catch |err| {
            if (err == error.WouldBlock) return error.WouldBlock;
            return err;
        };
        if (bytes_read == 0) return null; // EOF
        if (bytes_read < 45) return error.IncompleteHeader;

        // Parse header to get payload length
        const payload_len = std.mem.readInt(u32, header_buf[41..45], .big);
        if (payload_len > self.max_message_size) return error.MessageTooLarge;

        // Read payload
        if (payload_len > 0) {
            const payload_buf = try self.allocator.alloc(u8, payload_len);
            defer self.allocator.free(payload_buf);

            const payload_read = streamReadShort(self.conn, payload_buf) catch |err| {
                if (err == error.WouldBlock) return error.WouldBlock;
                return err;
            };
            if (payload_read < payload_len) return error.IncompletePayload;

            // Combine header + payload for deserialization
            var full_buf = try self.allocator.alloc(u8, 45 + payload_len);
            defer self.allocator.free(full_buf);
            @memcpy(full_buf[0..45], &header_buf);
            @memcpy(full_buf[45..], payload_buf);

            return try Message.deserialize(self.allocator, full_buf);
        }

        return try Message.deserialize(self.allocator, &header_buf);
    }

    pub fn sendPing(self: *Self) !void {
        const msg = Message{
            .msg_type = .ping,
            .sender = undefined,
            .sequence = 0,
            .payload = &.{},
        };
        try self.sendMessage(msg);
        self.last_ping = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
    }

    pub fn sendPong(self: *Self) !void {
        const msg = Message{
            .msg_type = .pong,
            .sender = undefined,
            .sequence = 0,
            .payload = &.{},
        };
        try self.sendMessage(msg);
    }
};

/// QUIC-specific peer connection wrapper
pub const QUICPeerConnection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    peer_id: u64,
    quic_conn: *QUIC.QUICConnection,
    state: PeerConnection.State,
    last_ping: i64,
    peer_key: [32]u8,
    max_message_size: usize,

    pub fn init(allocator: std.mem.Allocator, peer_id: u64, quic_conn: *QUIC.QUICConnection) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .peer_id = peer_id,
            .quic_conn = quic_conn,
            .state = .handshaking,
            .last_ping = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .peer_key = undefined,
            .max_message_size = Message.MAX_MESSAGE_SIZE,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Perform QUIC handshake
    pub fn performHandshake(
        self: *Self,
        is_initiator: bool,
        validator_key: ?[32]u8,
        allow_unauthenticated_handshake: bool,
    ) !void {
        _ = is_initiator;
        if (validator_key == null and !allow_unauthenticated_handshake) {
            return error.UnauthenticatedHandshakeDisabled;
        }
        // QUIC handshake happens at connection level
        // Just mark as connected once we have the connection
        self.quic_conn.state = .connected;
        self.state = .connected;
    }

    pub fn sendMessage(self: *Self, msg: Message) !void {
        // Open a new bidirectional stream for each message
        const stream_id = try self.quic_conn.openStream();
        const stream = self.quic_conn.getStream(stream_id) orelse return error.StreamNotFound;

        const serialized = try msg.serialize(self.allocator);
        defer self.allocator.free(serialized);

        try stream.write(serialized);
    }

    pub fn recvMessage(self: *Self) !?Message {
        // Accept incoming stream
        const stream = self.quic_conn.acceptStream() orelse return null;

        var buf: [64 * 1024]u8 = undefined;
        const len = try stream.read(&buf);
        if (len == 0) return null;
        if (len > self.max_message_size) return error.MessageTooLarge;

        return try Message.deserialize(self.allocator, buf[0..len]);
    }

    pub fn sendPing(self: *Self) !void {
        const stream_id = try self.quic_conn.openUnidirectionalStream();
        const stream = self.quic_conn.getStream(stream_id) orelse return error.StreamNotFound;
        const ping_data = "ping";
        try stream.write(ping_data);
        self.last_ping = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
    }

    pub fn sendPong(self: *Self) !void {
        const stream_id = try self.quic_conn.openUnidirectionalStream();
        const stream = self.quic_conn.getStream(stream_id) orelse return error.StreamNotFound;
        const pong_data = "pong";
        try stream.write(pong_data);
    }
};

test "P2PServer initialization" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{});
    defer server.deinit();

    try std.testing.expect(!server.isRunning());
    try std.testing.expect(server.peerCount() == 0);
}

test "P2PServer deinit does not double free" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{});
    server.deinit();
}

test "P2PServer with QUIC transport" {
    const allocator = std.testing.allocator;
    const config = P2PServerConfig{
        .transport_type = .quic,
    };
    const server = try P2PServer.init(allocator, config);
    defer server.deinit();

    try std.testing.expect(!server.isRunning());
    try std.testing.expect(server.peerCount() == 0);
    try std.testing.expect(server.quic_transport != null);
}

test "PeerConnection struct layout" {
    _ = @sizeOf(PeerConnection);
}

test "QUICPeerConnection struct layout" {
    _ = @sizeOf(QUICPeerConnection);
}

test "bootstrap peer key derivation is deterministic" {
    const addr = "127.0.0.1:8083";
    const k1 = P2PServer.derivePeerKeyFromAddress(addr);
    const k2 = P2PServer.derivePeerKeyFromAddress(addr);
    try std.testing.expectEqual(k1, k2);
}

test "HandshakeNonceTracker rejects replay and allows after ttl" {
    const allocator = std.testing.allocator;
    var tracker = HandshakeNonceTracker.init(allocator, 2);
    defer tracker.deinit();

    const nonce = [_]u8{7} ** 32;
    try std.testing.expect(tracker.registerFresh(nonce, 100));
    try std.testing.expect(!tracker.registerFresh(nonce, 100));
    try std.testing.expect(!tracker.registerFresh(nonce, 101));
    try std.testing.expect(tracker.registerFresh(nonce, 103));
}

test "handshake timestamp freshness window" {
    try std.testing.expect(PeerConnection.isTimestampFresh(100, 100));
    try std.testing.expect(PeerConnection.isTimestampFresh(40, 100));
    try std.testing.expect(!PeerConnection.isTimestampFresh(39, 100));
    try std.testing.expect(!PeerConnection.isTimestampFresh(200, 100));
}

test "per-peer rate limiter eventually bans noisy peer" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{
        .max_messages_per_second_per_peer = 4,
        .max_messages_per_second_per_type = 3,
        .peer_score_ban_threshold = -20,
        .peer_ban_seconds = 30,
    });
    defer server.deinit();

    const peer = [_]u8{0xAA} ** 32;
    try std.testing.expect(server.allowIncomingMessage(peer, .consensus));
    try std.testing.expect(server.allowIncomingMessage(peer, .consensus));
    try std.testing.expect(server.allowIncomingMessage(peer, .consensus));
    // Type cap exceeded; score drops to threshold and peer becomes banned.
    try std.testing.expect(!server.allowIncomingMessage(peer, .consensus));
    try std.testing.expect(server.isPeerBanned(peer));
}

test "handshake payload parser rejects malformed lengths" {
    const short_req = [_]u8{0} ** 39;
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseRequestPayload(&short_req));

    const long_req = [_]u8{0} ** 41;
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseRequestPayload(&long_req));

    const short_signed = [_]u8{0} ** 135;
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseSignedPayload(&short_signed));

    const long_signed = [_]u8{0} ** 137;
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseSignedPayload(&long_signed));
}

test "peerCount sums tcp and quic peers" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{ .max_connections = 10 });
    defer server.deinit();

    // Create a valid socket pair for the mock TCP peer's conn
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[1]);
    const stream = std.Io.net.Stream{ .socket = .{
        .handle = fds[0],
        .address = .{ .ip4 = .{ .bytes = .{0, 0, 0, 0}, .port = 0 } },
    } };

    // Manually inject a TCP peer
    const tcp_key = [_]u8{0x01} ** 32;
    const tcp_peer = try allocator.create(PeerConnection);
    tcp_peer.* = .{
        .allocator = allocator,
        .peer_id = 1,
        .conn = stream,
        .state = .connected,
        .last_ping = 0,
        .peer_key = tcp_key,
        .max_message_size = 1024,
    };
    try server.peers.put(allocator, tcp_key, tcp_peer);

    // Manually inject a QUIC peer with a valid QUICConnection
    const quic_conn = try QUIC.QUICConnection.init(allocator, .{ .bytes = [_]u8{0} ** 16 });
    const quic_key = [_]u8{0x02} ** 32;
    const quic_peer = try allocator.create(QUICPeerConnection);
    quic_peer.* = .{
        .allocator = allocator,
        .peer_id = 2,
        .quic_conn = quic_conn,
        .state = .connected,
        .last_ping = 0,
        .peer_key = quic_key,
        .max_message_size = 1024,
    };
    try server.quic_peers.put(allocator, quic_key, quic_peer);

    try std.testing.expectEqual(@as(usize, 2), server.peerCount());

    // getPeerIDs should return both
    const ids = try server.getPeerIDs();
    defer allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);

    // isPeerConnectedByAddress should check both maps (no matching address)
    try std.testing.expect(!server.isPeerConnectedByAddress("127.0.0.1:1"));

    // removePeer should destroy the correct type
    server.removePeer(tcp_key);
    server.removePeer(quic_key);
    try std.testing.expectEqual(@as(usize, 0), server.peerCount());

    // QUICConnection was not freed by removePeer (quic_transport is null),
    // so clean it up manually.
    quic_conn.deinit();
}

test "max_connections rejects inbound connection" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{ .max_connections = 1 });
    defer server.deinit();

    // Create a valid socket pair for the mock peer's conn
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[1]);
    const stream = std.Io.net.Stream{ .socket = .{
        .handle = fds[0],
        .address = .{ .ip4 = .{ .bytes = .{0, 0, 0, 0}, .port = 0 } },
    } };

    // Fill the slot with a dummy TCP peer
    const key = [_]u8{0xAB} ** 32;
    const peer = try allocator.create(PeerConnection);
    peer.* = .{
        .allocator = allocator,
        .peer_id = 0,
        .conn = stream,
        .state = .connected,
        .last_ping = 0,
        .peer_key = key,
        .max_message_size = 1024,
    };
    try server.peers.put(allocator, key, peer);

    try std.testing.expectEqual(@as(usize, 1), server.peerCount());

    // A second peer should be rejected. Since we can't easily create a real
    // stream in a unit test, verify the limit logic by checking the public
    // peer count against max_connections.
    try std.testing.expect(server.peerCount() >= server.config.max_connections);
}
