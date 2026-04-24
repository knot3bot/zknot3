//! M4 multi-signer checkpoint proofs: Node.buildCheckpointProof + LightClient.verifyCheckpointProofQuorum.
const std = @import("std");
const root = @import("../../src/root.zig");

const Config = root.app.Config;
const Node = root.app.Node;
const NodeDependencies = root.app.NodeDependencies;
const LightClient = root.app.LightClient;
const Validator = root.form.consensus.Validator;

const io_mod = @import("io_instance");

fn allocDataDir(allocator: std.mem.Allocator) ![]const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const salt: u64 = @as(u64, @intCast(ts.sec)) ^ (@as(u64, @intCast(ts.nsec)) << 1);
    return try std.fmt.allocPrint(allocator, "test_tmp/m4_mv_{x}", .{salt});
}

fn cleanupDataDir(data_dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io_mod.io, data_dir) catch {};
}

test "M4 Node buildCheckpointProof with extra seeds passes 2-of-3 LightClient quorum" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const s1 = [_]u8{0x61} ** 32;
    const s2 = [_]u8{0x62} ** 32;
    const s3 = [_]u8{0x63} ** 32;
    const b1 = [_]u8{0x71} ** 32;
    const b2 = [_]u8{0x72} ** 32;

    var v1 = try Validator.create((try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s1)).public_key.toBytes(), 401, "a", allocator);
    defer v1.deinit(allocator);
    v1.stake.bls_public_key = root.core.Bls.derivePublicKey(b1);
    var v2 = try Validator.create((try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s2)).public_key.toBytes(), 400, "b", allocator);
    defer v2.deinit(allocator);
    v2.stake.bls_public_key = root.core.Bls.derivePublicKey(b2);
    var v3 = try Validator.create((try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s3)).public_key.toBytes(), 400, "c", allocator);
    defer v3.deinit(allocator);

    const cfg = try allocator.create(Config);
    cfg.* = Config.default();
    cfg.authority.signing_key = s1;
    cfg.authority.checkpoint_proof_extra_signing_seeds = &.{s2};
    cfg.authority.bls_signing_seed = b1;
    cfg.authority.extra_bls_signing_seeds = &.{b2};
    cfg.authority.stake = 1_000_000_000;
    cfg.storage.data_dir = data_dir;

    const node = try Node.init(allocator, cfg, NodeDependencies{});
    defer node.deinit();
    defer allocator.destroy(cfg);

    const proof = try node.buildCheckpointProof(.{ .sequence = 3, .object_id = [_]u8{0xaa} ** 32 });
    defer node.freeCheckpointProof(proof);
    try std.testing.expect(proof.bls_signature.len > 0);
    try std.testing.expect(proof.bls_signer_bitmap.len > 0);

    const vals = [_]Validator{ v1, v2, v3 };
    try std.testing.expect(try LightClient.verifyCheckpointProofQuorum(allocator, proof, &vals));
}
