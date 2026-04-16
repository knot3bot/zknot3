//! Yamux-style stream multiplexer
//!
//! Reference: rust-libp2p yamux implementation
//!
//! Yamux is a stream multiplexer that:
//! - Multiplexes multiple streams over a single TCP connection
//! - Uses a framed protocol with window-based flow control
//! - Supports half-close and full-close semantics
//! - Provides ordered, reliable delivery within each stream
//!
//! Frame types:
//! - DATA (0): Payload data
//! - WINDOW_UPDATE (1): Flow control window update
//! - PING (2): Keep-alive ping
//! - PING_ACK (3): Keep-alive pong
//! - GO_AWAY (4): Connection shutdown

const std = @import("std");

pub const YamuxConfig = struct {
    /// Maximum frame size
    max_frame_size: usize = 262144,
    /// Initial window size
    initial_window_size: u32 = 256 * 1024,
    /// Maximum window size
    max_window_size: u32 = 1024 * 1024,
    /// Enable ping keep-alive
    enable_ping: bool = true,
    /// Ping interval in seconds
    ping_interval_secs: u64 = 15,
};

pub const FrameType = enum(u8) {
    data = 0x00,
    window_update = 0x01,
    ping = 0x02,
    ping_ack = 0x03,
    go_away = 0x04,
};

pub const GO_AWAY_REASON = enum(u32) {
    normal = 0x00,
    protocol_error = 0x01,
    internal_error = 0x02,
};

pub const Frame = struct {
    const Self = @This();

    frame_type: FrameType,
    flags: u16,
    stream_id: u32,
    length: u32,

    pub const HEADER_SIZE: usize = 12;

    pub fn encode(self: Self, buf: []u8) void {
        std.mem.writeInt(u32, buf[0..4], @intFromEnum(self.frame_type), .big);
        std.mem.writeInt(u16, buf[4..6], self.flags, .big);
        std.mem.writeInt(u32, buf[6..10], self.stream_id, .big);
        std.mem.writeInt(u32, buf[10..14], self.length, .big);
    }

    pub fn decode(buf: []const u8) !Self {
        if (buf.len < HEADER_SIZE) return error.FrameTooShort;

        const frame_type = @as(FrameType, @enumFromInt(std.mem.readInt(u32, buf[0..4], .big)));
        const flags = std.mem.readInt(u16, buf[4..6], .big);
        const stream_id = std.mem.readInt(u32, buf[6..10], .big);
        const length = std.mem.readInt(u32, buf[10..14], .big);

        return Self{
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
            .length = length,
        };
    }

    pub fn hasFlag(self: Self, flag: u16) bool {
        return self.flags & flag != 0;
    }
};

pub const FrameFlags = struct {
    pub const SYN: u16 = 0x01; // Open new stream
    pub const ACK: u16 = 0x02; // Acknowledge stream
    pub const FIN: u16 = 0x04; // Half-close stream
    pub const RST: u16 = 0x08; // Reset stream
};

pub const YamuxStreamState = enum(u8) {
    /// Stream reserved (protocol state)
    reserved = 0,
    /// Waiting for SYN/SYN-ACK
    syn_sent = 1,
    /// Waiting for ACK of SYN-ACK
    syn_received = 2,
    /// Stream open and ready
    open = 3,
    /// We half-closed the stream
    half_closed_local = 4,
    /// Remote half-closed the stream
    half_closed_remote = 5,
    /// Both sides closed
    closed = 6,
    /// Stream reset
    reset = 7,
};

