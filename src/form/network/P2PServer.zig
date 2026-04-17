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
const core = @import("../../core.zig");
const Transport = @import("Transport.zig");
const Message = Transport.Message;
const P2PMessageType = @import("P2P.zig").P2PMessageType;
const QUIC = @import("QUIC.zig");
const Log = @import("../../app/Log.zig");


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

/// Transport protocol type
pub const TransportType = enum {
    tcp,
    quic,
};

pub const P2PServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0:8080",
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
};

pub const P2PServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: P2PServerConfig,
    listener: ?std.Io.net.Server,
    quic_transport: ?*QUIC.QUICTransport,
    is_running: bool,
    peers: std.AutoArrayHashMapUnmanaged([32]u8, *PeerConnection),
    next_peer_id: u64,
    last_bootstrap_retry: i64,
    validator_key: ?[32]u8,

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
            .next_peer_id = 0,
            .last_bootstrap_retry = 0,
            .on_block = null,
            .on_vote = null,
            .on_certificate = null,
            .on_transaction = null,
            .on_peer_connect = null,
            .on_peer_disconnect = null,
            .validator_key = config.validator_key,
        };
        errdefer self.peers.deinit(self.allocator);

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

        // Deinit QUIC transport if present
        if (self.quic_transport) |qt| {
            qt.deinit();
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
            const port_str = parts.next() orelse "8080";
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
        if (self.peers.count() >= self.config.max_connections) {
            Log.warn("[WARN] P2P connection limit reached ({}), rejecting incoming connection", .{self.config.max_connections});
            conn.close(@import("io_instance").io);
            return error.TooManyPeers;
        }

        const peer_id = self.next_peer_id;
        self.next_peer_id += 1;

        const peer_conn = try PeerConnection.init(self.allocator, peer_id, conn);

        // Perform handshake
        try peer_conn.performHandshake(false, self.validator_key);
        Log.info("Peer handshake completed (id={})", .{peer_id});

        // Set short read timeout so recvMessage doesn't block the event loop
        setPeerTimeout(peer_conn.conn);

        // For legacy mode without auth, generate deterministic peer key
        if (self.validator_key == null) {
            var peer_key: [32]u8 = undefined;
            std.mem.writeInt(u64, peer_key[0..8], peer_id, .big);
            const addr_bytes = std.mem.asBytes(&conn.socket.address);
            const addr_len = @min(addr_bytes.len, 24);
            @memcpy(peer_key[8..][0..addr_len], addr_bytes[0..addr_len]);
            if (addr_len < 24) {
                @memset(peer_key[8 + addr_len ..], 0);
            }
            peer_conn.peer_key = peer_key;
        }

        const peer_key = peer_conn.peer_key;
        try self.peers.put(self.allocator, peer_key, peer_conn);

        // Notify callback
        if (self.on_peer_connect) |cb| {
            cb(peer_key);
        }
    }

    /// Handle an incoming QUIC connection
    fn handleQUICConnection(self: *Self, quic_conn: *QUIC.QUICConnection) !void {
        if (self.peers.count() >= self.config.max_connections) {
            Log.warn("[WARN] P2P QUIC connection limit reached ({}), rejecting incoming connection", .{self.config.max_connections});
            quic_conn.close();
            return error.TooManyPeers;
        }

        const peer_id = self.next_peer_id;
        self.next_peer_id += 1;

        const peer_conn = try QUICPeerConnection.init(self.allocator, peer_id, quic_conn);

        // Perform QUIC handshake
        try peer_conn.performHandshake(false, self.validator_key);

        if (self.validator_key == null) {
            var peer_key: [32]u8 = undefined;
            std.mem.writeInt(u64, peer_key[0..8], peer_id, .big);
            @memset(peer_key[8..], 0);
            peer_conn.peer_key = peer_key;
        }

        const peer_key = peer_conn.peer_key;
        try self.peers.put(self.allocator, peer_key, @ptrCast(peer_conn));

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

    fn broadcast(self: *Self, msg: Message) !void {
        var failed_peers: std.ArrayList([32]u8) = .empty;
        defer failed_peers.deinit(self.allocator);

        var it = self.peers.iterator();
        while (it.next()) |entry| {
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

            if (self.on_peer_disconnect) |cb| {
                cb(peer_id);
            }
        }
    }

    pub fn peerCount(self: *Self) usize {
        return self.peers.count();
    }

    pub fn getPeerIDs(self: *Self) ![]const [32]u8 {
        var ids: std.ArrayList([32]u8) = .empty;
        errdefer ids.deinit(self.allocator);
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            try ids.append(self.allocator, entry.key_ptr.*);
        }
        return ids.toOwnedSlice(self.allocator);
    }

    /// Send a direct message to a specific peer
    pub fn sendToPeer(self: *Self, peer_id: [32]u8, msg: Message) !void {
        if (self.peers.getPtr(peer_id)) |peer| {
            try peer.*.sendMessage(msg);
        } else {
            return error.PeerNotFound;
        }
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
            var parts = std.mem.splitScalar(u8, address, ':');
            const host = parts.next() orelse return error.InvalidAddress;
            const port_str = parts.next() orelse return error.InvalidAddress;
            const port = try std.fmt.parseInt(u16, port_str, 10);
            const resolved_addr = try std.Io.net.IpAddress.resolve(@import("io_instance").io, host, port);
            const stream = try resolved_addr.connect(@import("io_instance").io, .{ .mode = .stream });
            const conn = stream;
            const peer_conn = try PeerConnection.init(self.allocator, self.next_peer_id, conn);
            self.next_peer_id += 1;
            try peer_conn.performHandshake(true, self.validator_key);
            setPeerTimeout(peer_conn.conn);
            if (self.validator_key == null) {
                peer_conn.peer_key = peer_id;
            }
            if (self.peers.contains(peer_conn.peer_key)) {
                self.disconnectPeer(peer_conn.peer_key);
            }
            try self.peers.put(self.allocator, peer_conn.peer_key, peer_conn);
            Log.info("Connected to peer at {s} (id={})", .{ address, peer_conn.peer_id });
        }
    }

    fn dialBootstrapPeer(self: *Self, address: []const u8) !void {
        var peer_key: [32]u8 = undefined;
        for (0..32) |i| {
            peer_key[i] = @truncate(@as(u32, @truncate(@intFromPtr(address.ptr) + i)));
        }
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
        var peer_key: [32]u8 = undefined;
        for (0..32) |i| {
            peer_key[i] = @truncate(@as(u32, @truncate(@intFromPtr(address.ptr) + i)));
        }
        return self.peers.contains(peer_key);
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
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.conn.close(@import("io_instance").io);
    }

    /// Perform handshake with remote peer
    pub fn performHandshake(self: *Self, is_initiator: bool, validator_key: ?[32]u8) !void {
        if (validator_key) |vk| {
            const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(vk) catch return error.HandshakeFailed;
            const pubkey = kp.public_key.toBytes();

            var challenge: [32]u8 = undefined;
            @import("io_instance").io.random(&challenge);

            const handshake_context = "zknot3_p2p_handshake_v1";
            var msg_buf: [64]u8 = undefined;
            @memcpy(msg_buf[0..32], &challenge);
            @memcpy(msg_buf[32..55], handshake_context);
            const msg_slice = msg_buf[0..55];

            const sig = std.crypto.sign.Ed25519.KeyPair.sign(kp, msg_slice, null) catch return error.HandshakeFailed;
            const sig_bytes = sig.toBytes();

            var payload: [128]u8 = undefined;
            @memcpy(payload[0..32], &pubkey);
            @memcpy(payload[32..64], &challenge);
            @memcpy(payload[64..128], &sig_bytes);

            const msg = Message{
                .msg_type = .handshake,
                .sender = pubkey,
                .sequence = 0,
                .payload = &payload,
            };

            if (is_initiator) {
                try self.sendMessage(msg);
                const response = try self.recvMessage() orelse return error.HandshakeFailed;
                defer self.allocator.free(response.payload);
                if (response.msg_type != .handshake) return error.HandshakeFailed;
                if (response.payload.len != 128) return error.HandshakeFailed;
                try verifyHandshakePayload(response.payload);
                self.peer_key = response.sender;
            } else {
                const request = try self.recvMessage() orelse return error.HandshakeFailed;
                defer self.allocator.free(request.payload);
                if (request.msg_type != .handshake) return error.HandshakeFailed;
                if (request.payload.len != 128) return error.HandshakeFailed;
                try verifyHandshakePayload(request.payload);
                self.peer_key = request.sender;
                try self.sendMessage(msg);
            }
            self.state = .connected;
        } else {
            // Legacy unauthenticated handshake
            const handshake_data = try self.allocator.dupe(u8, "zknot3:v1");
            defer self.allocator.free(handshake_data);
            const msg = Message{
                .msg_type = .transaction,
                .sender = undefined,
                .sequence = 0,
                .payload = handshake_data,
            };
            try self.sendMessage(msg);
            self.state = .connected;
        }
    }

    fn verifyHandshakePayload(payload: []const u8) !void {
        if (payload.len != 128) return error.HandshakeFailed;
        const pubkey = payload[0..32].*;
        const challenge = payload[32..64].*;
        const signature = payload[64..128].*;
        const handshake_context = "zknot3_p2p_handshake_v1";
        var msg_buf: [64]u8 = undefined;
        @memcpy(msg_buf[0..32], &challenge);
        @memcpy(msg_buf[32..55], handshake_context);
        const msg_slice = msg_buf[0..55];
        const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(pubkey) catch return error.HandshakeFailed;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature);
        sig.verify(msg_slice, pk) catch return error.HandshakeFailed;
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
            if (err == error.WouldBlock) return null;
            return err;
        };
        if (bytes_read == 0) return null; // EOF
        if (bytes_read < 45) return error.IncompleteHeader;

        // Parse header to get payload length
        const payload_len = std.mem.readInt(u32, header_buf[41..45], .big);

        // Read payload
        if (payload_len > 0) {
            const payload_buf = try self.allocator.alloc(u8, payload_len);
            defer self.allocator.free(payload_buf);

            const payload_read = streamReadShort(self.conn, payload_buf) catch |err| {
                if (err == error.WouldBlock) return null;
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

    pub fn init(allocator: std.mem.Allocator, peer_id: u64, quic_conn: *QUIC.QUICConnection) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .peer_id = peer_id,
            .quic_conn = quic_conn,
            .state = .handshaking,
            .last_ping = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .peer_key = undefined,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Perform QUIC handshake
    pub fn performHandshake(self: *Self, is_initiator: bool, validator_key: ?[32]u8) !void {
        _ = is_initiator;
        _ = validator_key;
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
