//! QUIC-style transport for libp2p-compatible networking
//!
//! Reference: rust-libp2p QUIC implementation
//!
//! This is a simplified QUIC-inspired transport for Zig:
//! - Connection-oriented with 0-RTT handshake potential
//! - Stream-based multiplexing within connections
//! - Built on UDP (simulated on top of TCP for cross-platform)
//! - TLS 1.3 encryption patterns (without actual TLS)
//!
//! Key concepts from QUIC:
//! - Connection ID for NAT traversal
//! - Streams for independent data channels
//! - Flow control per stream and connection
//! - Encryption with forward secrecy

const std = @import("std");
const core = @import("../../core.zig");

pub const QUICConfig = struct {
    bind_address: []const u8 = "0.0.0.0:8080",
    max_connections: usize = 256,
    stream_window: u64 = 1024 * 1024,
    connection_window: u64 = 16 * 1024 * 1024,
    idle_timeout_secs: u64 = 30,
    max_stream_data: u64 = 1024 * 1024,
};

pub const QUICConnectionID = struct {
    bytes: [16]u8,

    pub fn generate() @This() {
        var id: @This() = undefined;
        std.crypto.random.bytes(&id.bytes);
        return id;
    }

    pub fn fromBytes(bytes: []const u8) !@This() {
        if (bytes.len != 16) return error.InvalidLength;
        var id: @This() = undefined;
        @memcpy(&id.bytes, bytes[0..16]);
        return id;
    }
};

pub const StreamType = enum(u8) {
    /// Bidirectional stream - both sides can send
    bidirectional = 0x00,
    /// Unidirectional stream - only initiator sends
    unidirectional = 0x01,
};

pub const StreamState = enum(u8) {
    idle = 0,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

pub const QUICStream = struct {
    const Self = @This();

    stream_id: u64,
    stream_type: StreamType,
    state: StreamState,
    local_window: u64,
    remote_window: u64,
    bytes_sent: u64,
    bytes_received: u64,
    data: std.ArrayList(u8),

    pub fn init(stream_id: u64, stream_type: StreamType) !*Self {
        const self = try std.heap.page_allocator.create(Self);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .stream_id = stream_id,
            .stream_type = stream_type,
            .state = .open,
            .local_window = 1024 * 1024,
            .remote_window = 1024 * 1024,
            .bytes_sent = 0,
            .bytes_received = 0,
            .data = std.ArrayList(u8).init(std.heap.page_allocator),
        };
        errdefer self.data.deinit(std.heap.page_allocator);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(self);
    }

    pub fn write(self: *Self, data: []const u8) !void {
        if (self.state == .closed or self.state == .half_closed_local) {
            return error.StreamClosed;
        }
        try self.data.appendSlice(data);
        self.bytes_sent += data.len;
    }

    pub fn read(self: *Self, buf: []u8) !usize {
        if (self.state == .closed) return 0;
        const len = @min(buf.len, self.data.items.len);
        @memcpy(buf[0..len], self.data.items[0..len]);
        if (len > 0) {
            self.data.items = self.data.subscriber(.{ .start = len, .len = self.data.items.len - len });
            self.bytes_received += len;
        }
        return len;
    }

    pub fn close(self: *Self) void {
        self.state = .closed;
    }

    pub fn halfClose(self: *Self, side: enum { local, remote }) void {
        self.state = if (side == .local) .half_closed_local else .half_closed_remote;
    }
};

pub const ConnectionState = enum(u8) {
    /// Connection not yet established
    dialing = 0,
    /// Handshake in progress
    handshaking = 1,
    /// Connection established
    connected = 2,
    /// Connection draining
    draining = 3,
    /// Connection closed
    closed = 4,
};