pub const YamuxStream = struct {
    const Self = @This();

    stream_id: u32,
    state: YamuxStreamState,
    is_initiator: bool,

    /// Data waiting to be sent
    send_buffer: std.ArrayList(u8),
    /// Data received
    recv_buffer: std.ArrayList(u8),

    /// Our window size
    send_window: u32,
    /// Their window size
    recv_window: u32,

    /// Bytes sent
    bytes_sent: u64,
    /// Bytes received
    bytes_received: u64,

    pub fn init(stream_id: u32, is_initiator: bool, initial_window: u32) !*Self {
        const self = try std.heap.general_allocator.create(Self);
        errdefer std.heap.general_allocator.destroy(self);
        self.* = .{
            .stream_id = stream_id,
            .state = if (is_initiator) .syn_sent else .reserved,
            .is_initiator = is_initiator,
            .send_buffer = std.ArrayList(u8).init(std.heap.general_allocator),
            .recv_buffer = std.ArrayList(u8).init(std.heap.general_allocator),
            .send_window = initial_window,
            .recv_window = initial_window,
            .bytes_sent = 0,
            .bytes_received = 0,
        };
        errdefer {
            self.send_buffer.deinit();
            self.recv_buffer.deinit();
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.send_buffer.deinit();
        self.recv_buffer.deinit();
        std.heap.general_allocator.destroy(self);
    }

    /// Write data to the stream (subject to flow control)
    pub fn write(self: *Self, data: []const u8) !usize {
        if (self.state != .open and self.state != .half_closed_local) {
            return error.StreamNotOpen;
        }

        const allowed = @min(@as(usize, self.send_window), data.len);
        if (allowed == 0) return error.WindowFull;

        try self.send_buffer.appendSlice(data[0..allowed]);
        return allowed;
    }

    /// Read data from the stream
    pub fn read(self: *Self, buf: []u8) !usize {
        if (self.state != .open and self.state != .half_closed_remote) {
            return 0;
        }

        const available = self.recv_buffer.items.len;
        const to_read = @min(buf.len, available);

        if (to_read == 0) return 0;

        @memcpy(buf[0..to_read], self.recv_buffer.items[0..to_read]);
        self.recv_buffer.items = self.recv_buffer.subscriber(.{ .start = to_read, .len = available - to_read });

        return to_read;
    }

    /// Update receive window (send WINDOW_UPDATE)
    pub fn updateWindow(self: *Self, increment: u32) void {
        self.recv_window +%= increment;
    }

    /// Handle incoming data
    pub fn recvData(self: *Self, data: []const u8) !void {
        if (self.state != .open and self.state != .half_closed_local) {
            return error.StreamNotOpen;
        }
        try self.recv_buffer.appendSlice(data);
        self.bytes_received += data.len;
    }

    /// Check if stream can receive data
    pub fn canReceive(self: Self) bool {
        return self.state == .open or self.state == .half_closed_local;
    }

    /// Check if stream is closed
    pub fn isClosed(self: Self) bool {
        return self.state == .closed or self.state == .reset;
    }
};

pub const YamuxSession = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: YamuxConfig,

    /// All streams (both sides)
    streams: std.AutoArrayHashMapUnmanaged(u32, *YamuxStream),

    /// Next stream ID for initiator
    next_stream_id: u32,

    /// Is this the connection initiator?
    is_initiator: bool,

    /// Connection state
    go_away: bool,
    go_away_reason: GO_AWAY_REASON,

    pub fn init(allocator: std.mem.Allocator, is_initiator: bool, config: YamuxConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .streams = std.AutoArrayHashMapUnmanaged().init(allocator, &.{}, &.{}),
            .next_stream_id = if (is_initiator) 0 else 1,
            .is_initiator = is_initiator,
            .go_away = false,
            .go_away_reason = .normal,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.streams.deinit();
        self.allocator.destroy(self);
    }

    /// Open a new stream
    pub fn openStream(self: *Self) !u32 {
        if (self.go_away) return error.ConnectionGoAway;

        const stream_id = self.next_stream_id;
        self.next_stream_id +%= 4;

        const stream = try YamuxStream.init(stream_id, true, self.config.initial_window_size);
        try self.streams.put(stream_id, stream);

        return stream_id;
    }

    /// Accept an incoming stream
    pub fn acceptStream(self: *Self) ?u32 {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            const stream = entry.value_ptr.*;
            if (stream.state == .syn_received) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }

    /// Get stream by ID
    pub fn getStream(self: *Self, stream_id: u32) ?*YamuxStream {
        return self.streams.get(stream_id);
    }

    /// Handle incoming frame
    pub fn handleFrame(self: *Self, frame: Frame, payload: []const u8) !void {
        if (self.go_away) return;

        switch (frame.frame_type) {
            .data => {
                if (self.streams.getPtr(frame.stream_id)) |stream| {
                    try stream.*.recvData(payload);
                    if (frame.hasFlag(FrameFlags.FIN)) {
                        stream.*.state = .half_closed_remote;
                    }
                }
            },
            .window_update => {
                if (self.streams.getPtr(frame.stream_id)) |stream| {
                    stream.*.send_window = frame.length;
                }
            },
            .ping => {
                // Handle ping - would need to send PING_ACK
            },
            .go_away => {
                self.go_away = true;
                self.go_away_reason = @as(GO_AWAY_REASON, @enumFromInt(frame.length));
            },
            else => {},
        }
    }

    /// Create GO_AWAY frame
    pub fn createGoAway(_: *Self, reason: GO_AWAY_REASON) Frame {
        return Frame{
            .frame_type = .go_away,
            .flags = 0,
            .stream_id = 0,
            .length = @intFromEnum(reason),
        };
    }

    pub fn close(self: *Self) void {
        self.go_away = true;
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.state = .closed;
        }
    }
};

test "Frame encode/decode" {
    const frame = Frame{
        .frame_type = .data,
        .flags = FrameFlags.SYN,
        .stream_id = 123,
        .length = 456,
    };

    var buf: [14]u8 = undefined;
    frame.encode(&buf);

    const decoded = try Frame.decode(&buf);
    try std.testing.expect(decoded.frame_type == .data);
    try std.testing.expect(decoded.flags == FrameFlags.SYN);
    try std.testing.expect(decoded.stream_id == 123);
    try std.testing.expect(decoded.length == 456);
}

test "YamuxSession open/accept stream" {
    const allocator = std.testing.allocator;
    const config = YamuxConfig{};

    const session = try YamuxSession.init(allocator, true, config);
    defer session.deinit();

    const stream_id = try session.openStream();
    try std.testing.expect(stream_id == 0);

    const stream = session.getStream(stream_id);
    try std.testing.expect(stream != null);
}
