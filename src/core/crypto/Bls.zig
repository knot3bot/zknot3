//! BLS12-381 abstraction surface used by checkpoint proofs.
//! Backed by `supranational/blst` Zig bindings (min-pk variant):
//! - PublicKey compressed: 48 bytes (G1)
//! - Signature compressed: 96 bytes (G2)

const std = @import("std");
const blst = @import("blst");

pub const PublicKey = [48]u8;
pub const Signature = [96]u8;
pub const SecretKey = [32]u8;
pub const Dst = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

fn decodePk(pk_bytes: PublicKey) ?blst.P1_Affine {
    return blst.P1_Affine.from(&pk_bytes) catch null;
}

fn decodeSig(sig_bytes: Signature) ?blst.P2_Affine {
    return blst.P2_Affine.from(&sig_bytes) catch null;
}

pub fn derivePublicKey(seed: SecretKey) PublicKey {
    var sk: blst.SecretKey = .{};
    sk.keygen(&seed, null);
    const pk = blst.P1.from(&sk) catch return @as([48]u8, @splat(0));
    return pk.compress();
}

pub fn sign(seed: SecretKey, message: []const u8) Signature {
    var sk: blst.SecretKey = .{};
    sk.keygen(&seed, null);
    const sig = blst.P2.hash_to(message, Dst, null).sign_with(&sk).to_affine();
    return sig.compress();
}

pub fn aggregatePk(pubkeys: []const PublicKey) PublicKey {
    if (pubkeys.len == 0) return @as([48]u8, @splat(0));
    const first_affine = decodePk(pubkeys[0]) orelse return @as([48]u8, @splat(0));
    var acc = first_affine.to_jacobian();
    var i: usize = 1;
    while (i < pubkeys.len) : (i += 1) {
        const next_affine = decodePk(pubkeys[i]) orelse return @as([48]u8, @splat(0));
        acc.aggregate(&next_affine) catch return @as([48]u8, @splat(0));
    }
    return acc.to_affine().compress();
}

pub fn aggregateSig(signatures: []const Signature) Signature {
    if (signatures.len == 0) return @as([96]u8, @splat(0));
    const first_affine = decodeSig(signatures[0]) orelse return @as([96]u8, @splat(0));
    var acc = first_affine.to_jacobian();
    var i: usize = 1;
    while (i < signatures.len) : (i += 1) {
        const next_affine = decodeSig(signatures[i]) orelse return @as([96]u8, @splat(0));
        acc.aggregate(&next_affine) catch return @as([96]u8, @splat(0));
    }
    return acc.to_affine().compress();
}

pub fn verifyAggregated(message: []const u8, aggregated_pk: PublicKey, aggregated_sig: Signature) bool {
    const pk = decodePk(aggregated_pk) orelse return false;
    const sig = decodeSig(aggregated_sig) orelse return false;
    return sig.core_verify(&pk, true, message, Dst, null) == .SUCCESS;
}


test "BLS sign and verify single" {
    const sk = @as([32]u8, @splat(0x31));
    const pk = derivePublicKey(sk);
    const msg = "hello";
    const sig = sign(sk, msg);
    try std.testing.expect(verifyAggregated(msg, pk, sig));
}

test "BLS aggregate sign and verify" {
    const sk1 = @as([32]u8, @splat(0x31));
    const sk2 = @as([32]u8, @splat(0x32));
    const pk1 = derivePublicKey(sk1);
    const pk2 = derivePublicKey(sk2);
    const msg = "hello";
    const sig1 = sign(sk1, msg);
    const sig2 = sign(sk2, msg);
    const agg_sig = aggregateSig(&[_]Signature{sig1, sig2});
    const agg_pk = aggregatePk(&[_]PublicKey{pk1, pk2});
    try std.testing.expect(verifyAggregated(msg, agg_pk, agg_sig));
}

test "BLS aggregate 3 signers" {
    const sk1 = @as([32]u8, @splat(0x31));
    const sk2 = @as([32]u8, @splat(0x32));
    const sk3 = @as([32]u8, @splat(0x33));
    const pk1 = derivePublicKey(sk1);
    const pk2 = derivePublicKey(sk2);
    const pk3 = derivePublicKey(sk3);
    const msg = @as([32]u8, @splat(0xAB));
    const sig1 = sign(sk1, &msg);
    const sig2 = sign(sk2, &msg);
    const sig3 = sign(sk3, &msg);
    const agg_sig = aggregateSig(&[_]Signature{sig1, sig2, sig3});
    const agg_pk = aggregatePk(&[_]PublicKey{pk1, pk2, pk3});
    try std.testing.expect(verifyAggregated(&msg, agg_pk, agg_sig));
}

/// Compatibility helper for legacy callers.
/// This path cannot prove multi-signer ownership and should not be used by
/// production proof builders.
pub fn aggregateSigners(pubkeys: []const PublicKey, message: []const u8) Signature {
    _ = pubkeys;
    _ = message;
    return @as([96]u8, @splat(0));
}

