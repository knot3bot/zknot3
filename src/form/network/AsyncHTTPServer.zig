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
const MainnetExtensionHooks = app.MainnetExtensionHooks;
const M4RpcParams = @import("M4RpcParams.zig");

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

    pub fn initWithDashboard(allocator: std.mem.Allocator, address: std.Io.net.IpAddress, node: *Node, max_requests_per_second: u32) !Self {
        var self = try init(allocator, address);
        var handler = try allocator.create(Dashboard.DashboardHandler);
        handler.* = Dashboard.DashboardHandler.init(allocator);
        handler.setNode(node);
        self.dashboard_handler = handler;
        self.node = node;
        self.max_requests_per_second = max_requests_per_second;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.dashboard_handler) |handler| {
            self.allocator.destroy(handler);
        }
        self.stop();
    }

    fn addrToPosix(addr: std.Io.net.IpAddress) !std.posix.sockaddr.in {
        const ip4 = addr.ip4;
        return .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, ip4.port),
            .addr = @bitCast(ip4.bytes),
            .zero = .{0} ** 8,
        };
    }

    pub fn start(self: *Self) !void {
        self.ring = try std.os.linux.IoUring.init(RING_ENTRIES, 0);
        errdefer self.ring.deinit();

        self.listen_fd = @intCast(std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0));
        if (self.listen_fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(self.listen_fd);

        const reuse: c_int = 1;
        if (std.c.setsockopt(self.listen_fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int)) < 0) {
            return error.SetSockOptFailed;
        }

        const posix_addr = try addrToPosix(self.address);
        if (std.c.bind(self.listen_fd, @ptrCast(&posix_addr), @sizeOf(std.posix.sockaddr.in)) < 0) {
            return error.BindFailed;
        }

        if (std.c.listen(self.listen_fd, 128) < 0) {
            return error.ListenFailed;
        }

        // Submit initial accepts for all idle slots
        for (&self.conns, 0..) |*conn, i| {
            conn.state = .accepting;
            _ = try self.ring.accept(makeUserData(@intCast(i), .accept), self.listen_fd, null, null, 0);
        }
        _ = try self.ring.submit();

        // Spawn dedicated io_uring event loop thread
        self.thread_running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, threadLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        // Signal thread to stop and wait for it
        if (self.thread) |t| {
            self.thread_running.store(false, .seq_cst);
            t.join();
            self.thread = null;
        }
        if (self.listen_fd >= 0) {
            _ = std.c.close(self.listen_fd);
            self.listen_fd = -1;
        }
        self.ring.deinit();
        for (&self.conns) |*conn| {
            if (conn.response) |r| {
                self.allocator.free(r);
                conn.response = null;
            }
            if (conn.fd >= 0 and conn.state != .idle) {
                _ = std.c.close(conn.fd);
                conn.fd = -1;
            }
        }
    }

    /// Dedicated thread entry point for the io_uring event loop.
    fn threadLoop(self: *Self) void {
        while (self.thread_running.load(.seq_cst)) {
            self.tick() catch |err| {
                Log.err("[HTTP] tick error in io_uring thread: {s}", .{@errorName(err)});
            };
            const req = std.c.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&req, null);
        }
    }

    /// Process io_uring completions and drive the connection state machine.
    pub fn tick(self: *Self) !void {
        // 1. Submit pending SQEs
        _ = self.ring.submit() catch 0;

        // 2. Poll CQEs (non-blocking)
        var cqes: [32]std.os.linux.io_uring_cqe = undefined;
        const n = self.ring.copy_cqes(&cqes, 0) catch 0;

        for (0..n) |i| {
            const cqe = cqes[i];
            const parsed = parseUserData(cqe.user_data);
            self.handleCqe(parsed.idx, parsed.op, cqe.res) catch |err| {
                Log.warn("[HTTP] CQE handler error for conn {} op {}: {s}", .{ parsed.idx, @intFromEnum(parsed.op), @errorName(err) });
                // Force connection close on error
                if (parsed.idx < MAX_CONNS) {
                    self.closeConn(@intCast(parsed.idx));
                }
            };
        }

        // 3. Refill accept ops for idle slots
        for (&self.conns, 0..) |*conn, i| {
            if (conn.state == .idle) {
                conn.state = .accepting;
                _ = self.ring.accept(makeUserData(@intCast(i), .accept), self.listen_fd, null, null, 0) catch |err| {
                    Log.warn("[HTTP] Failed to submit accept: {s}", .{@errorName(err)});
                    conn.state = .idle;
                };
            }
        }

        // 4. Final submit
        _ = self.ring.submit() catch 0;
    }

    fn handleCqe(self: *Self, idx: u32, op: Op, res: i32) !void {
        if (idx >= MAX_CONNS) return;
        const conn = &self.conns[idx];

        switch (op) {
            .accept => {
                if (res < 0) {
                    conn.state = .idle; // will be re-accept submitted by tick()
                    return;
                }
                conn.fd = res;
                conn.buf_used = 0;
                conn.state = .reading;
                _ = try self.ring.recv(makeUserData(idx, .recv), conn.fd, .{ .buffer = conn.buf[0..] }, 0);
            },
            .recv => {
                if (res <= 0) {
                    self.closeConn(idx);
                    return;
                }
                const bytes_read = @as(usize, @intCast(res));
                conn.buf_used += bytes_read;

                // Check if we have a complete HTTP request
                const req_data = conn.buf[0..conn.buf_used];
                if (std.mem.indexOf(u8, req_data, "\r\n\r\n")) |_| {
                    // We have a complete request; process it
                    const response = try self.dispatchRequest(req_data);
                    conn.response = response;
                    conn.response_sent = 0;
                    conn.state = .writing;
                    _ = try self.ring.send(makeUserData(idx, .send), conn.fd, response, 0);
                } else if (conn.buf_used >= conn.buf.len) {
                    // Buffer full without complete request
                    self.closeConn(idx);
                } else {
                    // Need more data; submit another recv
                    _ = try self.ring.recv(makeUserData(idx, .recv), conn.fd, .{ .buffer = conn.buf[conn.buf_used..] }, 0);
                }
            },
            .send => {
                if (res <= 0) {
                    self.closeConn(idx);
                    return;
                }
                const bytes_sent = @as(usize, @intCast(res));
                conn.response_sent += bytes_sent;
                const response = conn.response orelse {
                    self.closeConn(idx);
                    return;
                };
                if (conn.response_sent >= response.len) {
                    // Fully sent; close or keep-alive
                    self.closeConn(idx);
                } else {
                    _ = try self.ring.send(makeUserData(idx, .send), conn.fd, response[conn.response_sent..], 0);
                }
            },
            .close => {
                if (conn.response) |r| {
                    self.allocator.free(r);
                    conn.response = null;
                }
                conn.fd = -1;
                conn.buf_used = 0;
                conn.response_sent = 0;
                conn.state = .idle;
            },
        }
    }

    fn closeConn(self: *Self, idx: u32) void {
        if (idx >= MAX_CONNS) return;
        const conn = &self.conns[idx];
        if (conn.fd >= 0) {
            conn.state = .closing;
            _ = self.ring.close(makeUserData(idx, .close), conn.fd) catch |err| {
                Log.warn("[HTTP] close submit failed: {s}", .{@errorName(err)});
                // Fallback to immediate cleanup
                if (conn.response) |r| {
                    self.allocator.free(r);
                    conn.response = null;
                }
                conn.fd = -1;
                conn.buf_used = 0;
                conn.state = .idle;
            };
        } else {
            if (conn.response) |r| {
                self.allocator.free(r);
                conn.response = null;
            }
            conn.buf_used = 0;
            conn.state = .idle;
        }
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

    fn dispatchRequest(self: *Self, request: []const u8) ![]const u8 {
        const path = HTTPServerBase.extractPath(request);
        const body = HTTPServerBase.extractBody(request);
        const trace_id = generateTraceId();

        // Request body size gate
        const content_len = HTTPServerBase.parseContentLength(request) orelse 0;
        const max_body = if (self.node) |n| n.config.network.max_request_body_size else 1024 * 1024;
        if (content_len > max_body) {
            var response = Response{
                .status = .payload_too_large,
                .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
                .body = "{\"error\":\"Request body too large\"}",
            };
            _ = try response.withJSONContentType();
            _ = response.withTraceId(&trace_id) catch {}; return try response.toString(self.allocator);
        }

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
            _ = response.withTraceId(&trace_id) catch {}; return try response.toString(self.allocator);
        }
        self.request_count += 1;

        var response = Response{
            .status = .ok,
            .headers = std.StringArrayHashMapUnmanaged([]const u8).empty,
            .body = null,
        };

        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            // GET / -> Dashboard HTML
            if (self.dashboard_handler) |handler| {
                const html = handler.getHTML() catch {
                    response.status = .internal_server_error;
                    response.body = "Failed to load dashboard";
                    _ = try response.withHeader("Content-Type", "text/html");
                    _ = response.withTraceId(&trace_id) catch {}; return try response.toString(self.allocator);
                };
                response.body = html;
                _ = try response.withHeader("Content-Type", "text/html");
            } else {
                response.status = .not_found;
                response.body = "{\"error\":\"Dashboard not configured\"}";
                _ = try response.withJSONContentType();
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
            response.body = health_body;
            _ = try response.withJSONContentType();
        } else if (std.mem.eql(u8, path, "/metrics")) {
            const metrics_body = if (self.node) |node| blk: {
                const info = node.getNodeInfo();
                const peers = if (node.getP2PServer()) |p2p| p2p.peerCount() else 0;
                const pool_stats = node.getTxnPoolStats();
                var p2p_sq_depth: u64 = 0;
                var p2p_cq_lat_ms: u64 = 0;
                var p2p_fallback_count: u64 = 0;
                if (node.getP2PServer()) |p2p| {
                    const m = p2p.asyncMetricsSnapshot();
                    p2p_sq_depth = m.sq_depth;
                    p2p_cq_lat_ms = m.cq_lat_ms;
                    p2p_fallback_count = m.fallback_count;
                }
                var metrics_buf: [8192]u8 = undefined;
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
                    "zknot3_txn_pool_executed_total {}\n" ++
                    "\n" ++
                    "# HELP p2p_uring_sq_depth Current io_uring submission queue depth\n" ++
                    "# TYPE p2p_uring_sq_depth gauge\n" ++
                    "p2p_uring_sq_depth {}\n" ++
                    "\n" ++
                    "# HELP p2p_uring_cq_lat_ms io_uring completion queue latency ms\n" ++
                    "# TYPE p2p_uring_cq_lat_ms gauge\n" ++
                    "p2p_uring_cq_lat_ms {}\n" ++
                    "\n" ++
                    "# HELP p2p_fallback_count Number of fallback-path activations\n" ++
                    "# TYPE p2p_fallback_count counter\n" ++
                    "p2p_fallback_count {}\n",
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
                        p2p_sq_depth,
                        p2p_cq_lat_ms,
                        p2p_fallback_count,
                    },
                ) catch |err| {
                    Log.warn("[WARN] Failed to format metrics response: {}", .{err});
                    break :blk "# Error formatting metrics\n";
                };
                break :blk text;
            } else "# No metrics available\n";
            response.body = metrics_body;
            _ = try response.withHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
        } else if (std.mem.eql(u8, path, "/ready")) {
            const is_ready = if (self.node) |node| node.state == .running else false;
            response.body = if (is_ready) "{\"ready\":true}" else "{\"ready\":false}";
            response.status = if (is_ready) .ok else .service_unavailable;
            _ = try response.withJSONContentType();
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
            response.body = peers_body;
            _ = try response.withJSONContentType();
        } else if (std.mem.eql(u8, path, "/tx") and std.mem.startsWith(u8, request, "POST ")) {
            // POST /tx -> Submit transaction
            if (self.node) |node| {
                const b = body orelse {
                    var bad_resp = Response.badRequest("{\"error\":\"Missing body\"}");
                    _ = try bad_resp.withJSONContentType();
                    return try bad_resp.toString(self.allocator);
                };
                if (b.len < 256) {
                    var bad_resp = Response.badRequest("{\"error\":\"Body must contain sender+public_key+signature hex\"}");
                    _ = try bad_resp.withJSONContentType();
                    return try bad_resp.toString(self.allocator);
                }
                const parsed = HTTPServerBase.parseSubmitTransactionBody(b) orelse {
                    var bad_resp = Response.badRequest("{\"error\":\"Invalid sender/public_key/signature hex\"}");
                    _ = try bad_resp.withJSONContentType();
                    return try bad_resp.toString(self.allocator);
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
                    var err_response = switch (err) {
                        error.NotRunning, error.PoolFull => Response.serviceUnavailable("{\"error\":\"Service unavailable - try again later\"}"),
                        error.InvalidSignature => Response.badRequest("{\"error\":\"Invalid transaction signature\"}"),
                        error.NonceTooOld, error.NonceTooNew => Response.badRequest("{\"error\":\"Invalid transaction nonce\"}"),
                        error.GasPriceTooLow => Response.badRequest("{\"error\":\"Gas price too low\"}"),
                        else => Response.internalError("{\"error\":\"Failed to submit transaction\"}"),
                    };
                    _ = try err_response.withJSONContentType();
                    return try err_response.toString(self.allocator);
                };
                response.body = if (submit == .duplicate)
                    "{\"success\":true,\"duplicate\":true}"
                else
                    "{\"success\":true,\"duplicate\":false}";
                _ = try response.withJSONContentType();
            } else {
                response.status = .not_found;
                response.body = "{\"error\":\"Node not configured\"}";
                _ = try response.withJSONContentType();
            }
        } else if (std.mem.startsWith(u8, path, "/api/")) {
            // GET /api/* -> Dashboard API
            if (self.dashboard_handler) |handler| {
                const json = handler.handleAPI(path) catch {
                    response.status = .not_found;
                    response.body = "{\"error\":\"API not found\"}";
                    _ = try response.withJSONContentType();
                    _ = response.withTraceId(&trace_id) catch {}; return try response.toString(self.allocator);
                };
                // Allocate a copy with self.allocator so it stays valid until response is sent
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
const id_str: []const u8 = if (id_val != null and id_val.? == .integer) blk: {
const v = id_val.?.integer;
break :blk std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch "null";
} else "null";
defer if (id_val != null and id_val.? == .integer) self.allocator.free(id_str);

                // Route to method handler
                const result_json: ?[]const u8 = if (std.mem.eql(u8, method_val.string, "knot3_getObject"))
                    "{\"objectId\":\"0x123\",\"version\":1,\"owner\":\"0x0\"}"
                else if (std.mem.eql(u8, method_val.string, "knot3_getCheckpoint"))
                    "{\"sequence\":0,\"digest\":\"0xabc123\"}"
                else if (std.mem.eql(u8, method_val.string, "knot3_getCoins"))
                    "{\"data\":[]}"
                else if (std.mem.eql(u8, method_val.string, "knot3_getLatestCheckpointSequenceNumber"))
                    "0"
                else if (std.mem.eql(u8, method_val.string, "knot3_getEpochs"))
                    "{\"data\":[]}"
                else if (std.mem.eql(u8, method_val.string, "knot3_syncEpochState"))
                    "{\"epoch\":0,\"protocolVersion\":1}"
                else if (std.mem.eql(u8, method_val.string, "knot3_getEpochInfo"))
                    "{\"epoch\":0,\"total_stake\":0,\"validators\":{\"active_validators\":{\"data\":[]}},\"initial_epoch_version\":0}"
                else if (std.mem.eql(u8, method_val.string, "knot3_submitStakeOperation")) blk: {
                    const node = self.node orelse {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Node not configured\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.internalError(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const params_val = parsed.value.object.get("params") orelse {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"missing params\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.badRequest(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const input = M4RpcParams.parseStakeOperationInput(params_val) catch {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"invalid knot3_submitStakeOperation params\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.badRequest(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const op_id = node.submitStakeOperation(input) catch |err| {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"";
                        const err_suffix = "\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, @errorName(err), err_suffix, id_str, "}" });
                        var http_resp = Response.internalError(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    break :blk try std.fmt.allocPrint(self.allocator, "{{\"status\":\"accepted\",\"operationId\":{d}}}", .{op_id});
                } else if (std.mem.eql(u8, method_val.string, "knot3_submitGovernanceProposal")) blk: {
                    const node = self.node orelse {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Node not configured\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.internalError(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const params_val = parsed.value.object.get("params") orelse {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"missing params\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.badRequest(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const input = M4RpcParams.parseGovernanceProposalInput(params_val) catch {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"invalid knot3_submitGovernanceProposal params\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.badRequest(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const proposal_id = node.submitGovernanceProposal(input) catch |err| {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"";
                        const err_suffix = "\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, @errorName(err), err_suffix, id_str, "}" });
                        var http_resp = Response.internalError(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    break :blk try std.fmt.allocPrint(self.allocator, "{{\"status\":\"accepted\",\"proposalId\":{d}}}", .{proposal_id});
                } else if (std.mem.eql(u8, method_val.string, "knot3_getCheckpointProof")) blk: {
                    const node = self.node orelse {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Node not configured\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.internalError(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const params_val = parsed.value.object.get("params") orelse {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"missing params\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.badRequest(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const req = M4RpcParams.parseCheckpointProofRequest(params_val) catch {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"invalid knot3_getCheckpointProof params\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
                        var http_resp = Response.badRequest(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
                    };
                    const proof = node.buildCheckpointProof(req) catch |err| {
                        const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"";
                        const err_suffix = "\"},\"id\":";
                        const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, @errorName(err), err_suffix, id_str, "}" });
                        var http_resp = Response.internalError(response_body);
                        _ = try http_resp.withJSONContentType();
                        return try http_resp.toString(self.allocator);
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
                }
                else
                    null;

                if (result_json) |r| {
                    // r is a JSON string literal like "{\"objectId\":\"0x123\"}"
                    // Use concatenation to avoid format string conflicts
                    const header = "{\"jsonrpc\":\"2.0\",\"result\":";
                    const footer = ",\"id\":";
                    const response_body = try std.mem.concat(self.allocator, u8, &.{ header, r, footer, id_str, "}" });
                    var http_resp = Response.ok(response_body);
                    _ = try http_resp.withJSONContentType();
                    return try http_resp.toString(self.allocator);
                } else {
                    const err_prefix = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":";
                    const response_body = try std.mem.concat(self.allocator, u8, &.{ err_prefix, id_str, "}" });
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

        _ = response.withTraceId(&trace_id) catch {}; return try response.toString(self.allocator);
    }
};