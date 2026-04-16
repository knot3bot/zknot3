//! RPC and Network Integration Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const RPC = root.form.network.RPC;
const HTTPServer = root.form.network.HTTPServer;
const P2P = root.form.network.P2P;

test "RPC: server init" {
    const allocator = std.testing.allocator;

    var server = try RPC.RPCServer.init(allocator);
    defer server.deinit();

    try std.testing.expect(server.handlers.count() == 0);
}

test "RPC: response builders" {
    const resp = HTTPServer.Response.ok("test");
    try std.testing.expect(std.mem.eql(u8, resp.body.?, "test"));
}

test "P2P: node state" {
    try std.testing.expect(@intFromEnum(P2P.NodeState.initializing) >= 0);
    try std.testing.expect(@intFromEnum(P2P.NodeState.bootstrapping) >= 0);
}

test "RPC: register handler" {
    const allocator = std.testing.allocator;

    var server = try RPC.RPCServer.init(allocator);
    defer server.deinit();

    try server.register("test_method", struct {
        fn handle(ctx: *RPC.RPCContext, params: []const u8) anyerror!RPC.RPCResponse {
            _ = ctx;
            _ = params;
            return RPC.RPCResponse.success(null, "{\"ok\":true}");
        }
    }.handle);

    try std.testing.expect(server.handlers.count() == 1);
}
