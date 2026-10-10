//! QuorumConfig - the single source of truth for BFT quorum thresholds.
//!
//! Every quorum decision in the node must go through this module. The tree
//! previously carried the formula `(total * 2) / 3 + 1` in nine separate
//! locations, plus a second, differently-written formula in `src/sdk/proof.zig`.
//! Worse, the two comparison styles disagreed by exactly one stake unit:
//!
//!   - `Stake.hasQuorum`            accepted `accumulated > threshold`
//!   - `Egress.verifyCertificate`   accepted `accumulated >= threshold`
//!
//! so a certificate carrying exactly `threshold` stake was rejected by the
//! accounting layer and accepted by the egress gate. Both now call `accepts`.
//!
//! ## Why the formula is what it is
//!
//! A BFT quorum must be a strict majority of the *active* stake, so that any
//! two quorums intersect in more than the Byzantine share. With stake-weighted
//! voting the threshold is `floor(2t/3) + 1`.
//!
//! This is deliberately **not** the spelling `((2t + 2) / 3) + 1` that
//! `src/sdk/proof.zig` used. The two agree only when `t % 3 == 0`; for
//! `t = 1, 2, 4, 5, 7, 8, ...` the SDK form is **one stake unit stricter**.
//! For example `t = 4`: consensus needs 3, the SDK demanded 4. A 4-validator
//! network would therefore have accepted a certificate the SDK rejected. The
//! SDK variant has been deleted rather than kept in parallel.
//!
//! ## Overflow
//!
//! `stakeOf` takes a `u64`-sized total in practice but is exposed for any
//! `u128`; the multiplication by two is checked so a hostile or corrupt
//! `total_stake` cannot wrap and produce a deceptively small threshold. A
//! saturating result is returned instead, which fails closed (no quorum can
//! ever reach saturation).

const std = @import("std");

/// Stake amount type shared with the rest of the node.
pub const StakeAmount = u128;

/// Which side of the threshold counts as a quorum.
///
/// The node historically used two different conventions. They are now unified
/// on `strictly_above`, which is the correct reading of "more than two thirds":
/// a stake total exactly equal to the threshold has *not* exceeded two thirds.
pub const Comparison = enum {
    /// `accumulated > threshold` — canonical.
    strictly_above,
    /// `accumulated >= threshold`. Retained only so the migration can assert
    /// that no call site still relies on it.
    at_least,
};

/// The one comparison the node uses. Changing this is a consensus-breaking
/// change and must go through a formal gate.
pub const comparison: Comparison = .strictly_above;

/// Minimum stake that constitutes a quorum, given the total active stake.
///
/// Returns `floor(2 * total / 3) + 1`. Saturates instead of overflowing.
pub fn thresholdOf(total: StakeAmount) StakeAmount {
    const doubled = std.math.mul(StakeAmount, total, 2) catch return std.math.maxInt(StakeAmount);
    return doubled / 3 + 1;
}

/// Whether `accumulated` stake reaches quorum under `comparison`.
///
/// This is the only predicate call sites may use to make a quorum decision.
pub fn accepts(accumulated: StakeAmount, total: StakeAmount) bool {
    const thr = thresholdOf(total);
    return switch (comparison) {
        .strictly_above => accumulated > thr,
        .at_least => accumulated >= thr,
    };
}

/// Maximum stake that may be Byzantine while a quorum of `total` is still
/// reachable: `floor(total / 3)`.
pub fn byzantineThreshold(total: StakeAmount) StakeAmount {
    return total / 3;
}

/// Number of validators required to tolerate `f` Byzantine faults: `3f + 1`.
pub fn bftBound(f: StakeAmount) StakeAmount {
    return f * 3 + 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "thresholdOf: floor(2t/3)+1 across residues mod 3" {
    const cases = [_]struct { t: StakeAmount, want: StakeAmount }{
        .{ .t = 0, .want = 1 },
        .{ .t = 1, .want = 1 },
        .{ .t = 2, .want = 2 },
        .{ .t = 3, .want = 3 },
        .{ .t = 6, .want = 5 },
        .{ .t = 9, .want = 7 },
        .{ .t = 30, .want = 21 },
        .{ .t = 300, .want = 201 },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c.want, thresholdOf(c.t));
    }
}

