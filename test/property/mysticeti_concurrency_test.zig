//! Property-style invariants for Mysticeti vote ingestion.
const std = @import("std");
const root = @import("../../src/root.zig");

const Mysticeti = root.form.consensus.Mysticeti;

fn mkVote(voter: [32]u8, round: u64, digest: [32]u8, sig_byte: u8) Mysticeti.Vote {
    return .{
        .voter = voter,
        .stake = 100,
        .round = .{ .value = round },
        .block_digest = digest,
        .signature = [_]u8{sig_byte} ** 64,
    };
}

test "mysticeti_property: same voter+round with same digest is never equivocation" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE12);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var voter: [32]u8 = undefined;
        var digest: [32]u8 = undefined;
        rnd.bytes(&voter);
        rnd.bytes(&digest);
        const round = rnd.intRangeAtMost(u64, 1, 512);
        const a = mkVote(voter, round, digest, 0x11);
        const b = mkVote(voter, round, digest, 0x22);
        try std.testing.expect(Mysticeti.detectEquivocation(a, b) == null);
    }
}

test "mysticeti_property: same voter+round with different digest always yields evidence" {
    var prng = std.Random.DefaultPrng.init(0xA11CE991);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var voter: [32]u8 = undefined;
        var d1: [32]u8 = undefined;
        var d2: [32]u8 = undefined;
        rnd.bytes(&voter);
        rnd.bytes(&d1);
        rnd.bytes(&d2);
        if (std.mem.eql(u8, &d1, &d2)) d2[0] ^= 0x01;
        const round = rnd.intRangeAtMost(u64, 1, 1024);
        const a = mkVote(voter, round, d1, 0x33);
        const b = mkVote(voter, round, d2, 0x44);
        const ev = Mysticeti.detectEquivocation(a, b);
        try std.testing.expect(ev != null);
        try std.testing.expectEqual(round, ev.?.round.value);
        try std.testing.expect(std.mem.eql(u8, &voter, &ev.?.voter));
    }
}

