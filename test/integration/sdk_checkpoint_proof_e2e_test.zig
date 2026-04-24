const std = @import("std");
const core = @import("../../src/core.zig");
const sdk = @import("../../src/sdk.zig");

test "e2e: getCheckpointProof verifies under docker devnet" {
    const allocator = std.testing.allocator;

    const rpc = sdk.rpc.RpcClient.init(allocator, "http://127.0.0.1:9003/rpc");

    const object_id_hex = "0000000000000000000000000000000000000000000000000000000000000000";
    const params_json = try std.fmt.allocPrint(allocator, "{{\"sequence\":1,\"objectId\":\"{s}\"}}", .{object_id_hex});
    defer allocator.free(params_json);

    const proof = try rpc.call(sdk.types.CheckpointProof, "knot3_getCheckpointProof", params_json);

    const state_root_dec = try sdk.types.decodeHexAlloc(allocator, proof.stateRoot);
    defer state_root_dec.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 32), state_root_dec.bytes.len);
    var state_root: [32]u8 = undefined;
    @memcpy(&state_root, state_root_dec.bytes);

    const object_id_dec = try sdk.types.decodeHexAlloc(allocator, object_id_hex);
    defer object_id_dec.deinit(allocator);
    var object_id: [32]u8 = undefined;
    @memcpy(&object_id, object_id_dec.bytes);

    const expected = sdk.proof.buildProofBytes(state_root, proof.sequence, object_id);

    const validators = [_]sdk.types.ValidatorInfo{
        .{ .voting_power = 1_000_000_000_000, .bls_public_key = core.Bls.derivePublicKey(tryMaterial(101)) },
        .{ .voting_power = 1_000_000_000_000, .bls_public_key = core.Bls.derivePublicKey(tryMaterial(102)) },
        .{ .voting_power = 1_000_000_000_000, .bls_public_key = core.Bls.derivePublicKey(tryMaterial(103)) },
        .{ .voting_power = 1_000_000_000_000, .bls_public_key = core.Bls.derivePublicKey(tryMaterial(104)) },
    };

    _ = try sdk.proof.verifyCheckpointProof(allocator, proof, expected, &validators, .{});
}

fn tryMaterial(comptime b: u8) [32]u8 {
    const seed: [32]u8 = .{b} ** 32;
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch @panic("bad seed");
    return kp.public_key.toBytes();
}

