//! Transport - Network message framing and connection management
//!
//! Provides message-based networking with framing, sequencing, and
//! connection state management.

const std = @import("std");
const core = @import("../../core.zig");

/// Transport configuration
pub const TransportConfig = struct {
    bind_address: []const u8 = "0.0.0.0:8080",
    use_quic: bool = true,
    max_connections: usize = 1024,
    recv_buffer_size: usize = 64 * 1024,
    send_buffer_size: usize = 64 * 1024,
    connection_timeout: i64 = 30,
};

/// Message type discriminator
pub const MessageType = enum(u8) {
    transaction = 1,
    block = 2,
    certificate = 3,
    consensus = 4,
    rpc_request = 5,
    rpc_response = 6,
    checkpoint = 7,
    ping = 9,
    pong = 10,
    handshake = 11,
};

/// Message envelope for network transport
pub const Message = struct {
    msg_type: MessageType,
    sender: [32]u8,
    sequence: u64,
    payload: []const u8,

    const Self = @This();

    pub const MAX_MESSAGE_SIZE: usize = 64 * 1024 * 1024;
    pub const HEADER_SIZE: usize = 45;

    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        if (self.payload.len > Self.MAX_MESSAGE_SIZE) {
            return error.MessageTooLarge;
        }

        var buf = try std.ArrayList(u8).initCapacity(allocator, Self.HEADER_SIZE + self.payload.len);
        errdefer buf.deinit(allocator);

        try buf.append(allocator, @intFromEnum(self.msg_type));
        try buf.appendSlice(allocator, &self.sender);

        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, self.sequence, .big);
        try buf.appendSlice(allocator, &seq_buf);

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(self.payload.len), .big);
        try buf.appendSlice(allocator, &len_buf);

        try buf.appendSlice(allocator, self.payload);

        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator, buf: []const u8) !Self {
        if (buf.len < Self.HEADER_SIZE) {
            return error.MessageTooShort;
        }

        var offset: usize = 0;

        const msg_type = @as(MessageType, @enumFromInt(buf[offset]));
        offset += 1;

        const sender = buf[offset..][0..32].*;
        offset += 32;

        const sequence = std.mem.readInt(u64, buf[offset..][0..8], .big);
        offset += 8;

        const payload_len = std.mem.readInt(u32, buf[offset..][0..4], .big);
        offset += 4;

        if (buf.len < offset + payload_len) {
            return error.InvalidMessage;
        }

        const payload = try allocator.dupe(u8, buf[offset..][0..payload_len]);

        return .{
            .msg_type = msg_type,
            .sender = sender,
            .sequence = sequence,
            .payload = payload,
        };
    }
};

/// Connection state
pub const ConnectionState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    handshaking = 2,
    connected = 3,
    closing = 4,
    closed = 5,
};

/// Network connection handle
pub const Connection = struct {
    id: u64,
    state: ConnectionState,
    peer: ?[32]u8,
    last_activity: i64,
    bytes_sent: u64,
    bytes_received: u64,

    const Self = @This();

    pub fn isActive(self: Self) bool {
        return self.state == .connected;
    }

    pub fn updateActivity(self: *Self) void {
        self.last_activity = std.time.timestamp();
    }
};

/// Transport statistics
pub const TransportStats = struct {
    active_connections: usize,
    total_connections: u64,
    bytes_sent: u64,
    bytes_received: u64,
};

