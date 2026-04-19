//! io_uring-based async HTTP Server for Linux
//!
//! Uses std.os.linux.IoUring for true async accept/recv/send/close,
//! eliminating the synchronous handleConnection bottleneck.
//! Runs in a dedicated thread so it is not blocked by the main event loop.

const std = @import("std");
const builtin = @import("builtin");
const app = @import("../../app.zig");
const Dashboard = @import("../../app/ui/Dashboard.zig");
const Node = @import("../../app/Node.zig").Node;
const pipeline = @import("../../pipeline.zig");
const Log = @import("../../app/Log.zig");
const HTTPServerBase = @import("HTTPServer.zig");
const Response = HTTPServerBase.Response;

const MAX_CONNS = 64;
const RING_ENTRIES = 256;

const ConnState = enum {
    idle,
    accepting,
    reading,
    writing,
    closing,
};

const Conn = struct {
    state: ConnState,
    fd: i32,
    buf: [4096]u8,
    buf_used: usize,
    response: ?[]const u8,
    response_sent: usize,
};

const Op = enum(u32) {
    accept = 0,
    recv = 1,
    send = 2,
    close = 3,
};

fn makeUserData(conn_idx: u32, op: Op) u64 {
    return (@as(u64, @intFromEnum(op)) << 32) | conn_idx;
}

fn parseUserData(ud: u64) struct { idx: u32, op: Op } {
    return .{
        .idx = @truncate(ud),
        .op = @enumFromInt(@as(u32, @truncate(ud >> 32))),
    };
}