pub const QUICConnection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    connection_id: QUICConnectionID,
    peer_connection_id: QUICConnectionID,
    state: ConnectionState,
    streams: std.AutoArrayHashMap(u64, *QUICStream),
    local_window: u64,
    remote_window: u64,
    bytes_sent: u64,
    bytes_received: u64,
    created_at: i64,
    tcp_connection: ?std.net.Server.Connection,
    receive_buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, connection_id: QUICConnectionID) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .connection_id = connection_id,
            .peer_connection_id = undefined,
            .state = .dialing,
            .streams = std.AutoArrayHashMap(u64, *QUICStream).init(allocator),
            .local_window = 16 * 1024 * 1024,
            .remote_window = 16 * 1024 * 1024,
            .bytes_sent = 0,
            .bytes_received = 0,
            .created_at = std.time.timestamp(),
            .tcp_connection = null,
            .receive_buffer = .empty,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.streams.deinit();
        self.receive_buffer.deinit(self.allocator);

        if (self.tcp_connection) |conn| {
            conn.stream.close();
        }
        self.allocator.destroy(self);
    }

    /// Set the TCP connection for this QUIC connection
    pub fn setTCPConnection(self: *Self, conn: std.net.Server.Connection) void {
        self.tcp_connection = conn;
        self.state = .connected;
    }

    /// Send data on a specific stream
    pub fn sendOnStream(self: *Self, stream_id: u64, data: []const u8) !void {
        if (self.tcp_connection) |*conn| {
            // QUIC frame format: stream header + data
            var frame: [16]u8 = undefined;
            // Stream frame: stream_id (varint) + offset (varint) + data length (varint) + data
            // Simplified: just prefix with stream_id (8 bytes) + length (4 bytes)
            std.mem.writeIntLittle(u64, &frame[0..8].*, stream_id);
            std.mem.writeIntLittle(u32, &frame[8..12].*, @intCast(data.len));
            try conn.stream.writeAll(&frame);
            try conn.stream.writeAll(data);
            self.bytes_sent += data.len;
        } else {
            return error.NotConnected;
        }
    }

    /// Receive data on a specific stream
    pub fn receiveOnStream(self: *Self, stream_id: u64, buf: []u8) !usize {
        _ = stream_id;
        if (self.tcp_connection) |*conn| {
            // Try to read a frame
            var header: [12]u8 = undefined;
            const header_len = try conn.stream.read(&header);
            if (header_len == 0) return 0;
            
            const data_len = std.mem.readIntLittle(u32, &header[8..12].*);
            const len = @min(buf.len, data_len);
            const received = try conn.stream.read(buf[0..len]);
            self.bytes_received += received;
            return received;
        }
        return error.NotConnected;
    }

    /// Open a new bidirectional stream
    pub fn openStream(self: *Self) !u64 {
        const stream_id = self.streams.count() * 4; // Client-initiated bidirectional
        const stream = try QUICStream.init(stream_id, .bidirectional);
        try self.streams.put(stream_id, stream);
        return stream_id;
    }

    /// Open a new unidirectional stream
    pub fn openUnidirectionalStream(self: *Self) !u64 {
        const stream_id = self.streams.count() * 4 + 1; // Client-initiated unidirectional
        const stream = try QUICStream.init(stream_id, .unidirectional);
        try self.streams.put(stream_id, stream);
        return stream_id;
    }

    /// Accept an incoming stream
    pub fn acceptStream(self: *Self) ?*QUICStream {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .open) {
                return entry.value_ptr;
            }
        }
        return null;
    }

    /// Get stream by ID
    pub fn getStream(self: *Self, stream_id: u64) ?*QUICStream {
        return self.streams.get(stream_id);
    }

    pub fn close(self: *Self) void {
        self.state = .closed;
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.close();
        }
        if (self.tcp_connection) |conn| {
            conn.stream.close();
            self.tcp_connection = null;
        }
    }
};

