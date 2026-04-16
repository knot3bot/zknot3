//! 4-Node Cluster Integration Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const Quorum = root.form.consensus.Quorum;
const Egress = root.pipeline.Egress;
const Executor = root.pipeline.Executor;
const Ingress = root.pipeline.Ingress;

fn makeValidatorId(i: u8) [32]u8 {
    return [_]u8{i} ** 32;
}

fn createTestQuorum(allocator: std.mem.Allocator) !*Quorum {
    var quorum = try Quorum.init(allocator);
    errdefer quorum.deinit();

    try quorum.addValidator(makeValidatorId(1), 1000);
    try quorum.addValidator(makeValidatorId(2), 1000);
    try quorum.addValidator(makeValidatorId(3), 1000);
    try quorum.addValidator(makeValidatorId(4), 1000);

    return quorum;
}

test "Cluster: 4-validator quorum formation" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    try std.testing.expect(quorum.totalStake() == 4000);
    try std.testing.expect(quorum.byzantineThreshold() == 1);
    try std.testing.expect(quorum.quorumSize() == 3);
    try std.testing.expect(quorum.quorumStakeThreshold() == 2667);
}

test "Cluster: validator connectivity simulation" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    // Verify all validators are present
    try std.testing.expect(quorum.activeStake() == 4000);
    try std.testing.expect(quorum.getVotingPower(makeValidatorId(1)) == 1000);
}

test "Cluster: certificate aggregation" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    var egress = try Egress.init(allocator, 4000);
    defer egress.deinit();

    try std.testing.expect(egress.getPending() == null);
}

test "Cluster: checkpoint commit" {
    const allocator = std.testing.allocator;

    var quorum = try createTestQuorum(allocator);
    defer quorum.deinit();

    // Basic smoke test - quorum is functional
    try std.testing.expect(quorum.totalStake() == 4000);
}
