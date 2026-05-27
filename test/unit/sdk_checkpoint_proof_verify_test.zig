const std = @import("std");
const sdk = @import("../../src/sdk.zig");

test "sdk proof verify rejects bitmap below quorum" {
    const allocator = std.testing.allocator;

    const proof = sdk.types.CheckpointProof{
        .sequence = 1,
        .stateRoot = "0000000000000000000000000000000000000000000000000000000000000000",
        .proof = "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .signatures = "",
        .blsSignature = "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .blsSignerBitmap = "00000000",
    };

    var state_root: [32]u8 = @as([32]u8, @splat(0));
    var object_id: [32]u8 = @as([32]u8, @splat(0));
    const expected = sdk.proof.buildProofBytes(state_root, 1, object_id);

    const validators = [_]sdk.types.ValidatorInfo{
        .{ .voting_power = 10, .bls_public_key = @as([48]u8, @splat(0)) },
        .{ .voting_power = 10, .bls_public_key = @as([48]u8, @splat(0)) },
        .{ .voting_power = 10, .bls_public_key = @as([48]u8, @splat(0)) },
        .{ .voting_power = 10, .bls_public_key = @as([48]u8, @splat(0)) },
    };

    try std.testing.expectError(error.ProtocolInvalidResponse, sdk.proof.verifyCheckpointProof(allocator, proof, expected, &validators, .{}));
}

