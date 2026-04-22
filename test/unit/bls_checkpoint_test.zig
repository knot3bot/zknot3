const std = @import("std");
const root = @import("../../src/root.zig");

const Bls = root.core.Bls;

test "checkpoint_bls: aggregate verify 2-of-3 succeeds" {
    const msg = "zknot3-checkpoint-msg";
    const s1 = [_]u8{0x11} ** 32;
    const s2 = [_]u8{0x22} ** 32;
    const s3 = [_]u8{0x33} ** 32; // unused signer candidate

    const p1 = Bls.derivePublicKey(s1);
    const p2 = Bls.derivePublicKey(s2);
    const p3 = Bls.derivePublicKey(s3);
    _ = p3;

    const sig1 = Bls.sign(s1, msg);
    const sig2 = Bls.sign(s2, msg);
    const agg_sig = Bls.aggregateSig(&[_]Bls.Signature{ sig1, sig2 });
    const agg_pk = Bls.aggregatePk(&[_]Bls.PublicKey{ p1, p2 });
    try std.testing.expect(Bls.verifyAggregated(msg, agg_pk, agg_sig));
}

test "checkpoint_bls: 3-of-3 succeeds and tampered signature fails" {
    const msg = "zknot3-checkpoint-msg-all";
    const s1 = [_]u8{0x41} ** 32;
    const s2 = [_]u8{0x42} ** 32;
    const s3 = [_]u8{0x43} ** 32;
    const p1 = Bls.derivePublicKey(s1);
    const p2 = Bls.derivePublicKey(s2);
    const p3 = Bls.derivePublicKey(s3);

    const sig1 = Bls.sign(s1, msg);
    const sig2 = Bls.sign(s2, msg);
    const sig3 = Bls.sign(s3, msg);
    var agg_sig = Bls.aggregateSig(&[_]Bls.Signature{ sig1, sig2, sig3 });
    const agg_pk = Bls.aggregatePk(&[_]Bls.PublicKey{ p1, p2, p3 });
    try std.testing.expect(Bls.verifyAggregated(msg, agg_pk, agg_sig));

    agg_sig[0] ^= 0x01;
    try std.testing.expect(!Bls.verifyAggregated(msg, agg_pk, agg_sig));
}

test "checkpoint_bls: tampered message fails verification" {
    const msg = "zknot3-checkpoint-msg-msg";
    const bad = "zknot3-checkpoint-msg-bad";
    const s1 = [_]u8{0x51} ** 32;
    const s2 = [_]u8{0x52} ** 32;
    const p1 = Bls.derivePublicKey(s1);
    const p2 = Bls.derivePublicKey(s2);
    const sig1 = Bls.sign(s1, msg);
    const sig2 = Bls.sign(s2, msg);
    const agg_sig = Bls.aggregateSig(&[_]Bls.Signature{ sig1, sig2 });
    const agg_pk = Bls.aggregatePk(&[_]Bls.PublicKey{ p1, p2 });
    try std.testing.expect(!Bls.verifyAggregated(bad, agg_pk, agg_sig));
}

