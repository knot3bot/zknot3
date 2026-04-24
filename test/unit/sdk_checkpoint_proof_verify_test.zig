const std = @import("std");
const sdk = @import("../../src/sdk.zig");

test "sdk proof verify rejects bitmap below quorum" {
    const allocator = std.testing.allocator;

    const proof = sdk.types.CheckpointProof{
        .sequence = 1,
        .stateRoot = "00" ** 32,
        .proof = "00" ** 80,
        .signatures = "",
        .blsSignature = "00" ** 96,
        .blsSignerBitmap = "00" ** 4,
    };

    var state_root: [32]u8 = .{0} ** 32;
    var object_id: [32]u8 = .{0} ** 32;
    const expected = sdk.proof.buildProofBytes(state_root, 1, object_id);

    const validators = [_]sdk.types.ValidatorInfo{
        .{ .voting_power = 10, .bls_public_key = .{0} ** 48 },
        .{ .voting_power = 10, .bls_public_key = .{0} ** 48 },
        .{ .voting_power = 10, .bls_public_key = .{0} ** 48 },
        .{ .voting_power = 10, .bls_public_key = .{0} ** 48 },
    };

    try std.testing.expectError(error.ProtocolInvalidResponse, sdk.proof.verifyCheckpointProof(allocator, proof, expected, &validators, .{}));
}

