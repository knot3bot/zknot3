//! Consensus Flow Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const Quorum = root.form.consensus.Quorum;
const Mysticeti = root.form.consensus.Mysticeti;

fn makeId(i: u8) [32]u8 {
    return [_]u8{i} ** 32;
}

test "Consensus: quorum formation" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    try quorum.addValidator(makeId(1), 1000);
    try quorum.addValidator(makeId(2), 1000);
    try quorum.addValidator(makeId(3), 1000);

    try std.testing.expect(quorum.totalStake() == 3000);
    try std.testing.expect(quorum.isQuorum(&.{ makeId(1), makeId(2) }));
}

test "Consensus: block creation" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();
    try quorum.addValidator(makeId(1), 1000);

    var block = try Mysticeti.Block.create(makeId(1), .{ .value = 1 }, &.{}, &.{}, allocator);
    defer block.deinit(allocator);

    try std.testing.expect(block.round.value == 1);
    try std.testing.expect(!block.hasQuorum(0, quorum.quorumStakeThreshold()));
}

test "Consensus: hasQuorum edge cases" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    try quorum.addValidator(makeId(1), 1000);
    try quorum.addValidator(makeId(2), 1000);
    try quorum.addValidator(makeId(3), 1000);

    try std.testing.expect(quorum.isQuorum(&.{ makeId(1), makeId(2) }));
    try std.testing.expect(!quorum.isQuorum(&.{ makeId(1) }));
}

test "Consensus: byzantine thresholds" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    try quorum.addValidator(makeId(1), 1000);
    try quorum.addValidator(makeId(2), 1000);
    try quorum.addValidator(makeId(3), 1000);
    try quorum.addValidator(makeId(4), 1000);

    try std.testing.expect(quorum.byzantineThreshold() == 1);
    try std.testing.expect(quorum.byzantineStakeThreshold() == 1334);
}

test "Consensus: quorum stake threshold" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    try quorum.addValidator(makeId(1), 1000);
    try quorum.addValidator(makeId(2), 2000);
    try quorum.addValidator(makeId(3), 3000);

    try std.testing.expect(quorum.quorumStakeThreshold() == 4001);
    try std.testing.expect(quorum.quorumSize() == 2);
}

test "Consensus: voting power" {
    const allocator = std.testing.allocator;

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    try quorum.addValidator(makeId(1), 1000);
    try quorum.addValidator(makeId(2), 2000);

    try std.testing.expect(quorum.getVotingPower(makeId(1)) == 1000);
    try std.testing.expect(quorum.getVotingPower(makeId(2)) == 2000);
    try std.testing.expect(quorum.getVotingPower(makeId(99)) == 0);
}