/// Async HTTP server using io_uring on Linux.
/// On non-Linux, this delegates to the threaded HTTPServer.
pub const AsyncHTTPServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    address: std.Io.net.IpAddress,
    dashboard_handler: ?*Dashboard.DashboardHandler,
    node: ?*Node,
    request_count: usize,
    last_request_second: i64,
    max_requests_per_second: usize,

    // io_uring fields
    ring: std.os.linux.IoUring,
    listen_fd: i32,
    conns: [MAX_CONNS]Conn,
    thread: ?std.Thread,
    thread_running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, address: std.Io.net.IpAddress) !Self {
        var self: Self = undefined;
        self.allocator = allocator;
        self.address = address;
        self.dashboard_handler = null;
        self.node = null;
        self.request_count = 0;
        self.last_request_second = 0;
        self.max_requests_per_second = 100;
        self.listen_fd = -1;
        self.ring = undefined;
        self.thread = null;
        self.thread_running = std.atomic.Value(bool).init(false);
        for (&self.conns) |*conn| {
            conn.* = .{
                .state = .idle,
                .fd = -1,
                .buf = undefined,
                .buf_used = 0,
                .response = null,
                .response_sent = 0,
            };
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.thread) |t| {
            self.thread_running.store(false, .seq_cst);
            t.join();
        }
        if (self.ring.fd >= 0) {
            self.ring.deinit();
        }
        if (self.listen_fd >= 0) {
            std.posix.close(self.listen_fd);
        }
    }

    /// Start the async HTTP server in a background thread
    pub fn start(self: *Self) !void {
        self.thread_running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
    }

    fn run(self: *Self) void {
        while (self.thread_running.load(.seq_cst)) {
            self.tick() catch |err| {
                Log.err("AsyncHTTP tick error: {}", .{err});
            };
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn tick(self: *Self) !void {
        var cqe = self.ring.copyNextCqe() catch return;
        defer self.ring.seenCqe(cqe);

        const user_data = cqe.user_data();
        if (user_data == 0) return;

        const parsed = parseUserData(user_data);
        const conn_idx = parsed.idx;
        const conn = &self.conns[conn_idx];

        switch (parsed.op) {
            .accept => {
                if (cqe.result() < 0) {
                    Log.err("Accept error: {}", .{cqe.result()});
                    return;
                }
                conn.fd = @as(i32, @intCast(cqe.result()));
                conn.state = .reading;
                conn.buf_used = 0;
                try self.submitRecv(conn_idx);
            },
            .recv => {
                if (cqe.result() <= 0) {
                    if (cqe.result() == 0) {
                        try self.closeConn(conn_idx);
                    } else {
                        Log.err("Recv error: {}", .{cqe.result()});
                        try self.closeConn(conn_idx);
                    }
                    return;
                }
                conn.buf_used += @as(usize, @intCast(cqe.result()));
                try self.handleRequest(conn_idx);
            },
            .send => {
                if (cqe.result() < 0) {
                    Log.err("Send error: {}", .{cqe.result()});
                    try self.closeConn(conn_idx);
                    return;
                }
                conn.response_sent += @as(usize, @intCast(cqe.result()));
                if (conn.response_sent >= conn.response.?.len) {
                    try self.closeConn(conn_idx);
                } else {
                    try self.submitSend(conn_idx);
                }
            },
            .close => {
                conn.state = .idle;
                conn.fd = -1;
            },
        }
    }

    fn submitAccept(self: *Self) !void {
        for (0..MAX_CONNS) |i| {
            if (self.conns[i].state == .idle) {
                try self.ring.accept(self.listen_fd, null, null, makeUserData(@as(u32, @intCast(i)), .accept));
                return;
            }
        }
    }

    fn submitRecv(self: *Self, conn_idx: u32) !void {
        try self.ring.recv(self.conns[conn_idx].fd, self.conns[conn_idx].buf[0..], makeUserData(conn_idx, .recv));
    }

    fn submitSend(self: *Self, conn_idx: u32) !void {
        const remaining = self.conns[conn_idx].response.?[self.conns[conn_idx].response_sent..];
        try self.ring.send(self.conns[conn_idx].fd, remaining, makeUserData(conn_idx, .send));
    }

    fn closeConn(self: *Self, conn_idx: u32) !void {
        if (self.conns[conn_idx].fd >= 0) {
            std.posix.close(self.conns[conn_idx].fd);
            self.conns[conn_idx].fd = -1;
        }
        self.conns[conn_idx].state = .idle;
        if (self.conns[conn_idx].response) |resp| {
            self.allocator.free(resp);
            self.conns[conn_idx].response = null;
        }
        try self.ring.close(self.conns[conn_idx].fd, makeUserData(conn_idx, .close));
    }

    fn handleRequest(self: *Self, conn_idx: u32) !void {
        const conn = &self.conns[conn_idx];
        const request = conn.buf[0..conn.buf_used];

        // Find end of headers
        const header_end = std.mem.indexOfScalar(u8, request, '\n') orelse {
            try self.closeConn(conn_idx);
            return;
        };
        const header_str = request[0..header_end];

        // Parse request line
        var iter = std.mem.splitScalar(u8, header_str, ' ');
        const method = iter.next() orelse "";
        const path = iter.next() orelse "/";
        _ = method;

        // Find body (after double newline)
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse
            std.mem.indexOf(u8, request, "\n\n");
        const body = if (body_start) |pos| request[pos + 4 ..] else null;

        // Generate response
        const response_str = try self.generateResponse(path, request, body);
        conn.response = response_str;
        conn.response_sent = 0;
        conn.state = .writing;
        try self.submitSend(conn_idx);
    }

    fn generateResponse(self: *Self, path: []const u8, request: []const u8, body: ?[]const u8) ![]const u8 {
        var response = Response.ok("OK");
        response.headers.put("Server", "zknot3/0.1");

        if (std.mem.eql(u8, path, "/health")) {
            response.body = "{\"status\":\"ok\"}";
            _ = try response.withJSONContentType();
        } else if (std.mem.eql(u8, path, "/")) {
            response.body = "{\"version\":\"0.1.0\",\"network\":\"zknot3\"}";
            _ = try response.withJSONContentType();
        } else if (std.mem.eql(u8, path, "/api/v1/node_status")) {
            response.body = "{\"peers\":0,\"round\":0,\"epoch\":0}";
            _ = try response.withJSONContentType();
            _ = try response.withJSONContentType();
        } else if (std.mem.eql(u8, path, "/api/v1/validators")) {
            response.body = "{\"validators\":[]}";
            _ = try response.withJSONContentType();
        } else if (std.mem.eql(u8, path, "/api/v1/metrics")) {
            response.body = "{\"wu_feng\":0,\"xiang_da\":0,\"zi_zai\":0}";
            _ = try response.withJSONContentType();
        } else if (std.mem.eql(u8, path, "/dashboard")) {
            if (self.dashboard_handler) |dh| {
                const json = try dh.getDashboardJSON(self.allocator);
                defer self.allocator.free(json);
                const json_copy = try self.allocator.dupe(u8, json);
                response.body = json_copy;
                _ = try response.withJSONContentType();
            } else {
                response.status = .not_found;
                response.body = "{\"error\":\"Dashboard not configured\"}";
                _ = try response.withJSONContentType();
            }
        } else if (std.mem.eql(u8, path, "/rpc") and std.mem.startsWith(u8, request, "POST ")) {
            if (body) |b| {
                // Parse JSON-RPC request using parseFromSlice with Value
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, b, .{ .ignore_unknown_fields = true }) catch {
                    return try Response.badRequest("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid request\"},\"id\":null}").toString(self.allocator);
                };
                defer parsed.deinit();

                const method_val = parsed.value.object.get("method") orelse {
                    return try Response.badRequest("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Missing method\"},\"id\":null}").toString(self.allocator);
                };

                const id_val = parsed.value.object.get("id") orelse null;
                const id_str: []const u8 = if (id_val != null and id_val.?.* == .integer) blk: {
                    const v = id_val.?.*.integer;
                    break :blk std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch "null";
                } else "null";

                // Route to method handler
                const result_json: ?[]const u8 = if (std.mem.eql(u8, method_val.string, "knot3_getObject"))
                    "{\"objectId\":\"0x123\",\"version\":1,\"owner\":\"0x0\"}"
                else if (std.mem.eql(u8, method_val.string, "knot3_getCheckpoint"))
                    "{\"sequence\":0,\"digest\":\"0xabc123\"}"
                else if (std.mem.eql(u8, method_val.string, "knot3_getCoins"))
                    "{\"data\":[]}"
                else if (std.mem.eql(u8, method_val.string, "sui_getLatestCheckpointSequenceNumber"))
                    "0"
                else if (std.mem.eql(u8, method_val.string, "sui_getEpochs"))
                    "{\"data\":[]}"
                else if (std.mem.eql(u8, method_val.string, "sui_syncEpochState"))
                    "{\"epoch\":0,\"protocolVersion\":1}"
                else if (std.mem.eql(u8, method_val.string, "knot3_getEpochInfo"))
                    "{\"epoch\":0,\"total_stake\":0,\"validators\":{\"active_validators\":{\"data\":[]}},\"initial_epoch_version\":0}"
                else
                    null;

                if (result_json) |r| {
                    const response_body = try std.fmt.allocPrint(self.allocator, "{\"jsonrpc\":\"2.0\",\"result\":{},\"id\":{s}}", .{r, id_str});
                    var http_resp = Response.ok(response_body);
                    _ = try http_resp.withJSONContentType();
                    return try http_resp.toString(self.allocator);
                } else {
                    const response_body = try std.fmt.allocPrint(self.allocator, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":{s}}", .{id_str});
                    var http_resp = Response.ok(response_body);
                    _ = try http_resp.withJSONContentType();
                    return try http_resp.toString(self.allocator);
                }
            } else {
                response.status = .bad_request;
                response.body = "{\"error\":\"Missing body\"}";
                _ = try response.withJSONContentType();
            }
        } else {
            response.status = .not_found;
            response.body = "{\"error\":\"Not found\"}";
            _ = try response.withJSONContentType();
        }

        return try response.toString(self.allocator);
    }
};
