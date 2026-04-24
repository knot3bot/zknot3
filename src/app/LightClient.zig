//! LightClient - Lightweight client for blockchain verification
//!
//! Provides:
//! - Checkpoint verification against trusted state root
//! - Validator set verification
//! - Minimal state sync interface
//!
//! Note: Full sync protocol implementation requires network layer integration.
//! This module provides the verification primitives.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const checkpoint_mod = @import("../form/storage/Checkpoint.zig");
const Checkpoint = checkpoint_mod.Checkpoint;
const Validator = @import("../form/consensus/Validator.zig").Validator;
const MainnetExtensionHooks = @import("MainnetExtensionHooks.zig");
const Sig = @import("../property/crypto/Signature.zig");
const Bls = @import("../core/crypto/Bls.zig");

/// Trusted checkpoint for light client initialization
pub const TrustedCheckpoint = struct {
    checkpoint: Checkpoint,
    validator_set_hash: [32]u8,
    signatures: []const u8,
};

/// Light client state
pub const LightClientState = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    trusted_checkpoint: ?TrustedCheckpoint,
    latest_verified_sequence: u64,
    validator_set_hash: [32]u8,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
                self.* = .{
                        .allocator = allocator,
                        .trusted_checkpoint = null,
                        .latest_verified_sequence = 0,
                        .validator_set_hash = [_]u8{0} ** 32,
                };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Initialize with a trusted checkpoint (bootstrap)
    pub fn initializeWithTrustedCheckpoint(
        self: *Self,
        checkpoint: Checkpoint,
        validator_set_hash: [32]u8,
    ) !void {
        self.trusted_checkpoint = .{
            .checkpoint = checkpoint,
            .validator_set_hash = validator_set_hash,
            .signatures = &[_]u8{},
        };
        self.latest_verified_sequence = checkpoint.sequence;
        self.validator_set_hash = validator_set_hash;
    }

    /// Get the latest verified sequence number
    pub fn latestSequence(self: Self) u64 {
        return self.latest_verified_sequence;
    }

    /// Get current validator set hash
    pub fn currentValidatorSetHash(self: Self) [32]u8 {
        return self.validator_set_hash;
    }
};

/// Verify checkpoint proof against trusted state root
pub fn verifyCheckpointProof(
    checkpoint: *const Checkpoint,
    trusted_state_root: [32]u8,
) bool {
    // Verify state root matches trusted value
    return std.mem.eql(u8, &checkpoint.state_root, &trusted_state_root);
}

/// Verify M4 checkpoint proof: canonical `proof_bytes`, Ed25519 signatures in `k3s1` list,
/// and stake-weighted quorum against `validators` (same 2/3+1 rule as storage checkpoints).
pub fn verifyCheckpointProofQuorum(
    allocator: std.mem.Allocator,
    proof: MainnetExtensionHooks.CheckpointProof,
    validators: []const Validator,
) !bool {
    const expected = MainnetExtensionHooks.m4ProofSigningMessage(proof.state_root, proof.sequence, proof.object_id);
    if (proof.proof_bytes.len != expected.len) return false;
    if (!std.mem.eql(u8, proof.proof_bytes, &expected)) return false;

    const layout = MainnetExtensionHooks.decodeProofSignatureLayout(proof.signatures) orelse return false;
    if (layout.count == 0) return false;

    var total_stake: u64 = 0;
    for (validators) |v| total_stake += v.stake.votingPower();
    if (total_stake == 0) return false;
    const quorum_threshold = (total_stake * 2) / 3 + 1;

    if (proof.bls_signature.len > 0 and proof.bls_signer_bitmap.len > 0) {
        if (proof.bls_signature.len != @sizeOf(Bls.Signature)) return false;
        var selected = std.ArrayList(Bls.PublicKey).empty;
        defer selected.deinit(allocator);
        const bitmap_len = @min(proof.bls_signer_bitmap.len, validators.len);
        var bls_power: u64 = 0;
        var i: usize = 0;
        while (i < bitmap_len) : (i += 1) {
            if (proof.bls_signer_bitmap[i] != 0) {
                const pk = validators[i].stake.bls_public_key orelse Bls.derivePublicKey(validators[i].stake.public_key);
                try selected.append(allocator, pk);
                bls_power += validators[i].stake.votingPower();
            }
        }
        if (selected.items.len == 0) return false;
        if (bls_power < quorum_threshold) return false;
        const agg_pk = Bls.aggregatePk(selected.items);
        const agg_sig: Bls.Signature = proof.bls_signature[0..@sizeOf(Bls.Signature)].*;
        if (!Bls.verifyAggregated(proof.proof_bytes, agg_pk, agg_sig)) return false;
    }

    var counted = std.AutoArrayHashMapUnmanaged([32]u8, void).empty;
    defer counted.deinit(allocator);

    var stake_sum: u64 = 0;
    var off: usize = 8;
    var idx: u32 = 0;
    while (idx < layout.count) : (idx += 1) {
        const vid = proof.signatures[off..][0..32].*;
        off += 32;
        const sigb = proof.signatures[off..][0..64].*;
        off += 64;

        if (counted.contains(vid)) continue;

        var found_pk: ?[32]u8 = null;
        var power: u64 = 0;
        for (validators) |v| {
            if (std.mem.eql(u8, &v.id, &vid)) {
                found_pk = v.stake.public_key;
                power = v.stake.votingPower();
                break;
            }
        }
        const pk = found_pk orelse continue;
        if (!Sig.Ed25519.verify(pk, proof.proof_bytes, sigb)) continue;

        try counted.put(allocator, vid, {});
        stake_sum += power;
    }

    return stake_sum >= quorum_threshold;
}