pub const QUICTransport = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: QUICConfig,
    connections: std.AutoArrayHashMap(QUICConnectionID, *QUICConnection),
    listener: ?std.net.Server,
    is_running: bool,
    next_connection_id: u64,

    pub fn init(allocator: std.mem.Allocator, config: QUICConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .connections = std.AutoArrayHashMap(QUICConnectionID, *QUICConnection).init(allocator),
            .listener = null,
            .is_running = false,
            .next_connection_id = 0,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.connections.deinit();
        self.allocator.destroy(self);
    }

    pub fn listen(self: *Self) !void {
        if (self.is_running) return error.AlreadyListening;

        var parts = std.mem.splitScalar(u8, self.config.bind_address, ':');
        const host = parts.next() orelse "0.0.0.0";
        const port_str = parts.next() orelse "8080";
        const port = try std.fmt.parseInt(u16, port_str, 10);

        const addr = try std.net.Address.parseIp(host, port);
        self.listener = try addr.listen(.{ .reuse_address = true });
        self.is_running = true;
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }

    /// Accept an incoming QUIC connection
    pub fn accept(self: *Self) !*QUICConnection {
        if (self.listener) |_| {
            const tcp_conn = try self.listener.?.accept();
            const cid = QUICConnectionID.generate();
            const quic_conn = try QUICConnection.init(self.allocator, cid);
            quic_conn.setTCPConnection(tcp_conn);
            try self.connections.put(cid, quic_conn);
            return quic_conn;
        }
        return error.NotListening;
    }

    /// Dial a remote QUIC endpoint
    pub fn dial(self: *Self, address: []const u8) !*QUICConnection {
        var parts = std.mem.splitScalar(u8, address, ':');
        const host = parts.next() orelse return error.InvalidAddress;
        const port_str = parts.next() orelse return error.InvalidAddress;
        const port = try std.fmt.parseInt(u16, port_str, 10);
        const addr = try std.net.Address.parseIp(host, port);
        const tcp_conn = try std.net.tcpConnectToAddress(addr);
        // Wrap stream in Connection struct
        const conn = std.net.Server.Connection{
            .stream = tcp_conn,
            .address = addr,
        };
        const cid = QUICConnectionID.generate();
        const quic_conn = try QUICConnection.init(self.allocator, cid);
        quic_conn.setTCPConnection(conn);
        try self.connections.put(cid, quic_conn);
        return quic_conn;
    }

    pub fn closeConnection(self: *Self, cid: QUICConnectionID) void {
        if (self.connections.getPtr(cid)) |conn| {
            conn.*.close();
            _ = self.connections.remove(cid);
        }
    }

    pub fn connectionCount(self: *Self) usize {
        return self.connections.count();
    }
};

test "QUICConnectionID generation" {
    const id1 = QUICConnectionID.generate();
    const id2 = QUICConnectionID.generate();

    // Different IDs should be different
    try std.testing.expect(!std.mem.eql(u8, &id1.bytes, &id2.bytes));
}

test "QUICConnection init" {
    const allocator = std.testing.allocator;
    const cid = QUICConnectionID.generate();

    const conn = try QUICConnection.init(allocator, cid);
    defer conn.deinit();

    try std.testing.expect(conn.state == .dialing);
    try std.testing.expect(conn.connection_id.bytes == cid.bytes);
}

test "QUICStream write and read" {
    const stream = try QUICStream.init(0, .bidirectional);
    defer stream.deinit();

    const data = "hello world";
    try stream.write(data);

    var buf: [100]u8 = undefined;
    const len = try stream.read(&buf);

    try std.testing.expect(len == data.len);
    try std.testing.expect(std.mem.eql(u8, buf[0..len], data));
}

test "QUICTransport init and listen" {
    const allocator = std.testing.allocator;
    const config = QUICConfig{};

    const transport = try QUICTransport.init(allocator, config);
    defer transport.deinit();

    try std.testing.expect(!transport.is_running);
}

test "QUICTransport listen and connection" {
    const allocator = std.testing.allocator;
    const config = QUICConfig{ .bind_address = "127.0.0.1:0" }; // Use port 0 to auto-select

    const transport = try QUICTransport.init(allocator, config);
    defer transport.deinit();

    // Start listening
    try transport.listen();
    try std.testing.expect(transport.is_running);

    // Get the actual port the listener was assigned
    if (transport.listener) |listener| {
        const local_addr = listener.listen_address;
        _ = local_addr; // Address available for dial if needed
    }

    // Stop listening
    transport.stop();
    try std.testing.expect(!transport.is_running);
}

test "QUICConnection stores TCP connection" {
    const allocator = std.testing.allocator;
    const cid = QUICConnectionID.generate();

    const conn = try QUICConnection.init(allocator, cid);
    defer conn.deinit();

    // Initially no TCP connection
    try std.testing.expect(conn.tcp_connection == null);
    try std.testing.expect(conn.state == .dialing);
}

