const std = @import("std");
const core = @import("../core.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

const Bls = core.Bls;

pub const VerifyOptions = struct {
    /// If true, recompute proof_bytes from (state_root, sequence, object_id) and require equality.
    enforce_proof_bytes: bool = true,
};

/// Rebuild the canonical 80-byte checkpoint proof signing message used by the node.
/// Matches `MainnetExtensionHooks.m4ProofSigningMessage`.
pub fn buildProofBytes(state_root: [32]u8, sequence: u64, object_id: [32]u8) [80]u8 {
    var out: [80]u8 = undefined;
    @memcpy(out[0..8], "ZKNOT3CP");
    @memcpy(out[8..40], &state_root);
    std.mem.writeInt(u64, out[40..48], sequence, .big);
    @memcpy(out[48..80], &object_id);
    return out;
}

fn quorumThreshold(total_stake: u64) u64 {
    // ceil(2/3 * total) + 1 (avoid float)
    // For integers: floor((2*total + 2)/3) + 1 achieves ceil(2/3*total)+1
    return ((2 * total_stake + 2) / 3) + 1;
}

fn bitmapSelected(bitmap: []const u8, idx: usize) bool {
    if (idx >= bitmap.len) return false;
    return bitmap[idx] != 0;
}

pub const Verified = struct {
    quorum_stake: u64,
    total_stake: u64,
};

/// Verify checkpoint proof:
/// - bitmap quorum stake check
/// - BLS aggregated signature verification over proof_bytes
///
/// Assumptions (matches current node behavior):
/// - `blsSignerBitmap` is an array aligned with `validators` where non-zero means selected.
/// - `blsSignature` is a hex string of 96-byte signature (G2 compressed).
/// - `validators[i].bls_public_key` is a 48-byte public key (G1 compressed).
pub fn verifyCheckpointProof(
    allocator: std.mem.Allocator,
    proof: types.CheckpointProof,
    proof_bytes_expected: [80]u8,
    validators: []const types.ValidatorInfo,
    opts: VerifyOptions,
) !Verified {
    if (validators.len == 0) return error.ProtocolInvalidResponse;

    // Decode bitmap + signature from hex (wire currently uses hex strings).
    const bitmap_dec = try types.decodeHexAlloc(allocator, proof.blsSignerBitmap);
    defer bitmap_dec.deinit(allocator);
    const sig_dec = try types.decodeHexAlloc(allocator, proof.blsSignature);
    defer sig_dec.deinit(allocator);
    if (sig_dec.bytes.len != 96) return error.ProtocolInvalidResponse;

    if (opts.enforce_proof_bytes) {
        const proof_bytes_wire = try types.decodeHexAlloc(allocator, proof.proof);
        defer proof_bytes_wire.deinit(allocator);
        if (proof_bytes_wire.bytes.len != 80) return error.ProtocolInvalidResponse;
        if (!std.mem.eql(u8, proof_bytes_wire.bytes, &proof_bytes_expected)) {
            return error.ProtocolInvalidResponse;
        }
    }

    var total: u64 = 0;
    var selected: u64 = 0;
    var pks = std.ArrayList(Bls.PublicKey).empty;
    defer pks.deinit(allocator);

    for (validators, 0..) |v, i| {
        total += v.voting_power;
        if (!bitmapSelected(bitmap_dec.bytes, i)) continue;
        selected += v.voting_power;
        try pks.append(allocator, v.bls_public_key);
    }

    const thr = quorumThreshold(total);
    if (selected < thr) {
        return error.ProtocolInvalidResponse;
    }

    // Aggregate selected public keys and verify aggregated signature.
    const apk = Bls.aggregatePk(pks.items);
    var sig_arr: [96]u8 = undefined;
    @memcpy(&sig_arr, sig_dec.bytes);
    if (!Bls.verifyAggregated(apk, sig_arr, &proof_bytes_expected)) {
        return error.ProtocolInvalidResponse;
    }

    return .{ .quorum_stake = selected, .total_stake = total };
}