/// Compute validator set hash from validator list
pub fn computeValidatorSetHash(validators: []const Validator) [32]u8 {
    var ctx = Blake3.init(.{});

    for (validators) |v| {
        ctx.update(&v.id);
        var stake_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &stake_bytes, v.stake.votingPower(), .big);
        ctx.update(&stake_bytes);
    }

    var hash: [32]u8 = undefined;
    ctx.final(&hash);
    return hash;
}

/// Verifies a minimal publishable subset for an epoch handoff claim (not a full light-client protocol).
///
/// Checks:
/// - `next_validator_set_hash` is not all-zero.
/// - `checkpoint.state_root` matches recomputation from `checkpoint.object_changes`.
/// - `next_validator_set_hash` equals `computeValidatorSetHash(next_validators)`.
/// - If `checkpoints_per_epoch > 0`, `checkpoint.sequence` lies on that boundary (`sequence % checkpoints_per_epoch == 0`).
///
/// Does **not** verify checkpoint validator signatures or a complete cross-epoch proof chain.
pub fn verifyEpochProof(
    allocator: std.mem.Allocator,
    checkpoint: *const Checkpoint,
    next_validator_set_hash: [32]u8,
    next_validators: []const Validator,
    checkpoints_per_epoch: u64,
) !bool {
    var all_zero = true;
    for (next_validator_set_hash) |b| {
        if (b != 0) all_zero = false;
    }
    if (all_zero) return false;

    const computed_root = try checkpoint_mod.verifyStateRoot(checkpoint.object_changes, allocator);
    if (!std.mem.eql(u8, &checkpoint.state_root, &computed_root)) return false;

    const expected_next = computeValidatorSetHash(next_validators);
    if (!std.mem.eql(u8, &next_validator_set_hash, &expected_next)) return false;

    if (checkpoints_per_epoch > 0 and checkpoint.sequence % checkpoints_per_epoch != 0) {
        return false;
    }

    return true;
}

/// Light client sync progress
pub const SyncProgress = struct {
    current_epoch: u64,
    current_sequence: u64,
    target_sequence: u64,
    verified_count: u64,
};

test "LightClientState init" {
    const allocator = std.testing.allocator;
    var state = try LightClientState.init(allocator);
    defer state.deinit();

    try std.testing.expect(state.latestSequence() == 0);
}

test "Checkpoint verification" {
    const allocator = std.testing.allocator;
    const changes = [_]Checkpoint.ObjectChange{};
    var cp = try Checkpoint.create(3, [_]u8{1} ** 32, &changes, allocator);
    defer cp.deinit(allocator);

    try std.testing.expect(verifyCheckpointProof(&cp, cp.state_root));
    try std.testing.expect(!verifyCheckpointProof(&cp, [_]u8{8} ** 32));
}

test "verifyCheckpointProofQuorum accepts signed M4 proof" {
    const allocator = std.testing.allocator;
    var mgr = try MainnetExtensionHooks.Manager.init(allocator);
    defer mgr.deinit();

    const state_root = try mgr.computeStateRoot();
    const msg = MainnetExtensionHooks.m4ProofSigningMessage(state_root, 12, [_]u8{0x11} ** 32);
    const proof_bytes = try allocator.dupe(u8, &msg);
    errdefer allocator.free(proof_bytes);

    const seed = [_]u8{0x55} ** 32;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const pk = kp.public_key.toBytes();
    var vid: [32]u8 = undefined;
    {
        var h = Blake3.init(.{});
        h.update(&pk);
        h.final(&vid);
    }
    const sig = try Sig.Ed25519.sign(seed, proof_bytes);
    const signatures = try MainnetExtensionHooks.encodeProofSignatureList(allocator, &[_]MainnetExtensionHooks.ProofSigPair{.{
        .validator_id = vid,
        .signature = sig,
    }});
    errdefer allocator.free(signatures);

    const proof = MainnetExtensionHooks.CheckpointProof{
        .sequence = 12,
        .object_id = [_]u8{0x11} ** 32,
        .state_root = state_root,
        .proof_bytes = proof_bytes,
        .signatures = signatures,
        .bls_signature = &.{},
        .bls_signer_bitmap = &.{},
    };
    defer allocator.free(proof.signatures);
    defer allocator.free(proof.proof_bytes);

    var val = try Validator.create(pk, 1_000_000_000, "v", allocator);
    defer val.deinit(allocator);

    try std.testing.expect(try verifyCheckpointProofQuorum(allocator, proof, &[_]Validator{val}));
}

