//! M4 extension WAL integration: crash tail truncation, cold-start replay, slash dedupe.
const std = @import("std");
const root = @import("../../src/root.zig");

const Config = root.app.Config;
const Node = root.app.Node;
const NodeDependencies = root.app.NodeDependencies;

const io_mod = @import("io_instance");

fn allocDataDir(allocator: std.mem.Allocator) ![]const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const salt: u64 = @as(u64, @intCast(ts.sec)) ^ (@as(u64, @intCast(ts.nsec)) << 1);
    return try std.fmt.allocPrint(allocator, "test_tmp/m4_wal_it_{x}", .{salt});
}

fn cleanupDataDir(data_dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io_mod.io, data_dir) catch {};
}

fn newTestNode(allocator: std.mem.Allocator, data_dir: []const u8) !struct { node: *Node, cfg: *Config } {
    const cfg = try allocator.create(Config);
    cfg.* = Config.default();
    const seed = [_]u8{0x5D} ** 32;
    cfg.authority.signing_key = seed;
    cfg.authority.stake = 1_000_000_000;
    cfg.storage.data_dir = data_dir;
    const node = try Node.init(allocator, cfg, NodeDependencies{});
    return .{ .node = node, .cfg = cfg };
}

test "M4 WAL recovery: restart replay restores stake and slash totals" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);

    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const validator = [_]u8{0x71} ** 32;
    const delegator = [_]u8{0x72} ** 32;

    {
        const h = try newTestNode(allocator, data_dir);
        defer h.node.deinit();
        defer allocator.destroy(h.cfg);
        const node = h.node;
        try node.start();
        _ = try node.submitStakeOperation(.{
            .validator = validator,
            .delegator = delegator,
            .amount = 200,
            .action = .stake,
            .metadata = "it",
        });
        const applied = try node.applyEquivocationEvidence(validator, delegator, 9, "evidence-bytes", 25);
        try std.testing.expect(applied);
        try std.testing.expectEqual(@as(u64, 25), node.getM4TotalSlashed());
        try std.testing.expectEqual(@as(u64, 175), node.getM4ValidatorStake(validator));
    }

    {
        const h2 = try newTestNode(allocator, data_dir);
        defer h2.node.deinit();
        defer allocator.destroy(h2.cfg);
        const node2 = h2.node;
        try node2.start();
        try std.testing.expectEqual(@as(u64, 25), node2.getM4TotalSlashed());
        try std.testing.expectEqual(@as(u64, 175), node2.getM4ValidatorStake(validator));
    }
}

test "M4 WAL recovery: double cold restart is idempotent for slash totals" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);

    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const validator = [_]u8{0x81} ** 32;
    const delegator = [_]u8{0x82} ** 32;

    {
        const h0 = try newTestNode(allocator, data_dir);
        defer h0.node.deinit();
        defer allocator.destroy(h0.cfg);
        const n = h0.node;
        try n.start();
        _ = try n.submitStakeOperation(.{
            .validator = validator,
            .delegator = delegator,
            .amount = 120,
            .action = .stake,
            .metadata = "it",
        });
        _ = try n.applyEquivocationEvidence(validator, delegator, 3, "dup-restart", 15);
    }

    for (0..2) |_| {
        const h = try newTestNode(allocator, data_dir);
        defer h.node.deinit();
        defer allocator.destroy(h.cfg);
        const n = h.node;
        try n.start();
        try std.testing.expectEqual(@as(u64, 15), n.getM4TotalSlashed());
        try std.testing.expectEqual(@as(u64, 105), n.getM4ValidatorStake(validator));
    }
}

