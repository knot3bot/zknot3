//! Integration tests for RPC and networking
//!
//! Tests RPC server, HTTP server, and P2P networking.

const std = @import("std");
const RPC = root.form.network.RPC;
const ObjectStore = root.form.storage.ObjectStore;
const root = @import("root.zig");
const HTTPServer = root.form.network.HTTPServer;
const P2P = root.form.network.P2P;

test "RPC server initialization" {
    const allocator = std.testing.allocator;
    var server = try RPC.RPCServer.init(allocator);
    defer server.deinit();

    try std.testing.expect(server.methods.count() == 0);
}

test "RPC server registers method" {
    const allocator = std.testing.allocator;
    var server = try RPC.RPCServer.init(allocator);
    defer server.deinit();

    // Register a test handler
    try server.register("test_method", struct {
        fn handle(ctx: *RPC.RPCContext, params: []const u8) !RPC.RPCResponse {
            _ = ctx;
            _ = params;
            return RPC.RPCResponse.success(null, "test_result");
        }
    }.handle);

    try std.testing.expect(server.methods.contains("test_method"));
}

test "RPC response creation" {
    const resp = RPC.RPCResponse.success(null, "ok");
    try std.testing.expect(resp.error == null);
    try std.testing.expect(resp.result != null);
}

test "RPC error response" {
    const resp = RPC.RPCResponse.error(null, .method_not_found, "Method not found");
    try std.testing.expect(resp.error != null);
    try std.testing.expect(resp.error.?.code == .method_not_found);
}

test "RPC ErrorCode enum values" {
    try std.testing.expect(@intFromEnum(RPC.ErrorCode.parse_error) == -32700);
    try std.testing.expect(@intFromEnum(RPC.ErrorCode.method_not_found) == -32601);
    try std.testing.expect(@intFromEnum(RPC.ErrorCode.internal_error) == -32603);
    try std.testing.expect(@intFromEnum(RPC.ErrorCode.sui_object_not_found) == -32001);
}

test "HTTPServer response creation" {
    const resp = HTTPServer.Response.ok("test body");
    try std.testing.expect(resp.status == .ok);
    try std.testing.expect(resp.body != null);
    try std.testing.expect(resp.body.?.len > 0);
}

test "HTTPServer response with JSON content type" {
    const resp = HTTPServer.Response.ok("test").withJSONContentType();
    try std.testing.expect(resp.headers.contains("Content-Type"));
    try std.testing.expect(std.mem.eql(u8, resp.headers.get("Content-Type").?, "application/json"));
}

test "HTTPServer response not found" {
    const resp = HTTPServer.Response.notFound("not found");
    try std.testing.expect(resp.status == .not_found);
}

test "HTTPServer response bad request" {
    const resp = HTTPServer.Response.badRequest("bad request");
    try std.testing.expect(resp.status == .bad_request);
}

test "HTTPServer response internal error" {
    const resp = HTTPServer.Response.internalError("internal error");
    try std.testing.expect(resp.status == .internal_server_error);
}

test "HTTPServer response with custom header" {
    const resp = HTTPServer.Response.ok("test").withHeader("X-Custom", "value");
    try std.testing.expect(resp.headers.contains("X-Custom"));
    try std.testing.expect(std.mem.eql(u8, resp.headers.get("X-Custom").?, "value"));
}

test "P2P Peer creation" {
    const peer = P2P.Peer{
        .id = [_]u8{1} ** 32,
        .address = "127.0.0.1",
        .port = 8080,
        .is_outbound = true,
        .connected_at = std.time.timestamp(),
        .last_message = std.time.timestamp(),
        .latency_ms = 10,
    };

    try std.testing.expect(peer.isActive());
}

test "P2P createPeerID from public key" {
    const public_key = [_]u8{0xAB} ** 32;
    const peer_id = P2P.createPeerID(public_key);

    // Peer ID should be 32 bytes (Blake3 hash of public key)
    try std.testing.expect(peer_id.len == 32);

    // Same public key should produce same peer ID
    const peer_id2 = P2P.createPeerID(public_key);
    try std.testing.expect(std.mem.eql(u8, &peer_id, &peer_id2));
}

test "P2P NodeState enum values" {
    try std.testing.expect(std.mem.eql(u8, @tagName(P2P.NodeState.initializing), "initializing"));
    try std.testing.expect(std.mem.eql(u8, @tagName(P2P.NodeState.running), "running"));
    try std.testing.expect(std.mem.eql(u8, @tagName(P2P.NodeState.shutting_down), "shutting_down"));
}

test "P2P P2PMessageType values" {
    try std.testing.expect(@intFromEnum(P2P.P2PMessageType.handshake) == 0x01);
    try std.testing.expect(@intFromEnum(P2P.P2PMessageType.ping) == 0x03);
    try std.testing.expect(@intFromEnum(P2P.P2PMessageType.transaction) == 0x10);
    try std.testing.expect(@intFromEnum(P2P.P2PMessageType.block) == 0x11);
}

test "HTTPServer ServerConfig defaults" {
    const config = HTTPServer.ServerConfig{};
    try std.testing.expect(std.mem.eql(u8, config.address, "127.0.0.1"));
    try std.testing.expect(config.port == 9000);
    try std.testing.expect(config.keep_alive == true);
    try std.testing.expect(config.timeout_secs == 30);
}

test "HTTPServer StatusCode values" {
    try std.testing.expect(@intFromEnum(HTTPServer.StatusCode.ok) == 200);
    try std.testing.expect(@intFromEnum(HTTPServer.StatusCode.bad_request) == 400);
    try std.testing.expect(@intFromEnum(HTTPServer.StatusCode.not_found) == 404);
    try std.testing.expect(@intFromEnum(HTTPServer.StatusCode.internal_server_error) == 500);
}
