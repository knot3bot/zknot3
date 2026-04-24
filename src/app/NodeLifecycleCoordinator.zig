//! NodeLifecycleCoordinator - startup/recovery lifecycle orchestration

const std = @import("std");
const Log = @import("Log.zig");
const ObjectStore = @import("../form/storage/ObjectStore.zig").ObjectStore;

pub fn recoverFromDisk(object_store: ?*ObjectStore) !void {
    if (object_store) |store| {
        const result = try store.recover();
        if (result.errors > 0) return error.RecoveryFailed;
    }
    Log.info("Node recovered from disk", .{});
}

pub fn runStart(node: anytype) !void {
    if (node.state != .initializing) return error.InvalidState;
    try node.validateConfig();
    node.state = .starting;
    try recoverFromDisk(node.object_store);
    if (@hasDecl(@TypeOf(node.*), "replayMainnetM4Wal")) {
        try node.replayMainnetM4Wal();
    }
    if (node.p2p_server) |server| {
        try server.start();
        Log.info("P2P server listening on 0.0.0.0:{}", .{node.config.network.p2p_port});
    }
    node.state = .running;
}

test "NodeLifecycleCoordinator recoverFromDisk handles null store" {
    try recoverFromDisk(null);
}

test "NodeLifecycleCoordinator runStart validates state transitions" {
    const MockP2P = struct {
        started: bool = false,
        pub fn start(self: *@This()) !void {
            self.started = true;
        }
    };
    const MockConfig = struct {
        network: struct {
            p2p_port: u16 = 8080,
        } = .{},
    };
    const MockNode = struct {
        state: enum { initializing, starting, running } = .initializing,
        object_store: ?*ObjectStore = null,
        p2p_server: ?*MockP2P = null,
        config: MockConfig = .{},
        validated: bool = false,
        pub fn validateConfig(self: *@This()) !void {
            self.validated = true;
        }
        pub fn replayMainnetM4Wal(_: *@This()) !void {}
    };

    var p2p: MockP2P = .{};
    var node: MockNode = .{
        .p2p_server = &p2p,
    };

    try runStart(&node);
    try std.testing.expect(node.validated);
    try std.testing.expect(node.state == .running);
    try std.testing.expect(p2p.started);
}

test "NodeLifecycleCoordinator runStart rejects non-initializing state" {
    const MockP2P = struct {
        pub fn start(_: *@This()) !void {}
    };
    const MockNode = struct {
        state: enum { initializing, starting, running } = .running,
        object_store: ?*ObjectStore = null,
        p2p_server: ?*MockP2P = null,
        config: struct { network: struct { p2p_port: u16 = 8080 } = .{} } = .{},
        pub fn validateConfig(_: *@This()) !void {}
    };

    var node: MockNode = .{};
    try std.testing.expectError(error.InvalidState, runStart(&node));
}

