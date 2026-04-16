//! HTTP Server implementation with JSON-RPC routing
const std = @import("std");
const app = @import("../../app.zig");
const Dashboard = @import("../../app/ui/Dashboard.zig");
const Node = @import("../../app/Node.zig").Node;
const pipeline = @import("../../pipeline.zig");
const Log = @import("../../app/Log.zig");

fn streamWriteAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var writer = stream.writer(@import("io_instance").io, &.{});
    try writer.interface.writeAll(bytes);
}

fn streamReadShort(stream: std.Io.net.Stream, buf: []u8) !usize {
    var reader = stream.reader(@import("io_instance").io, &.{});
    return reader.interface.readSliceShort(buf) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
    };
}
/// JSON-RPC request
pub const JSONRPCRequest = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?std.json.Value = null,
};

/// JSON-RPC response
pub const JSONRPCResponse = struct {
    jsonrpc: []const u8 = "2.0",
    result: ?std.json.Value = null,
    err: ?JSONRPCError = null,
    id: ?std.json.Value = null,

    pub fn success(result: std.json.Value, id: std.json.Value) @This() {
        return .{ .result = result, .id = id };
    }

    pub fn newError(code: i32, message: []const u8, id: std.json.Value) @This() {
        return .{ .err = .{ .code = code, .message = message }, .id = id };
    }

    pub fn toJSON(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var buf: [256]u8 = undefined;
        if (self.err) |err| {
            const json = std.fmt.bufPrint(&buf,
                "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{},\"message\":\"{s}\"}},\"id\":{}}}",
                .{ err.code, err.message, self.id.?.integer },
            ) catch return error.BufferOverflow;
            return try allocator.dupe(u8, json);
        }
        const json = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":null}}", .{}) catch return error.BufferOverflow;
        return try allocator.dupe(u8, json);
    }
};

pub const JSONRPCError = struct {
    code: i32,
    message: []const u8,
    data: ?[]const u8 = null,
};

/// HTTP status codes
pub const StatusCode = enum(u16) {
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    request_timeout = 408,
    conflict = 409,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    too_many_requests = 429,
};

/// HTTP Response
pub const Response = struct {
    status: StatusCode,
    headers: std.StringArrayHashMapUnmanaged([]const u8),
    body: ?[]const u8,

    pub fn ok(body: []const u8) @This() {
        return .{
            .status = .ok,
            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
            .body = body,
        };
    }

    pub fn json(body: []const u8) @This() {
        return .{
            .status = .ok,
            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
            .body = body,
        };
    }

    pub fn notFound(body: []const u8) @This() {
        return .{
            .status = .not_found,
            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
            .body = body,
        };
    }

    pub fn badRequest(body: []const u8) @This() {
        return .{
            .status = .bad_request,
            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
            .body = body,
        };
    }

    pub fn methodNotAllowed() @This() {
        return .{
            .status = .method_not_allowed,
            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
            .body = null,
        };
    }

    pub fn internalError(body: []const u8) @This() {
        return .{
            .status = .internal_server_error,
            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
            .body = body,
        };
    }
    pub fn serviceUnavailable(body: []const u8) @This() {
        return .{
            .status = .service_unavailable,
            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
            .body = body,
        };
    }

    pub fn withHeader(self: *@This(), name: []const u8, value: []const u8) !@This() {
        try self.headers.put(std.heap.page_allocator, name, value);
        return self.*;
    }

    pub fn withJSONContentType(self: *@This()) !@This() {
        _ = try self.withHeader("Content-Type", "application/json");
        return self.*;
    }

    pub fn send(self: *const @This(), conn: std.Io.net.Stream) !void {
        const status_text = switch (self.status) {
            .ok => "200 OK",
            .created => "201 Created",
            .accepted => "202 Accepted",
            .no_content => "204 No Content",
            .bad_request => "400 Bad Request",
            .unauthorized => "401 Unauthorized",
            .forbidden => "403 Forbidden",
            .not_found => "404 Not Found",
            .method_not_allowed => "405 Method Not Allowed",
            .request_timeout => "408 Request Timeout",
            .conflict => "409 Conflict",
            .payload_too_large => "413 Payload Too Large",
            .uri_too_long => "414 URI Too Long",
            .unsupported_media_type => "415 Unsupported Media Type",
            .internal_server_error => "500 Internal Server Error",
            .not_implemented => "501 Not Implemented",
            .bad_gateway => "502 Bad Gateway",
            .service_unavailable => "503 Service Unavailable",
            .too_many_requests => "429 Too Many Requests",
        };

        try streamWriteAll(conn, "HTTP/1.1 ");
        try streamWriteAll(conn, status_text);
        try streamWriteAll(conn, "\r\n");

        // Write headers from the headers map
        var headers_it = self.headers.iterator();
        while (headers_it.next()) |entry| {
            try streamWriteAll(conn, entry.key_ptr.*);
            try streamWriteAll(conn, ": ");
            try streamWriteAll(conn, entry.value_ptr.*);
            try streamWriteAll(conn, "\r\n");
        }

        if (self.body) |body| {
            try streamWriteAll(conn, "Content-Length: ");
            var buf: [20]u8 = undefined;
            const len_str = try std.fmt.bufPrint(&buf, "{}", .{body.len});
            try streamWriteAll(conn, len_str);
            try streamWriteAll(conn, "\r\n");
        } else {
            try streamWriteAll(conn, "Content-Length: 0\r\n");
        }
        try streamWriteAll(conn, "\r\n");

        if (self.body) |body| {
            try streamWriteAll(conn, body);
        }
    }
};

