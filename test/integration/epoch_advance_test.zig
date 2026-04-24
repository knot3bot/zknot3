//! Epoch Advance Integration Test
//!
//! Validates: stake sync to quorum -> epoch advance -> validator set hash rotation.

const std = @import("std");
const Node = @import("../../src/app/Node.zig").Node;
const NodeDependencies = @import("../../src/app/Node.zig").NodeDependencies;
const Config = @import("../../src/app/Config.zig").Config;
const io_mod = @import("io_instance");

fn allocDataDir(allocator: std.mem.Allocator) ![]const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const salt: u64 = @as(u64, @intCast(ts.sec)) ^ (@as(u64, @intCast(ts.nsec)) << 1);
    return try std.fmt.allocPrint(allocator, "test_tmp/epoch_e2e_{x}", .{salt});
}

fn cleanupDataDir(data_dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io_mod.io, data_dir) catch {};
}

test "E2E: advanceEpoch syncs stake and rotates validator set hash" {
    const allocator = std.testing.allocator;

    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = data_dir;

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();
    defer allocator.destroy(config);

    try node.start();
    defer node.stop();

    // Seed stake for two validators via mainnet hooks (M4 path)
    const v1 = [_]u8{0x01} ** 32;
    const v2 = [_]u8{0x02} ** 32;
    _ = try node.mainnet_hooks.submitStakeOperation(.{
        .validator = v1,
        .delegator = v1,
        .amount = 1000,
        .action = .stake,
    });
    _ = try node.mainnet_hooks.submitStakeOperation(.{
        .validator = v2,
        .delegator = v2,
        .amount = 2000,
        .action = .stake,
    });

    const hash_before = node.getM4ValidatorSetHash();

    // Advance epoch
    try node.advanceEpoch();

    const hash_after = node.getM4ValidatorSetHash();
    const epoch_after = node.getM4CurrentEpoch();

    try std.testing.expect(epoch_after > 0);
    try std.testing.expect(!std.mem.eql(u8, &hash_before, &hash_after));
}

test "E2E: advanceEpoch executes approved governance proposals" {
    const allocator = std.testing.allocator;

    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const config = try allocator.create(Config);
    config.* = Config.default();
    config.storage.data_dir = data_dir;

    const deps = NodeDependencies{};
    const node = try Node.init(allocator, config, deps);
    defer node.deinit();
    defer allocator.destroy(config);

    try node.start();
    defer node.stop();

    // Seed validator stake so they can vote
    const v1 = [_]u8{0x01} ** 32;
    _ = try node.mainnet_hooks.submitStakeOperation(.{
        .validator = v1,
        .delegator = v1,
        .amount = 3000,
        .action = .stake,
    });

    // Submit and approve a proposal
    const proposal_id = try node.mainnet_hooks.submitGovernanceProposal(.{
        .proposer = v1,
        .title = "test proposal",
        .description = "auto execute on epoch advance",
        .kind = .parameter_change,
    });
    try node.mainnet_hooks.voteOnProposal(proposal_id, v1, true);
    try std.testing.expectEqual(@import("../../src/app/MainnetExtensionHooks.zig").GovernanceStatus.approved, node.mainnet_hooks.proposals.items[0].status);

    // Advance epoch should auto-execute approved proposals
    try node.advanceEpoch();
    try std.testing.expectEqual(@import("../../src/app/MainnetExtensionHooks.zig").GovernanceStatus.executed, node.mainnet_hooks.proposals.items[0].status);
}