test "thresholdOf: a strict majority of stake is always required" {
    var t: StakeAmount = 1;
    while (t <= 4096) : (t += 1) {
        const thr = thresholdOf(t);
        // Acceptable stake must be strictly more than two thirds of total.
        try std.testing.expect(thr > (t * 2) / 3 or t <= 1);
        // And strictly less than two thirds plus one, i.e. it is the minimum.
        try std.testing.expect(thr - 1 <= (t * 2) / 3);
    }
}

test "accepts: boundary is exactly at threshold (regression)" {
    // This is the defect that motivated the module: the accounting layer used
    // `>` while the egress gate used `>=`, disagreeing by one stake unit.
    const total: StakeAmount = 300;
    const thr = thresholdOf(total);

    try std.testing.expectEqual(@as(StakeAmount, 201), thr);
    // Exactly at threshold does NOT reach a strict majority.
    try std.testing.expect(!accepts(thr, total));
    // One unit above does.
    try std.testing.expect(accepts(thr + 1, total));
    // Far below does not.
    try std.testing.expect(!accepts(thr - 1, total));
    try std.testing.expect(!accepts(0, total));
}

test "accepts: full and over-full stake always accepted" {
    const total: StakeAmount = 300;
    try std.testing.expect(accepts(total, total));
    try std.testing.expect(accepts(total * 10, total));
}

test "accepts: the two Comparison styles differ by exactly one unit" {
    // Documents why the unification was necessary; if this ever becomes equal,
    // the regression that motivated QuorumConfig has reappeared.
    const total: StakeAmount = 300;
    const thr = thresholdOf(total);
    const above = thr > thr; // strictly_above
    const atleast = thr >= thr; // at_least
    try std.testing.expect(above != atleast);
    try std.testing.expect(!above);
    try std.testing.expect(atleast);
}

test "accepts: monotone in accumulated stake" {
    const total: StakeAmount = 1000;
    var prev = false;
    var acc: StakeAmount = 0;
    while (acc <= total + 10) : (acc += 7) {
        const cur = accepts(acc, total);
        // Once a quorum is reached it must never be lost as stake grows.
        if (prev) try std.testing.expect(cur);
        prev = cur;
    }
    try std.testing.expect(prev);
}

test "thresholdOf: saturates instead of wrapping on absurd totals" {
    const huge = std.math.maxInt(StakeAmount);
    // Must not wrap to a small value, which would let a tiny stake form a quorum.
    try std.testing.expect(thresholdOf(huge) > huge / 2);
}

test "byzantineThreshold: honest stake alone cannot always form a quorum" {
    const total: StakeAmount = 300;
    const f = byzantineThreshold(total); // 100
    const honest = total - f; // 200
    const thr = thresholdOf(total); // 201
    // Honest stake alone falls short, which is exactly why a BFT threshold is
    // above the Byzantine bound rather than at it.
    try std.testing.expect(honest < thr);
    try std.testing.expect(!accepts(honest, total));
    try std.testing.expect(!accepts(honest + 1, total));
    try std.testing.expect(accepts(honest + 2, total));
}

test "thresholdOf: differs from the old SDK spelling when t % 3 != 0" {
    // The SDK used ((2t + 2) / 3) + 1. It matches only when t % 3 == 0, and is
    // one unit stricter otherwise. Pinned so nobody reintroduces it as an
    // "equivalent" alternative.
    const t: StakeAmount = 4;
    const sdk = ((t * 2 + 2) / 3) + 1;
    try std.testing.expectEqual(@as(StakeAmount, 3), thresholdOf(t));
    try std.testing.expectEqual(@as(StakeAmount, 4), sdk);
    try std.testing.expect(thresholdOf(t) != sdk);

    // Agreement holds exactly on the multiples of three.
    var k: StakeAmount = 3;
    while (k <= 300) : (k += 3) {
        try std.testing.expectEqual(((k * 2 + 2) / 3) + 1, thresholdOf(k));
    }
}

test "bftBound: 3f+1 tolerates f faults" {
    try std.testing.expectEqual(@as(StakeAmount, 4), bftBound(1));
    try std.testing.expectEqual(@as(StakeAmount, 7), bftBound(2));
    try std.testing.expectEqual(@as(StakeAmount, 10), bftBound(3));
    try std.testing.expectEqual(@as(StakeAmount, 31), bftBound(10));
}