/// Transport layer - connection and message management
pub const Transport = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: TransportConfig,
    connections: std.AutoHashMap(u64, Connection),
    next_connection_id: u64,
    total_connections: u64,
    total_bytes_sent: u64,
    total_bytes_received: u64,

    pub fn init(allocator: std.mem.Allocator, config: TransportConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .connections = std.AutoHashMap(u64, Connection).init(allocator),
            .next_connection_id = 0,
            .total_connections = 0,
            .total_bytes_sent = 0,
            .total_bytes_received = 0,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            _ = entry;
        }
        self.connections.deinit();
        self.allocator.destroy(self);
    }

    pub fn connect(self: *Self, peer: [32]u8) !u64 {
        const conn_id = self.next_connection_id;
        self.next_connection_id +%= 1;
        self.total_connections += 1;

        try self.connections.put(conn_id, .{
            .id = conn_id,
            .state = .connecting,
            .peer = peer,
            .last_activity = std.time.timestamp(),
            .bytes_sent = 0,
            .bytes_received = 0,
        });

        return conn_id;
    }

    pub fn accept(self: *Self, peer: [32]u8) !u64 {
        return self.connect(peer);
    }

    pub fn close(self: *Self, conn_id: u64) void {
        if (self.connections.getPtr(conn_id)) |conn| {
            conn.state = .closed;
        }
    }

    pub fn hasConnection(self: Self, conn_id: u64) bool {
        return self.connections.contains(conn_id);
    }

    pub fn getConnectionState(self: Self, conn_id: u64) ?ConnectionState {
        if (self.connections.get(conn_id)) |conn| {
            return conn.state;
        }
        return null;
    }

    pub fn setConnected(self: *Self, conn_id: u64) void {
        if (self.connections.getPtr(conn_id)) |conn| {
            conn.state = .connected;
            conn.updateActivity();
        }
    }

    pub fn send(self: *Self, conn_id: u64, msg: Message) !void {
        if (self.connections.getPtr(conn_id)) |conn| {
            const serialized = try msg.serialize(self.allocator);
            defer self.allocator.free(serialized);

            conn.bytes_sent += serialized.len;
            self.total_bytes_sent += serialized.len;
            conn.updateActivity();
        }
    }

    pub fn recv(self: *Self, conn_id: u64, buf: []const u8) !?Message {
        if (self.connections.getPtr(conn_id)) |conn| {
            conn.bytes_received += buf.len;
            self.total_bytes_received += buf.len;
            conn.updateActivity();

            if (buf.len < Message.HEADER_SIZE) {
                return null;
            }

            return try Message.deserialize(self.allocator, buf);
        }
        return null;
    }

    pub fn removeTimeouts(self: *Self) usize {
        const now = std.time.timestamp();
        var removed: usize = 0;

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.last_activity > self.config.connection_timeout) {
                self.connections.remove(entry.key);
                removed +%= 1;
            }
        }

        return removed;
    }

    pub fn stats(self: Self) TransportStats {
        var active: usize = 0;
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .connected) {
                active += 1;
            }
        }

        return .{
            .active_connections = active,
            .total_connections = self.total_connections,
            .bytes_sent = self.total_bytes_sent,
            .bytes_received = self.total_bytes_received,
        };
    }
};

test "Transport basic operations" {
    const allocator = std.testing.allocator;
    const config = TransportConfig{};
    var transport = try Transport.init(allocator, config);
    defer transport.deinit();

    const peer = [_]u8{1} ** 32;
    const conn_id = try transport.connect(peer);
    try std.testing.expect(conn_id == 0);

    try std.testing.expect(transport.hasConnection(conn_id));
    try std.testing.expect(transport.getConnectionState(conn_id).? == .connecting);

    transport.setConnected(conn_id);
    try std.testing.expect(transport.getConnectionState(conn_id).? == .connected);

    transport.close(conn_id);
    try std.testing.expect(transport.getConnectionState(conn_id).? == .closed);
}

test "Message serialization" {
    const allocator = std.testing.allocator;

    const msg = Message{
        .msg_type = .transaction,
        .sender = [_]u8{0xAB} ** 32,
        .sequence = 12345,
        .payload = "hello world",
    };

    const serialized = try msg.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len == Message.HEADER_SIZE + 11);

    const deserialized = try Message.deserialize(allocator, serialized);
    defer allocator.free(deserialized.payload);

    try std.testing.expect(deserialized.msg_type == .transaction);
    try std.testing.expect(deserialized.sequence == 12345);
    try std.testing.expect(std.mem.eql(u8, deserialized.payload, "hello world"));
}

test "Transport stats" {
    const allocator = std.testing.allocator;
    const config = TransportConfig{};
    var transport = try Transport.init(allocator, config);
    defer transport.deinit();

    const stats = transport.stats();
    try std.testing.expect(stats.active_connections == 0);
    try std.testing.expect(stats.total_connections == 0);
}
