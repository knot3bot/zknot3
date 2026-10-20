//! Offline checkpoint-proof file.
//!
//! `k3prf01 || fields`. Verification uses the genesis validator public keys
//! and `LightClient.verifyCheckpointProofQuorum`, so the checker does not
//! trust the node that produced the proof.

const std = @import("std");
const Genesis = @import("Genesis.zig");
const LightClient = @import("LightClient.zig");
const Validator = @import("../form/consensus/Validator.zig").Validator;
const MainnetExtensionHooks = @import("MainnetExtensionHooks.zig");

pub const magic = "k3prf01";

pub const Proof = struct {
    sequence: u64,
    object_id: [32]u8,
    state_root: [32]u8,
    proof_bytes: []u8,
    signatures: []u8,
    bls_signature: []u8,
    bls_signer_bitmap: []u8,
};

pub fn encode(allocator: std.mem.Allocator, proof: MainnetExtensionHooks.CheckpointProof) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    var b8: [8]u8 = undefined;
    std.mem.writeInt(u64, &b8, proof.sequence, .big);
    try out.appendSlice(allocator, &b8);
    try out.appendSlice(allocator, &proof.object_id);
    try out.appendSlice(allocator, &proof.state_root);
    try writeBlob(&out, allocator, proof.proof_bytes);
    try writeBlob(&out, allocator, proof.signatures);
    try writeBlob(&out, allocator, proof.bls_signature);
    try writeBlob(&out, allocator, proof.bls_signer_bitmap);
    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Proof {
    if (bytes.len < magic.len + 8 + 32 + 32) return error.InvalidProof;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidProof;
    var off: usize = magic.len;
    const sequence = std.mem.readInt(u64, bytes[off..][0..8], .big);
    off += 8;
    const object_id = bytes[off..][0..32].*;
    off += 32;
    const state_root = bytes[off..][0..32].*;
    off += 32;
    const proof_bytes = try readBlob(allocator, bytes, &off);
    errdefer allocator.free(proof_bytes);
    const signatures = try readBlob(allocator, bytes, &off);
    errdefer allocator.free(signatures);
    const bls_signature = try readBlob(allocator, bytes, &off);
    errdefer allocator.free(bls_signature);
    const bls_signer_bitmap = try readBlob(allocator, bytes, &off);
    if (off != bytes.len) return error.InvalidProof;
    return .{
        .sequence = sequence,
        .object_id = object_id,
        .state_root = state_root,
        .proof_bytes = proof_bytes,
        .signatures = signatures,
        .bls_signature = bls_signature,
        .bls_signer_bitmap = bls_signer_bitmap,
    };
}

pub fn freeProof(allocator: std.mem.Allocator, proof: Proof) void {
    allocator.free(proof.proof_bytes);
    allocator.free(proof.signatures);
    allocator.free(proof.bls_signature);
    allocator.free(proof.bls_signer_bitmap);
}

pub fn verify(allocator: std.mem.Allocator, genesis_bytes: []const u8, proof_bytes: []const u8) !bool {
    const doc = try Genesis.decode(allocator, genesis_bytes);
    defer allocator.free(doc.validators);
    const proof = try decode(allocator, proof_bytes);
    defer freeProof(allocator, proof);

    const validators = try allocator.alloc(Validator, doc.validators.len);
    defer allocator.free(validators);
    var built: usize = 0;
    errdefer {
        for (validators[0..built]) |*v| v.deinit(allocator);
    }
    for (doc.validators, 0..) |gv, i| {
        validators[i] = try Validator.create(gv.public_key, gv.stake, "", allocator);
        built += 1;
    }
    defer for (validators[0..built]) |*v| v.deinit(allocator);

    const view = MainnetExtensionHooks.CheckpointProof{
        .sequence = proof.sequence,
        .object_id = proof.object_id,
        .state_root = proof.state_root,
        .proof_bytes = proof.proof_bytes,
        .signatures = proof.signatures,
        .bls_signature = proof.bls_signature,
        .bls_signer_bitmap = proof.bls_signer_bitmap,
    };
    return LightClient.verifyCheckpointProofQuorum(allocator, view, validators);
}

fn writeBlob(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, blob: []const u8) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(blob.len), .big);
    try buf.appendSlice(allocator, &b);
    try buf.appendSlice(allocator, blob);
}

fn readBlob(allocator: std.mem.Allocator, bytes: []const u8, off: *usize) ![]u8 {
    if (off.* + 4 > bytes.len) return error.InvalidProof;
    const len = std.mem.readInt(u32, bytes[off.*..][0..4], .big);
    off.* += 4;
    if (off.* + len > bytes.len) return error.InvalidProof;
    const out = try allocator.dupe(u8, bytes[off.*..][0..len]);
    off.* += len;
    return out;
}

test "offline proof accepts a genesis validator signature and rejects a flip" {
    const allocator = std.testing.allocator;
    const seed: [32]u8 = @splat(0x11);
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    var validators = [_]Genesis.Validator{
        .{ .public_key = kp.public_key.toBytes(), .stake = 1_000_000_000 },
    };
    const genesis = try Genesis.encode(allocator, Genesis.sampleMainnet(&validators));
    defer allocator.free(genesis);

    const object_id: [32]u8 = @splat(0x22);
    const state_root: [32]u8 = @splat(0x33);
    const msg = MainnetExtensionHooks.m4ProofSigningMessage(state_root, 4, object_id);
    var vid: [32]u8 = undefined;
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(&kp.public_key.toBytes());
    h.final(&vid);
    const sig = try @import("../property/crypto/Signature.zig").Ed25519.sign(seed, &msg);
    const pairs = [_]MainnetExtensionHooks.ProofSigPair{.{ .validator_id = vid, .signature = sig }};
    const signatures = try MainnetExtensionHooks.encodeProofSignatureList(allocator, &pairs);
    defer allocator.free(signatures);
    const proof_bytes = try allocator.dupe(u8, &msg);
    defer allocator.free(proof_bytes);
    const empty = try allocator.alloc(u8, 0);
    defer allocator.free(empty);
    const blob = try encode(allocator, .{
        .sequence = 4,
        .object_id = object_id,
        .state_root = state_root,
        .proof_bytes = proof_bytes,
        .signatures = signatures,
        .bls_signature = empty,
        .bls_signer_bitmap = empty,
    });
    defer allocator.free(blob);
    try std.testing.expect(try verify(allocator, genesis, blob));

    var flipped = try allocator.dupe(u8, blob);
    defer allocator.free(flipped);
    flipped[magic.len + 8 + 32] ^= 0x01;
    try std.testing.expect(!try verify(allocator, genesis, flipped));
}
