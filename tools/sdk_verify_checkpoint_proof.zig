const std = @import("std");
const core = @import("../src/core.zig");
const sdk = @import("../src/sdk.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rpc = sdk.rpc.RpcClient.init(allocator, "http://127.0.0.1:9003/rpc");

    const object_id_hex = "0000000000000000000000000000000000000000000000000000000000000000";
    const params_json = try std.fmt.allocPrint(allocator, "{{\"sequence\":1,\"objectId\":\"{s}\"}}", .{object_id_hex});
    defer allocator.free(params_json);

    const proof = try rpc.call(sdk.types.CheckpointProof, "knot3_getCheckpointProof", params_json);

    const state_root_hex = proof.stateRoot;
    const state_root_dec = try sdk.types.decodeHexAlloc(allocator, state_root_hex);
    defer state_root_dec.deinit(allocator);
    if (state_root_dec.bytes.len != 32) return error.BadStateRoot;
    var state_root: [32]u8 = undefined;
    @memcpy(&state_root, state_root_dec.bytes);

    const object_id_dec = try sdk.types.decodeHexAlloc(allocator, object_id_hex);
    defer object_id_dec.deinit(allocator);
    var object_id: [32]u8 = undefined;
    @memcpy(&object_id, object_id_dec.bytes);

    const expected = sdk.proof.buildProofBytes(state_root, proof.sequence, object_id);

    // Build validator list corresponding to docker configs:
    // signing_seed = [1..4]**32
    // bls_seed = [101..104]**32
    var validators = std.ArrayList(sdk.types.ValidatorInfo).empty;
    defer validators.deinit(allocator);

    inline for (.{ 101, 102, 103, 104 }) |b| {
        const seed: [32]u8 = .{@intCast(b)} ** 32;
        const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        const material = kp.public_key.toBytes();
        const pk48 = core.Bls.derivePublicKey(material);
        var pk_hex_buf: [96]u8 = undefined;
        _ = std.fmt.bytesToHex(&pk48, .lower, &pk_hex_buf);
        try validators.append(allocator, .{
            .voting_power = 1_000_000_000_000,
            .bls_public_key_hex = pk_hex_buf[0..],
        });
    }

    const verified = try sdk.proof.verifyCheckpointProof(allocator, proof, expected, validators.items, .{});

    try std.io.getStdOut().writer().print(
        "OK: proof verified. quorum_stake={d} total_stake={d}\n",
        .{ verified.quorum_stake, verified.total_stake },
    );
}

