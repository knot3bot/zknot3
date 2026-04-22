//! M4 adversarial + recovery path tests (checkpoint quorum wire, RPC params, recover+replay).
const std = @import("std");
const root = @import("../../src/root.zig");

const Config = root.app.Config;
const Node = root.app.Node;
const NodeDependencies = root.app.NodeDependencies;
const LightClient = root.app.LightClient;
const MainnetExtensionHooks = root.app.MainnetExtensionHooks;
const Validator = root.form.consensus.Validator;
const SigCrypto = root.property.crypto.Signature;
const RPC = root.form.network.RPC;
const wal_mod = @import("../../src/form/storage/WAL.zig");

const io_mod = @import("io_instance");

fn allocDataDir(allocator: std.mem.Allocator) ![]const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const salt: u64 = @as(u64, @intCast(ts.sec)) ^ (@as(u64, @intCast(ts.nsec)) << 1);
    return try std.fmt.allocPrint(allocator, "test_tmp/m4_adv_{x}", .{salt});
}

fn cleanupDataDir(data_dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io_mod.io, data_dir) catch {};
}

fn newTestNode(allocator: std.mem.Allocator, data_dir: []const u8) !struct { node: *Node, cfg: *Config } {
    const cfg = try allocator.create(Config);
    cfg.* = Config.default();
    const seed = [_]u8{0x6E} ** 32;
    cfg.authority.signing_key = seed;
    cfg.authority.stake = 1_000_000_000;
    cfg.storage.data_dir = data_dir;
    const node = try Node.init(allocator, cfg, NodeDependencies{});
    return .{ .node = node, .cfg = cfg };
}

test "M4 adversarial: duplicate validator_id entries in proof wire do not inflate quorum stake" {
    const allocator = std.testing.allocator;

    var mgr = try MainnetExtensionHooks.Manager.init(allocator);
    defer mgr.deinit();

    const state_root = try mgr.computeStateRoot();
    const seq: u64 = 11;
    const object_id = [_]u8{0xEE} ** 32;
    const msg = MainnetExtensionHooks.m4ProofSigningMessage(state_root, seq, object_id);

    const s1 = [_]u8{0x11} ** 32;
    const s2 = [_]u8{0x22} ** 32;
    const s3 = [_]u8{0x33} ** 32;

    var v1 = try Validator.create((try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s1)).public_key.toBytes(), 400, "a", allocator);
    defer v1.deinit(allocator);
    var v2 = try Validator.create((try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s2)).public_key.toBytes(), 400, "b", allocator);
    defer v2.deinit(allocator);
    var v3 = try Validator.create((try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s3)).public_key.toBytes(), 400, "c", allocator);
    defer v3.deinit(allocator);

    const sig1 = try SigCrypto.Ed25519.sign(s1, &msg);
    const sig1b = try SigCrypto.Ed25519.sign(s1, &msg);
    const sig2 = try SigCrypto.Ed25519.sign(s2, &msg);

    const proof: MainnetExtensionHooks.CheckpointProof = .{
        .sequence = seq,
        .object_id = object_id,
        .state_root = state_root,
        .proof_bytes = try allocator.dupe(u8, &msg),
        .signatures = try MainnetExtensionHooks.encodeProofSignatureList(allocator, &.{
            .{ .validator_id = v1.id, .signature = sig1 },
            .{ .validator_id = v1.id, .signature = sig1b },
            .{ .validator_id = v2.id, .signature = sig2 },
        }),
        .bls_signature = &.{},
        .bls_signer_bitmap = &.{},
    };
    defer {
        allocator.free(proof.proof_bytes);
        allocator.free(proof.signatures);
    }

    const validators = [_]Validator{ v1, v2, v3 };
    const ok = try LightClient.verifyCheckpointProofQuorum(allocator, proof, &validators);
    try std.testing.expect(!ok);
}

test "M4 adversarial: replayWalExtension rejects malformed equivocation WAL payload" {
    const allocator = std.testing.allocator;
    var mgr = try MainnetExtensionHooks.Manager.init(allocator);
    defer mgr.deinit();

    try std.testing.expectError(error.InvalidWalPayload, mgr.replayWalExtension(wal_mod.WalRecordType.m4_equivocation_evidence, "short"));
    try std.testing.expectError(error.InvalidWalPayload, mgr.replayWalExtension(wal_mod.WalRecordType.m4_equivocation_evidence, "m4e1" ++ [_]u8{0} ** 10));
}

test "M4 recovery: recoverFromDisk then replayMainnetM4Wal restores M4 totals" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const validator = [_]u8{0xC1} ** 32;
    const delegator = [_]u8{0xC2} ** 32;

    {
        const h = try newTestNode(allocator, data_dir);
        defer h.node.deinit();
        defer allocator.destroy(h.cfg);
        const n = h.node;
        try n.start();
        _ = try n.submitStakeOperation(.{
            .validator = validator,
            .delegator = delegator,
            .amount = 88,
            .action = .stake,
            .metadata = "adv",
        });
    }

    const h2 = try newTestNode(allocator, data_dir);
    defer h2.node.deinit();
    defer allocator.destroy(h2.cfg);
    const n2 = h2.node;

    try n2.recoverFromDisk();
    try n2.replayMainnetM4Wal();
    try std.testing.expectEqual(@as(u64, 88), n2.getM4ValidatorStake(validator));
}

test "M4 RPC replay: identical valid submit twice returns accepted twice (no transport dedupe)" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const h = try newTestNode(allocator, data_dir);
    defer h.node.deinit();
    defer allocator.destroy(h.cfg);
    const node = h.node;
    try node.start();

    var rpc = try RPC.RPCServer.init(allocator);
    defer rpc.deinit();
    rpc.setUserData(node);

    const body =
        \\{"jsonrpc":"2.0","id":1,"method":"knot3_submitStakeOperation","params":{"validator":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","delegator":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","amount":1,"action":"stake","metadata":"rpc"}}
    ;

    const r1 = try rpc.handleHTTPRequest(body);
    defer allocator.free(r1);
    const r2 = try rpc.handleHTTPRequest(body);
    defer allocator.free(r2);

    try std.testing.expect(std.mem.indexOf(u8, r1, "accepted") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "accepted") != null);
}

test "M4 RPC replay: invalid submit twice returns -32602 twice" {
    const allocator = std.testing.allocator;
    const data_dir = try allocDataDir(allocator);
    defer allocator.free(data_dir);
    defer cleanupDataDir(data_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.io, data_dir);

    const h = try newTestNode(allocator, data_dir);
    defer h.node.deinit();
    defer allocator.destroy(h.cfg);
    try h.node.start();

    var rpc = try RPC.RPCServer.init(allocator);
    defer rpc.deinit();
    rpc.setUserData(h.node);

    const bad = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"knot3_submitStakeOperation\",\"params\":{}}";
    const r1 = try rpc.handleHTTPRequest(bad);
    defer allocator.free(r1);
    const r2 = try rpc.handleHTTPRequest(bad);
    defer allocator.free(r2);

    try std.testing.expect(std.mem.indexOf(u8, r1, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "-32602") != null);
}