test "verifyCheckpointProofQuorum rejects BLS bitmap below quorum" {
    const allocator = std.testing.allocator;
    var mgr = try MainnetExtensionHooks.Manager.init(allocator);
    defer mgr.deinit();

    const s1 = [_]u8{0x71} ** 32;
    const s2 = [_]u8{0x72} ** 32;
    const s3 = [_]u8{0x73} ** 32;
    const kp1 = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s1);
    const kp2 = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s2);
    const kp3 = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s3);

    var v1 = try Validator.create(kp1.public_key.toBytes(), 400, "a", allocator);
    defer v1.deinit(allocator);
    var v2 = try Validator.create(kp2.public_key.toBytes(), 400, "b", allocator);
    defer v2.deinit(allocator);
    var v3 = try Validator.create(kp3.public_key.toBytes(), 400, "c", allocator);
    defer v3.deinit(allocator);

    const state_root = try mgr.computeStateRoot();
    const msg = MainnetExtensionHooks.m4ProofSigningMessage(state_root, 23, [_]u8{0x19} ** 32);
    const proof_bytes = try allocator.dupe(u8, &msg);
    errdefer allocator.free(proof_bytes);

    var vid1: [32]u8 = undefined;
    {
        const pk1_bytes = kp1.public_key.toBytes();
        var h = Blake3.init(.{});
        h.update(&pk1_bytes);
        h.final(&vid1);
    }
    const sig1 = try Sig.Ed25519.sign(s1, proof_bytes);
    const signatures = try MainnetExtensionHooks.encodeProofSignatureList(allocator, &[_]MainnetExtensionHooks.ProofSigPair{.{
        .validator_id = vid1,
        .signature = sig1,
    }});
    errdefer allocator.free(signatures);

    const bls_msg_seed1 = kp1.public_key.toBytes();
    const bls_msg_seed2 = kp2.public_key.toBytes();
    const bls_sig = Bls.aggregateSig(&[_]Bls.Signature{
        Bls.sign(bls_msg_seed1, proof_bytes),
        Bls.sign(bls_msg_seed2, proof_bytes),
    });
    const bls_signature = try allocator.dupe(u8, &bls_sig);
    errdefer allocator.free(bls_signature);
    const bls_bitmap = try allocator.dupe(u8, &[_]u8{ 1, 0, 0 });
    errdefer allocator.free(bls_bitmap);

    const proof = MainnetExtensionHooks.CheckpointProof{
        .sequence = 23,
        .object_id = [_]u8{0x19} ** 32,
        .state_root = state_root,
        .proof_bytes = proof_bytes,
        .signatures = signatures,
        .bls_signature = bls_signature,
        .bls_signer_bitmap = bls_bitmap,
    };
    defer allocator.free(proof.bls_signer_bitmap);
    defer allocator.free(proof.bls_signature);
    defer allocator.free(proof.signatures);
    defer allocator.free(proof.proof_bytes);

    const vals = [_]Validator{ v1, v2, v3 };
    try std.testing.expect(!try verifyCheckpointProofQuorum(allocator, proof, &vals));
}

test "verifyEpochProof accepts consistent checkpoint, next set hash, and boundary" {
    const allocator = std.testing.allocator;
    const changes = [_]Checkpoint.ObjectChange{};
    var cp = try Checkpoint.create(20, [_]u8{1} ** 32, &changes, allocator);
    defer cp.deinit(allocator);

    var v1 = try Validator.create([_]u8{0x03} ** 32, 100, "a", allocator);
    defer v1.deinit(allocator);
    var v2 = try Validator.create([_]u8{0x04} ** 32, 200, "b", allocator);
    defer v2.deinit(allocator);

    const next = &[_]Validator{ v1, v2 };
    const hash = computeValidatorSetHash(next);

    try std.testing.expect(try verifyEpochProof(allocator, &cp, hash, next, 10));
    try std.testing.expect(try verifyEpochProof(allocator, &cp, hash, next, 0));
}

test "verifyEpochProof rejects wrong hash, zero hash, bad state root, and off-boundary sequence" {
    const allocator = std.testing.allocator;
    const changes = [_]Checkpoint.ObjectChange{};
    var cp = try Checkpoint.create(21, [_]u8{2} ** 32, &changes, allocator);
    defer cp.deinit(allocator);

    var v1 = try Validator.create([_]u8{0x13} ** 32, 50, "x", allocator);
    defer v1.deinit(allocator);
    const next = &[_]Validator{v1};
    const good_hash = computeValidatorSetHash(next);

    try std.testing.expect(!try verifyEpochProof(allocator, &cp, [_]u8{0} ** 32, next, 0));

    var wrong_hash: [32]u8 = good_hash;
    wrong_hash[0] ^= 0xff;
    try std.testing.expect(!try verifyEpochProof(allocator, &cp, wrong_hash, next, 0));

    try std.testing.expect(!try verifyEpochProof(allocator, &cp, good_hash, next, 10));

    var cp_bad = cp;
    cp_bad.state_root = [_]u8{0xee} ** 32;
    try std.testing.expect(!try verifyEpochProof(allocator, &cp_bad, good_hash, next, 0));
}