/// Simple HTTP server with routing
    // Extract the request path from a raw HTTP request
    fn extractPath(request: []const u8) []const u8 {
        // Find the space after the method to locate path start
        const space_idx = std.mem.indexOf(u8, request, " ") orelse return "";
        const path_start = space_idx + 1;

        // Find the space before HTTP version to locate path end
        const path_end = std.mem.indexOf(u8, request[path_start..], " ") orelse return "";

        return request[path_start..path_start + path_end];
    }

    // Parse Content-Length header from a raw HTTP request
    fn parseContentLength(request: []const u8) ?usize {
        const header = "Content-Length: ";
        const start = std.mem.indexOf(u8, request, header) orelse return null;
        const value_start = start + header.len;
        const value_end = std.mem.indexOf(u8, request[value_start..], "\r\n") orelse return null;
        return std.fmt.parseInt(usize, request[value_start..value_start + value_end], 10) catch null;
    }

    // Extract HTTP body using Content-Length if available
    fn extractBody(request: []const u8) ?[]const u8 {
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return null;
        const body = request[body_start + 4 ..];
        if (parseContentLength(request)) |content_len| {
            if (body.len >= content_len) {
                return body[0..content_len];
            }
        }
        return body;
    }


pub const HTTPServer = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    listener: ?std.Io.net.Server,
    address: std.Io.net.IpAddress,
    dashboard_handler: ?*Dashboard.DashboardHandler,
    node: ?*Node,
    request_count: usize,
    last_request_second: i64,
    max_requests_per_second: usize,

    pub fn init(allocator: std.mem.Allocator, address: std.Io.net.IpAddress) !@This() {
        return .{
            .allocator = allocator,
            .listener = null,
            .address = address,
            .dashboard_handler = null,
            .node = null,
            .request_count = 0,
            .last_request_second = 0,
            .max_requests_per_second = 100,
        };
    }

    pub fn initWithDashboard(allocator: std.mem.Allocator, address: std.Io.net.IpAddress, node: *Node, max_requests_per_second: u32) !@This() {
        var handler = try allocator.create(Dashboard.DashboardHandler);
        handler.* = Dashboard.DashboardHandler.init(allocator);
        handler.setNode(node);
        return .{
            .allocator = allocator,
            .listener = null,
            .address = address,
            .dashboard_handler = handler,
            .node = node,
            .request_count = 0,
            .last_request_second = 0,
            .max_requests_per_second = max_requests_per_second,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.dashboard_handler) |handler| {
            self.allocator.destroy(handler);
        }
        self.stop();
    }

    pub fn start(self: *@This()) !void {
        const listener = try self.address.listen(@import("io_instance").io, .{});
        self.listener = listener;

        // Set accept timeout to prevent blocking the event loop indefinitely
        const timeout: std.posix.timeval = if (@hasField(std.posix.timeval, "tv_sec"))
            .{ .tv_sec = 1, .tv_usec = 0 }
        else
            .{ .sec = 1, .usec = 0 };
        std.posix.setsockopt(
            listener.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            Log.warn("[WARN] HTTPServer failed to set accept timeout: {}", .{err});
        };
    }

    pub fn stop(self: *@This()) void {
        if (self.listener) |*l| {
            l.deinit(@import("io_instance").io);
            self.listener = null;
        }
    }

    pub fn accept(self: *@This()) !std.Io.net.Stream {
        if (self.listener) |*l| {
            return try l.accept(@import("io_instance").io);
        }
        return error.NotListening;
    }

    pub fn handleConnection(self: *@This(), conn: std.Io.net.Stream) !void {
        defer conn.close(@import("io_instance").io);

        // Set read/write timeout to prevent malicious clients from blocking the event loop
        const timeout: std.posix.timeval = if (@hasField(std.posix.timeval, "tv_sec"))
            .{ .tv_sec = 5, .tv_usec = 0 }
        else
            .{ .sec = 5, .usec = 0 };
        std.posix.setsockopt(
            conn.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            Log.warn("[WARN] HTTPServer failed to set receive timeout: {}", .{err});
        };
        std.posix.setsockopt(
            conn.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            Log.warn("[WARN] HTTPServer failed to set send timeout: {}", .{err});
        };

        // Rate limiting: global max requests per second
        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        if (now != self.last_request_second) {
            self.last_request_second = now;
            self.request_count = 0;
        }
        if (self.request_count >= self.max_requests_per_second) {
            var response = Response{
                .status = .too_many_requests,
                .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
                .body = "{\"error\":\"Rate limit exceeded\"}",
            };
            _ = try response.withJSONContentType();
            try response.send(conn);
            return;
        }
        self.request_count += 1;


        var buf: [4096]u8 = undefined;
        var net_reader = conn.reader(@import("io_instance").io, &buf);
        const bytes_read = net_reader.interface.readSliceShort(&buf) catch |err| {
            if (err == error.WouldBlock) {
                var response = Response.badRequest("{\"error\":\"Request timeout\"}");
                _ = try response.withJSONContentType();
                try response.send(conn);
            }
            return;
        };
        if (bytes_read == 0) return;

        const request = buf[0..bytes_read];

        // Extract the request path for proper routing
        const path = extractPath(request);

        // Route based on path - order matters (most specific first)
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            // GET / -> Dashboard HTML
            if (self.dashboard_handler) |handler| {
                const html = handler.getHTML() catch {
                    var response = Response.internalError("Failed to load dashboard");
                    _ = try response.withHeader("Content-Type", "text/html");
                    try response.send(conn);
                    return;
                };
                var response = Response.ok(html);
                _ = try response.withHeader("Content-Type", "text/html");
                try response.send(conn);
            } else {
                var response = Response.notFound("{\"error\":\"Dashboard not configured\"}");
                _ = try response.withJSONContentType();
                try response.send(conn);
            }
        } else if (std.mem.eql(u8, path, "/health")) {
            const health_body = if (self.node) |node| blk: {
                const info = node.getNodeInfo();
                const peers = if (node.getP2PServer()) |p2p| p2p.peerCount() else 0;
                var health_buf: [512]u8 = undefined;
                const json = std.fmt.bufPrint(
                    &health_buf,
                    "{{\"healthy\":true,\"consensus_round\":{},\"peers\":{},\"uptime_seconds\":{},\"pending_transactions\":{},\"committed_blocks\":{},\"blocks_committed_total\":{}}}",
                    .{ info.consensus_round, peers, info.uptime_seconds, info.pending_transactions, info.committed_blocks, info.blocks_committed_total },
                ) catch |err| {
                    Log.warn("[WARN] Failed to format health response: {}", .{err});
                    break :blk "{\"healthy\":true}";
                };
                break :blk json;
            } else "{\"healthy\":true}";
            var response = Response.ok(health_body);
            _ = try response.withJSONContentType();
            try response.send(conn);
        } else if (std.mem.eql(u8, path, "/metrics")) {
            const metrics_body = if (self.node) |node| blk: {
                const info = node.getNodeInfo();
                const peers = if (node.getP2PServer()) |p2p| p2p.peerCount() else 0;
                const pool_stats = node.getTxnPoolStats();
                var metrics_buf: [4096]u8 = undefined;
                const text = std.fmt.bufPrint(
                    &metrics_buf,
                    "# HELP zknot3_consensus_round Current consensus round\n" ++
                    "# TYPE zknot3_consensus_round gauge\n" ++
                    "zknot3_consensus_round {}\n" ++
                    "\n" ++
                    "# HELP zknot3_peers_connected Number of connected peers\n" ++
                    "# TYPE zknot3_peers_connected gauge\n" ++
                    "zknot3_peers_connected {}\n" ++
                    "\n" ++
                    "# HELP zknot3_uptime_seconds Node uptime in seconds\n" ++
                    "# TYPE zknot3_uptime_seconds gauge\n" ++
                    "zknot3_uptime_seconds {}\n" ++
                    "\n" ++
                    "# HELP zknot3_pending_transactions Number of pending transactions\n" ++
                    "# TYPE zknot3_pending_transactions gauge\n" ++
                    "zknot3_pending_transactions {}\n" ++
                    "\n" ++
                    "# HELP zknot3_committed_blocks_total Total committed blocks in memory\n" ++
                    "# TYPE zknot3_committed_blocks_total gauge\n" ++
                    "zknot3_committed_blocks_total {}\n" ++
                    "\n" ++
                    "# HELP zknot3_blocks_committed_total Total blocks committed since startup\n" ++
                    "# TYPE zknot3_blocks_committed_total counter\n" ++
                    "zknot3_blocks_committed_total {}\n" ++
                    "\n" ++
                    "# HELP zknot3_txn_pool_size Current transaction pool size\n" ++
                    "# TYPE zknot3_txn_pool_size gauge\n" ++
                    "zknot3_txn_pool_size {}\n" ++
                    "\n" ++
                    "# HELP zknot3_txn_pool_received_total Total transactions received\n" ++
                    "# TYPE zknot3_txn_pool_received_total counter\n" ++
                    "zknot3_txn_pool_received_total {}\n" ++
                    "\n" ++
                    "# HELP zknot3_txn_pool_executed_total Total transactions executed\n" ++
                    "# TYPE zknot3_txn_pool_executed_total counter\n" ++
                    "zknot3_txn_pool_executed_total {}\n",
                    .{
                        info.consensus_round,
                        peers,
                        info.uptime_seconds,
                        info.pending_transactions,
                        info.committed_blocks,
                        info.blocks_committed_total,
                        pool_stats.pending,
                        pool_stats.received_total,
                        pool_stats.executed_total,
                    },
                ) catch |err| {
                    Log.warn("[WARN] Failed to format metrics response: {}", .{err});
                    break :blk "# Error formatting metrics\n";
                };
                break :blk text;
            } else "# No metrics available\n";
            var response = Response.ok(metrics_body);
            _ = try response.withHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
            try response.send(conn);
        } else if (std.mem.eql(u8, path, "/ready")) {
            const is_ready = if (self.node) |node| node.state == .running else false;
            var response = if (is_ready) Response.ok("{\"ready\":true}") else Response.serviceUnavailable("{\"ready\":false}");
            _ = try response.withJSONContentType();
            try response.send(conn);
        } else if (std.mem.eql(u8, path, "/peers")) {
            const peers_body = if (self.node) |node| blk: {
                if (node.getP2PServer()) |p2p| {
                    const peer_ids = p2p.getPeerIDs() catch |err| {
                        Log.warn("[WARN] Failed to get peer IDs: {}", .{err});
                        break :blk "{\"error\":\"Failed to get peers\"}";
                    };
                    defer p2p.allocator.free(peer_ids);
                    var peers_buf: [4096]u8 = undefined;
                    var pos: usize = 0;
                    const prefix = std.fmt.bufPrint(peers_buf[pos..], "{{\"count\":{},\"peers\":[", .{peer_ids.len}) catch break :blk "{\"error\":\"Formatting failed\"}";
                    pos += prefix.len;
                    for (peer_ids, 0..) |id, idx| {
                        if (pos + 68 > peers_buf.len) break;
                        const hex = std.fmt.bufPrint(peers_buf[pos..], "\"{x}\"", .{id}) catch continue;
                        pos += hex.len;
                        if (idx < peer_ids.len - 1) {
                            const comma = std.fmt.bufPrint(peers_buf[pos..], ",", .{}) catch break;
                            pos += comma.len;
                        }
                    }
                    const suffix = std.fmt.bufPrint(peers_buf[pos..], "]}}", .{}) catch break :blk "{\"error\":\"Formatting failed\"}";
                    pos += suffix.len;
                    break :blk peers_buf[0..pos];
                }
                break :blk "{\"count\":0,\"peers\":[]}";
            } else "{\"error\":\"Node not configured\"}";
            var response = Response.ok(peers_body);
            _ = try response.withJSONContentType();
            try response.send(conn);

        } else if (std.mem.eql(u8, path, "/tx") and std.mem.startsWith(u8, request, "POST ")) {
            // POST /tx -> Submit transaction
            if (self.node) |node| {
                var sender: [32]u8 = .{0} ** 32;
                if (extractBody(request)) |body| {
                    // Simple hex parse: expect 64 hex chars for 32-byte sender
                    if (body.len >= 64) {
                        var i: usize = 0;
                        while (i < 32) : (i += 1) {
                            const hi = switch (body[i * 2]) {
                                '0'...'9' => |c| c - '0',
                                'a'...'f' => |c| c - 'a' + 10,
                                'A'...'F' => |c| c - 'A' + 10,
                                else => break,
                            };
                            const lo = switch (body[i * 2 + 1]) {
                                '0'...'9' => |c| c - '0',
                                'a'...'f' => |c| c - 'a' + 10,
                                'A'...'F' => |c| c - 'A' + 10,
                                else => break,
                            };
                            sender[i] = (@as(u8, hi) << 4) | @as(u8, lo);
                        }
                    }
                }
                const tx = pipeline.Transaction{
                    .sender = sender,
                    .inputs = &.{},
                    .program = &.{},
                    .gas_budget = 1000,
                    .sequence = 0,
                };
                node.submitTransaction(tx, 1000) catch |err| {
                    const response = switch (err) {
                        error.NotRunning, error.PoolFull => Response.serviceUnavailable("{\"error\":\"Service unavailable - try again later\"}"),
                        error.TransactionAlreadyExecuted, error.DuplicateTransaction => Response{
                            .status = .conflict,
                            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
                            .body = "{\"error\":\"Transaction already known\"}",
                        },
                        error.GasPriceTooLow => Response.badRequest("{\"error\":\"Gas price too low\"}"),
                        else => Response.internalError("{\"error\":\"Failed to submit transaction\"}"),
                    };
                    var resp = response;
                    _ = try resp.withJSONContentType();
                    try resp.send(conn);
                    return;
                };
                var response = Response.ok("{\"success\":true}");
                _ = try response.withJSONContentType();
                try response.send(conn);
            } else {
                var response = Response.notFound("{\"error\":\"Node not configured\"}");
                _ = try response.withJSONContentType();
                try response.send(conn);
            }
        } else if (std.mem.startsWith(u8, path, "/api/")) {
            // GET /api/* -> Dashboard API
            if (self.dashboard_handler) |handler| {
                const json = handler.handleAPI(path) catch {
                    var response = Response.notFound("{\"error\":\"API not found\"}");
                    _ = try response.withJSONContentType();
                    try response.send(conn);
                    return;
                };
                defer self.allocator.free(json);
                var http_resp = Response.ok(json);
                _ = try http_resp.withJSONContentType();
                try http_resp.send(conn);
            } else {
                var response = Response.notFound("{\"error\":\"Dashboard not configured\"}");
                _ = try response.withJSONContentType();
                try response.send(conn);
            }
        } else if (std.mem.eql(u8, path, "/rpc") and std.mem.startsWith(u8, request, "POST ")) {
            if (extractBody(request)) |body| {
                _ = body;
                const resp = JSONRPCResponse.newError(-32603, "Internal error", .{ .integer = 0 });
                const resp_json = try resp.toJSON(self.allocator);
                var http_resp = Response.internalError(resp_json);
                _ = try http_resp.withJSONContentType();
                try http_resp.send(conn);
            } else {
                var response = Response.badRequest("{\"error\":\"Missing body\"}");
                _ = try response.withJSONContentType();
                try response.send(conn);
            }
        } else {
            var response = Response.notFound("{\"error\":\"Not found\"}");
            _ = try response.withJSONContentType();
            try response.send(conn);
        }
    }

};

test "HTTP Response creation" {
    const response = Response.ok("Hello, World!");
    try std.testing.expect(response.status == .ok);
    try std.testing.expectEqualStrings("Hello, World!", response.body.?);
}

test "HTTP Response with header" {
    var response = Response.ok("Test");
    const response_with_header = try response.withHeader("X-Custom", "value");
    try std.testing.expectEqualStrings("value", response_with_header.headers.get("X-Custom").?);
    try std.testing.expectEqualStrings("value", response.headers.get("X-Custom").?);
}

test "JSON-RPC response success" {
    const response = JSONRPCResponse.success(.{ .string = "test" }, .{ .integer = 1 });
    try std.testing.expect(response.err == null);
    try std.testing.expect(response.result != null);
}

test "JSON-RPC response error" {
    const response = JSONRPCResponse.newError(-32600, "Invalid request", .{ .integer = 1 });
    try std.testing.expect(response.err != null);
    try std.testing.expectEqual(@as(i32, -32600), response.err.?.code);
}
