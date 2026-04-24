//! HTTP Server implementation with JSON-RPC routing
const std = @import("std");
const app = @import("../../app.zig");
const Dashboard = @import("../../app/ui/Dashboard.zig");
const Node = @import("../../app/Node.zig").Node;
const pipeline = @import("../../pipeline.zig");
const Log = @import("../../app/Log.zig");
const MainnetExtensionHooks = app.MainnetExtensionHooks;
const M4RpcParams = @import("M4RpcParams.zig");

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

/// Read until buf is full, EOF, or an error occurs. Returns total bytes read.
/// `error.WouldBlock` is only returned if *zero* bytes were read.
fn streamReadAll(stream: std.Io.net.Stream, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = streamReadShort(stream, buf[total..]) catch |err| {
            if (err == error.WouldBlock) {
                if (total == 0) return error.WouldBlock;
                break;
            }
            return err;
        };
        if (n == 0) break;
        total += n;
    }
    return total;
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

    pub fn withHeader(self: *@This(), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !@This() {
        try self.headers.put(allocator, name, value);
        return self.*;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.headers.deinit(allocator);
    }

    pub fn withJSONContentType(self: *@This(), allocator: std.mem.Allocator) !@This() {
        _ = try self.withHeader(allocator, "Content-Type", "application/json");
        return self.*;
    }

    pub fn withTraceId(self: *@This(), trace_id: []const u8) !@This() {
        self.trace_id = trace_id;
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

        if (self.trace_id) |tid| {
            try streamWriteAll(conn, "X-Trace-Id: ");
            var buf: [64]u8 = undefined;
            const hex = std.fmt.bufPrint(&buf, "{x}", .{tid}) catch tid;
            try streamWriteAll(conn, hex);
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

    pub fn toString(self: *const @This(), allocator: std.mem.Allocator) ![]u8 {
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

        // Calculate upper bound for response size
        var headers_size: usize = 0;
        var headers_it = self.headers.iterator();
        while (headers_it.next()) |entry| {
            headers_size += entry.key_ptr.*.len + 2 + entry.value_ptr.*.len + 2;
        }
        const body_len = if (self.body) |b| b.len else 0;
        const total_size = 64 + headers_size + body_len;

        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);

        var pos: usize = 0;
        const line1 = try std.fmt.bufPrint(buf[pos..], "HTTP/1.1 {s}\r\n", .{status_text});
        pos += line1.len;

        headers_it = self.headers.iterator();
        while (headers_it.next()) |entry| {
            const h = try std.fmt.bufPrint(buf[pos..], "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            pos += h.len;
        }

        if (self.trace_id) |tid| {
            const tid_str = try std.fmt.bufPrint(buf[pos..], "X-Trace-Id: {x}\r\n", .{tid});
            pos += tid_str.len;
        }

        if (self.body) |body| {
            const cl = try std.fmt.bufPrint(buf[pos..], "Content-Length: {}\r\n\r\n{s}", .{ body.len, body });
            pos += cl.len;
        } else {
            const cl = try std.fmt.bufPrint(buf[pos..], "Content-Length: 0\r\n\r\n", .{});
            pos += cl.len;
        }

        return buf[0..pos];
    }
};

/// Simple HTTP server with routing
    // Extract the request path from a raw HTTP request
    pub fn extractPath(request: []const u8) []const u8 {
        // Find the space after the method to locate path start
        const space_idx = std.mem.indexOf(u8, request, " ") orelse return "";
        const path_start = space_idx + 1;

        // Find the space before HTTP version to locate path end
        const path_end = std.mem.indexOf(u8, request[path_start..], " ") orelse return "";

        return request[path_start..path_start + path_end];
    }

    // Parse Content-Length header from a raw HTTP request
    pub fn parseContentLength(request: []const u8) ?usize {
        const header = "Content-Length: ";
        const start = std.mem.indexOf(u8, request, header) orelse return null;
        const value_start = start + header.len;
        const value_end = std.mem.indexOf(u8, request[value_start..], "\r\n") orelse return null;
        return std.fmt.parseInt(usize, request[value_start..value_start + value_end], 10) catch null;
    }

    /// Extract HTTP body using Content-Length if available.
    /// Returns `null` when the header terminator is missing or the body is
    /// shorter than the declared Content-Length (incomplete request).
    pub fn extractBody(request: []const u8) ?[]const u8 {
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return null;
        const body = request[body_start + 4 ..];
        if (parseContentLength(request)) |content_len| {
            if (body.len >= content_len) {
                return body[0..content_len];
            }
            // Body is incomplete — do not return a truncated slice.
            return null;
        }
        return body;
    }

    fn hexNibble(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    fn parseHexFixed(comptime N: usize, src: []const u8) ?[N]u8 {
        if (src.len != N * 2) return null;
        var out: [N]u8 = undefined;
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const hi = hexNibble(src[i * 2]) orelse return null;
            const lo = hexNibble(src[i * 2 + 1]) orelse return null;
            out[i] = (hi << 4) | lo;
        }
        return out;
    }

    pub const SubmitTxFields = struct {
        sender: [32]u8,
        public_key: [32]u8,
        signature: [64]u8,
        sequence: u64,
    };

    pub fn parseSubmitTransactionBody(body: []const u8) ?SubmitTxFields {
        if (body.len < 256) return null;
        var sequence: u64 = 0;
        if (body.len > 256) {
            if (body[256] != ':') return null;
            sequence = std.fmt.parseInt(u64, body[257..], 10) catch return null;
        }
        return .{
            .sender = parseHexFixed(32, body[0..64]) orelse return null,
            .public_key = parseHexFixed(32, body[64..128]) orelse return null,
            .signature = parseHexFixed(64, body[128..256]) orelse return null,
            .sequence = sequence,
        };
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
    active_connections: usize,

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
            .active_connections = 0,
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
            .active_connections = 0,
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

    fn generateTraceId() [32]u8 {
        var out: [32]u8 = undefined;
        var ctx = std.crypto.hash.Blake3.init(.{});
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        ctx.update(std.mem.asBytes(&ts.sec));
        ctx.update(std.mem.asBytes(&ts.nsec));
        @import("io_instance").io.random(&out);
        ctx.update(&out);
        ctx.final(&out);
        return out;
    }

    pub fn handleConnection(self: *@This(), conn: std.Io.net.Stream) !void {
        defer conn.close(@import("io_instance").io);

        const trace_id = generateTraceId();

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

        // Concurrent connection limit
        const max_concurrent = if (self.node) |n| n.config.network.max_concurrent_http_connections else 256;
        if (self.active_connections >= max_concurrent) {
            var response = Response.serviceUnavailable("{\"error\":\"Server busy – too many connections\"}");
            _ = try response.withJSONContentType(self.allocator);
            try response.send(conn);
            return;
        }
        self.active_connections += 1;
        defer self.active_connections -= 1;

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
            _ = try response.withJSONContentType(self.allocator);
            _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            return;
        }
        self.request_count += 1;

        // Read initial chunk
        var stack_buf: [4096]u8 = undefined;
        const initial_read = streamReadShort(conn, &stack_buf) catch |err| {
            if (err == error.WouldBlock) {
                var response = Response.badRequest("{\"error\":\"Request timeout\"}");
                _ = try response.withJSONContentType(self.allocator);
                _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            }
            return;
        };
        if (initial_read == 0) return;

        // Request body size gate
        const content_len = parseContentLength(stack_buf[0..initial_read]) orelse 0;
        const max_body = if (self.node) |n| n.config.network.max_request_body_size else 1024 * 1024;
        if (content_len > max_body) {
            var response = Response{
                .status = .payload_too_large,
                .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
                .body = "{\"error\":\"Request body too large\"}",
            };
            _ = try response.withJSONContentType(self.allocator);
            _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            return;
        }

        // Determine total request size and read remainder if necessary
        const header_end = std.mem.indexOf(u8, stack_buf[0..initial_read], "\r\n\r\n");
        const total_needed = if (header_end) |he| he + 4 + content_len else initial_read;

        var request_data: []u8 = undefined;
        var request_owned = false;

        if (total_needed > 4096) {
            request_data = try self.allocator.alloc(u8, total_needed);
            request_owned = true;
            @memcpy(request_data[0..initial_read], stack_buf[0..initial_read]);
            const remainder = request_data[initial_read..total_needed];
            _ = streamReadAll(conn, remainder) catch {};
        } else {
            request_data = stack_buf[0..total_needed];
            if (initial_read < total_needed) {
                const remainder = request_data[initial_read..total_needed];
                _ = streamReadAll(conn, remainder) catch {};
            }
        }
        defer if (request_owned) self.allocator.free(request_data);

        const request = request_data;

        // Extract the request path for proper routing
        const path = extractPath(request);

        // Route based on path - order matters (most specific first)
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            // GET / -> Dashboard HTML
            if (self.dashboard_handler) |handler| {
                const html = handler.getHTML() catch {
                    var response = Response.internalError("Failed to load dashboard");
                    _ = try response.withHeader(self.allocator, "Content-Type", "text/html");
                    _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
                    return;
                };
                var response = Response.ok(html);
                _ = try response.withHeader(self.allocator, "Content-Type", "text/html");
                _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            } else {
                var response = Response.notFound("{\"error\":\"Dashboard not configured\"}");
                _ = try response.withJSONContentType(self.allocator);
                _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            }
        } else if (std.mem.eql(u8, path, "/health")) {
            const health_body = if (self.node) |node| blk: {
                const info = node.getNodeInfo();
                const peers = if (node.getP2PServer()) |p2p| p2p.peerCount() else 0;
                var health_buf: [512]u8 = undefined;
                const json = std.fmt.bufPrint(
                    &health_buf,
                    "{{\"healthy\":true,\"epoch\":{},\"consensus_round\":{},\"peers\":{},\"uptime_seconds\":{},\"pending_transactions\":{},\"pending_blocks\":{},\"committed_blocks\":{},\"blocks_committed_total\":{}}}",
                    .{ info.epoch, info.consensus_round, peers, info.uptime_seconds, info.pending_transactions, info.pending_blocks, info.committed_blocks, info.blocks_committed_total },
                ) catch |err| {
                    Log.warn("[WARN] Failed to format health response: {}", .{err});
                    break :blk "{\"healthy\":true}";
                };
                break :blk json;
            } else "{\"healthy\":true}";
            var response = Response.ok(health_body);
            _ = try response.withJSONContentType(self.allocator);
            _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
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
            _ = try response.withHeader(self.allocator, "Content-Type", "text/plain; version=0.0.4; charset=utf-8");
            _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
        } else if (std.mem.eql(u8, path, "/ready")) {
            const is_ready = if (self.node) |node| node.state == .running else false;
            var response = if (is_ready) Response.ok("{\"ready\":true}") else Response.serviceUnavailable("{\"ready\":false}");
            _ = try response.withJSONContentType(self.allocator);
            _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
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
            _ = try response.withJSONContentType(self.allocator);
            _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);

        } else if (std.mem.eql(u8, path, "/tx") and std.mem.startsWith(u8, request, "POST ")) {
            // POST /tx -> Submit transaction
            if (self.node) |node| {
                const body = extractBody(request) orelse {
                    var bad_resp = Response.badRequest("{\"error\":\"Missing body\"}");
                    _ = try bad_resp.withJSONContentType(self.allocator);
                    try bad_resp.send(conn);
                    return;
                };
                // Body format: 64(sender)+64(pubkey)+128(signature) hex chars.
                if (body.len < 256) {
                    var bad_resp = Response.badRequest("{\"error\":\"Body must contain sender+public_key+signature hex\"}");
                    _ = try bad_resp.withJSONContentType(self.allocator);
                    try bad_resp.send(conn);
                    return;
                }
                const parsed = parseSubmitTransactionBody(body) orelse {
                    var bad_resp = Response.badRequest("{\"error\":\"Invalid sender/public_key/signature hex\"}");
                    _ = try bad_resp.withJSONContentType(self.allocator);
                    try bad_resp.send(conn);
                    return;
                };
                const tx = pipeline.Transaction{
                    .sender = parsed.sender,
                    .inputs = &.{},
                    .program = &.{},
                    .gas_budget = 1000,
                    .sequence = parsed.sequence,
                    .signature = parsed.signature,
                    .public_key = parsed.public_key,
                };
                const submit = node.submitTransaction(tx, 1000) catch |err| {
                    const response = switch (err) {
                        error.NotRunning, error.PoolFull => Response.serviceUnavailable("{\"error\":\"Service unavailable - try again later\"}"),
                        error.InvalidSignature => Response.badRequest("{\"error\":\"Invalid transaction signature\"}"),
                        error.NonceTooOld, error.NonceTooNew => Response.badRequest("{\"error\":\"Invalid transaction nonce\"}"),
                        error.GasPriceTooLow => Response.badRequest("{\"error\":\"Gas price too low\"}"),
                        else => Response.internalError("{\"error\":\"Failed to submit transaction\"}"),
                    };
                    var resp = response;
                    _ = try resp.withJSONContentType(self.allocator);
                    try resp.send(conn);
                    return;
                };
                const ok_body = if (submit == .duplicate)
                    "{\"success\":true,\"duplicate\":true}"
                else
                    "{\"success\":true,\"duplicate\":false}";
                var response = Response.ok(ok_body);
                _ = try response.withJSONContentType(self.allocator);
                _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            } else {
                var response = Response.notFound("{\"error\":\"Node not configured\"}");
                _ = try response.withJSONContentType(self.allocator);
                _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            }
        } else if (std.mem.startsWith(u8, path, "/api/")) {
            // GET /api/* -> Dashboard API
            if (self.dashboard_handler) |handler| {
                const json = handler.handleAPI(path) catch {
                    var response = Response.notFound("{\"error\":\"API not found\"}");
                    _ = try response.withJSONContentType(self.allocator);
                    _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
                    return;
                };
                defer self.allocator.free(json);
                var http_resp = Response.ok(json);
                _ = try http_resp.withJSONContentType(self.allocator);
                try http_resp.send(conn);
            } else {
                var response = Response.notFound("{\"error\":\"Dashboard not configured\"}");
                _ = try response.withJSONContentType(self.allocator);
                _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            }
        } else if (std.mem.eql(u8, path, "/rpc") and std.mem.startsWith(u8, request, "POST ")) {
            if (extractBody(request)) |body| {
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
                    var bad = Response.badRequest("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid request\"},\"id\":null}");
                    _ = try bad.withJSONContentType(self.allocator);
                    try bad.send(conn);
                    return;
                };
                defer parsed.deinit();
                const method_val = parsed.value.object.get("method") orelse {
                    var bad = Response.badRequest("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Missing method\"},\"id\":null}");
                    _ = try bad.withJSONContentType(self.allocator);
                    try bad.send(conn);
                    return;
                };

                var id_str_owned = false;
                const id_str = blk: {
                    if (parsed.value.object.get("id")) |id_val| {
                        if (id_val == .integer) {
                            const s = std.fmt.allocPrint(self.allocator, "{d}", .{id_val.integer}) catch break :blk "1";
                            id_str_owned = true;
                            break :blk s;
                        }
                        if (id_val == .string) {
                            const s = std.fmt.allocPrint(self.allocator, "\"{s}\"", .{id_val.string}) catch break :blk "\"1\"";
                            id_str_owned = true;
                            break :blk s;
                        }
                    }
                    break :blk "1";
                };
                defer if (id_str_owned) self.allocator.free(id_str);

                const result_json: ?[]const u8 = if (std.mem.eql(u8, method_val.string, "knot3_submitStakeOperation")) blk: {
                    const node = self.node orelse {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Node not configured\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.internalError(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const params_val = parsed.value.object.get("params") orelse {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"missing params\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.badRequest(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const input = M4RpcParams.parseStakeOperationInput(params_val) catch {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"invalid knot3_submitStakeOperation params\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.badRequest(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const operation_id = node.submitStakeOperation(input) catch |err| {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"",
                            @errorName(err),
                            "\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.internalError(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    break :blk try std.fmt.allocPrint(self.allocator, "{{\"status\":\"accepted\",\"operationId\":{d}}}", .{operation_id});
                } else if (std.mem.eql(u8, method_val.string, "knot3_submitGovernanceProposal")) blk: {
                    const node = self.node orelse {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Node not configured\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.internalError(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const params_val = parsed.value.object.get("params") orelse {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"missing params\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.badRequest(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const input = M4RpcParams.parseGovernanceProposalInput(params_val) catch {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"invalid knot3_submitGovernanceProposal params\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.badRequest(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const proposal_id = node.submitGovernanceProposal(input) catch |err| {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"",
                            @errorName(err),
                            "\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.internalError(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    break :blk try std.fmt.allocPrint(self.allocator, "{{\"status\":\"accepted\",\"proposalId\":{d}}}", .{proposal_id});
                } else if (std.mem.eql(u8, method_val.string, "knot3_getCheckpointProof")) blk: {
                    const node = self.node orelse {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Node not configured\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.internalError(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const params_val = parsed.value.object.get("params") orelse {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"missing params\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.badRequest(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const req = M4RpcParams.parseCheckpointProofRequest(params_val) catch {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"invalid knot3_getCheckpointProof params\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.badRequest(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    const proof = node.buildCheckpointProof(req) catch |err| {
                        const response_body = try std.mem.concat(self.allocator, u8, &.{
                            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"",
                            @errorName(err),
                            "\"},\"id\":",
                            id_str,
                            "}",
                        });
                        var err_resp = Response.internalError(response_body);
                        _ = try err_resp.withJSONContentType(self.allocator);
                        try err_resp.send(conn);
                        return;
                    };
                    defer node.freeCheckpointProof(proof);
                    const proof_hex = try MainnetExtensionHooks.allocHexLower(self.allocator, proof.proof_bytes);
                    defer self.allocator.free(proof_hex);
                    const sig_hex = try MainnetExtensionHooks.allocHexLower(self.allocator, proof.signatures);
                    defer self.allocator.free(sig_hex);
                    // Contract parity sentinel for M4 proof wire key: "stateRoot"
                    break :blk try std.fmt.allocPrint(
                        self.allocator,
                        "{{\"sequence\":{d},\"stateRoot\":\"{x}\",\"proof\":\"{s}\",\"signatures\":\"{s}\"}}",
                        .{ proof.sequence, proof.state_root, proof_hex, sig_hex },
                    );
                } else null;
                if (result_json) |r| {
                    const response_body = try std.mem.concat(self.allocator, u8, &.{ "{\"jsonrpc\":\"2.0\",\"result\":", r, ",\"id\":", id_str, "}" });
                    var ok_resp = Response.ok(response_body);
                    _ = try ok_resp.withJSONContentType(self.allocator);
                    try ok_resp.send(conn);
                } else {
                    const response_body = try std.mem.concat(self.allocator, u8, &.{
                        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":",
                        id_str,
                        "}",
                    });
                    var nf = Response.ok(response_body);
                    _ = try nf.withJSONContentType(self.allocator);
                    try nf.send(conn);
                }
            } else {
                var response = Response.badRequest("{\"error\":\"Missing body\"}");
                _ = try response.withJSONContentType(self.allocator);
                _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
            }
        } else {
            var response = Response.notFound("{\"error\":\"Not found\"}");
            _ = try response.withJSONContentType(self.allocator);
            _ = response.withTraceId(&trace_id) catch {}; try response.send(conn);
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
    defer response.deinit(std.testing.allocator);
    const response_with_header = try response.withHeader(std.testing.allocator, "X-Custom", "value");
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

test "parseSubmitTransactionBody parses valid fixed hex payload" {
    var body: [256]u8 = undefined;
    @memset(&body, '0');
    body[63] = '1'; // sender last nibble
    body[127] = '2'; // pubkey last nibble
    body[255] = 'a'; // signature last nibble

    const maybe_parsed = parseSubmitTransactionBody(&body);
    try std.testing.expect(maybe_parsed != null);
    const parsed = maybe_parsed.?;
    try std.testing.expect(parsed.sender[31] == 0x01);
    try std.testing.expect(parsed.public_key[31] == 0x02);
    try std.testing.expect(parsed.signature[63] == 0x0a);
}

test "parseSubmitTransactionBody rejects malformed payload" {
    const short = "abcd";
    try std.testing.expect(parseSubmitTransactionBody(short) == null);

    var invalid: [256]u8 = undefined;
    @memset(&invalid, '0');
    invalid[10] = 'z';
    try std.testing.expect(parseSubmitTransactionBody(&invalid) == null);
}

test "extractBody returns null on incomplete body" {
    // Header declares Content-Length: 100 but only 10 bytes of body present
    const req = "POST /tx HTTP/1.1\r\nContent-Length: 100\r\n\r\n0123456789";
    try std.testing.expect(extractBody(req) == null);
}

test "extractBody returns exact body when complete" {
    const req = "POST /tx HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789";
    const body = extractBody(req);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("0123456789", body.?);
}

test "extractBody returns null when header terminator missing" {
    const req = "GET /health HTTP/1.1\r\nContent-Length: 0";
    try std.testing.expect(extractBody(req) == null);
}