test "M4 WAL recovery: equivocation evidence not double-applied live or after replay" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);

    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const validator = [_]u8{0x91} ** 32;
    const delegator = [_]u8{0x92} ** 32;
    const evidence = "same-evidence-payload";

    {
        const h = try newTestNode(allocator, data_dir);
        defer h.node.deinit();
        defer allocator.destroy(h.cfg);
        const n = h.node;
        try n.start();
        _ = try n.submitStakeOperation(.{
            .validator = validator,
            .delegator = delegator,
            .amount = 60,
            .action = .stake,
            .metadata = "it",
        });
        const a1 = try n.applyEquivocationEvidence(validator, delegator, 77, evidence, 12);
        const a2 = try n.applyEquivocationEvidence(validator, delegator, 77, evidence, 12);
        try std.testing.expect(a1);
        try std.testing.expect(!a2);
        try std.testing.expectEqual(@as(u64, 12), n.getM4TotalSlashed());
        try std.testing.expectEqual(@as(u64, 48), n.getM4ValidatorStake(validator));
    }

    {
        const h = try newTestNode(allocator, data_dir);
        defer h.node.deinit();
        defer allocator.destroy(h.cfg);
        const n = h.node;
        try n.start();
        try std.testing.expectEqual(@as(u64, 12), n.getM4TotalSlashed());
        try std.testing.expectEqual(@as(u64, 48), n.getM4ValidatorStake(validator));
        const a3 = try n.applyEquivocationEvidence(validator, delegator, 77, evidence, 12);
        try std.testing.expect(!a3);
        try std.testing.expectEqual(@as(u64, 12), n.getM4TotalSlashed());
    }
}

test "M4 WAL recovery: truncated M4 WAL tail makes restart replay fail closed" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);

    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const validator = [_]u8{0xA1} ** 32;
    const delegator = [_]u8{0xA2} ** 32;

    {
        const h = try newTestNode(allocator, data_dir);
        defer h.node.deinit();
        defer allocator.destroy(h.cfg);
        const n = h.node;
        try n.start();
        _ = try n.submitStakeOperation(.{
            .validator = validator,
            .delegator = delegator,
            .amount = 50,
            .action = .stake,
            .metadata = "first",
        });
        _ = try n.submitStakeOperation(.{
            .validator = validator,
            .delegator = delegator,
            .amount = 10,
            .action = .stake,
            .metadata = "second",
        });
    }

    const wal_rel = try std.fmt.allocPrint(allocator, "{s}/m4_state.wal", .{data_dir});
    defer allocator.free(wal_rel);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io_mod.io,
        wal_rel,
        allocator,
        std.Io.Limit.limited(4 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 20);
    const truncated_len = bytes.len -| 9;
    try std.testing.expect(truncated_len < bytes.len);

    {
        const wf = try std.Io.Dir.cwd().createFile(io_mod.io, wal_rel, .{ .truncate = true, .read = true });
        defer wf.close(io_mod.io);
        try wf.writeStreamingAll(io_mod.io, bytes[0..truncated_len]);
        try wf.sync(io_mod.io);
    }

    const h2 = try newTestNode(allocator, data_dir);
    defer h2.node.deinit();
    defer allocator.destroy(h2.cfg);
    const n2 = h2.node;
    try std.testing.expectError(error.ReadFailed, n2.start());
}

test "M4 WAL recovery: epoch advance and validator set rotation replay across restart" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const expected_hash = [_]u8{0xAB} ** 32;
    {
        const h = try newTestNode(allocator, data_dir);
        defer h.node.deinit();
        defer allocator.destroy(h.cfg);
        try h.node.start();
        try h.node.mainnet_hooks.advanceEpoch(3);
        try h.node.mainnet_hooks.rotateValidatorSet(expected_hash);
        try std.testing.expectEqual(@as(u64, 3), h.node.getM4CurrentEpoch());
        try std.testing.expect(std.mem.eql(u8, &expected_hash, &h.node.getM4ValidatorSetHash()));
    }

    {
        const h2 = try newTestNode(allocator, data_dir);
        defer h2.node.deinit();
        defer allocator.destroy(h2.cfg);
        try h2.node.start();
        try std.testing.expectEqual(@as(u64, 3), h2.node.getM4CurrentEpoch());
        try std.testing.expect(std.mem.eql(u8, &expected_hash, &h2.node.getM4ValidatorSetHash()));
    }
}
