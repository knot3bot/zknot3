const std = @import("std");
const root = @import("../../src/root.zig");
const builtin = @import("builtin");

const P2PServer = root.form.network.P2PServer.P2PServer;
const P2PServerConfig = root.form.network.P2PServer.P2PServerConfig;

test "p2p_async: exposes async backend metrics snapshot" {
    const allocator = std.testing.allocator;
    var server = try P2PServer.init(allocator, P2PServerConfig{});
    defer server.deinit();

    const m = server.asyncMetricsSnapshot();
    if (builtin.os.tag == .linux) {
        try std.testing.expect(m.sq_depth > 0);
        try std.testing.expectEqual(@as(u64, 0), m.fallback_count);
    } else {
        try std.testing.expect(m.fallback_count > 0);
    }
}

