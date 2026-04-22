const std = @import("std");
const root = @import("../../src/root.zig");

const Config = root.app.Config;
const Node = root.app.Node;
const NodeDependencies = root.app.NodeDependencies;
const LightClient = @import("../../src/app/LightClient.zig");
const Validator = root.form.consensus.Validator;

test "M4 proof can be verified by light client path" {
    const allocator = std.testing.allocator;

    const config = try allocator.create(Config);
    defer allocator.destroy(config);
    config.* = Config.default();
    const seed = [_]u8{0x3C} ** 32;
    config.authority.signing_key = seed;
    config.authority.stake = 1_000_000_000;

    const node = try Node.init(allocator, config, NodeDependencies{});
    defer node.deinit();

    _ = try node.submitStakeOperation(.{
        .validator = [_]u8{1} ** 32,
        .delegator = [_]u8{2} ** 32,
        .amount = 10,
        .action = .stake,
        .metadata = "bootstrap",
    });

    const proof = try node.buildCheckpointProof(.{
        .sequence = 5,
        .object_id = [_]u8{0xAA} ** 32,
    });
    defer node.freeCheckpointProof(proof);

    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const pk = kp.public_key.toBytes();
    var val = try Validator.create(pk, config.authority.stake, "v", allocator);
    defer val.deinit(allocator);

    try std.testing.expect(try LightClient.verifyCheckpointProofQuorum(allocator, proof, &[_]Validator{val}));
}

test "M4 contract parity includes typed params and shared proof fields" {
    const sdk_source = @embedFile("../../src/app/ClientSDK.zig");
    try std.testing.expect(std.mem.indexOf(u8, sdk_source, "\"validator\", \"delegator\", \"amount\", \"action\", \"metadata\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_source, "\"proposer\", \"title\", \"description\", \"kind\", \"activation_epoch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_source, ".object_params = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_source, "param_json") != null);

    const m4_params = @embedFile("../../src/form/network/M4RpcParams.zig");
    try std.testing.expect(std.mem.indexOf(u8, m4_params, "parseStakeOperationInput") != null);
    try std.testing.expect(std.mem.indexOf(u8, m4_params, "objectId") != null);

    const http_source = @embedFile("../../src/form/network/HTTPServer.zig");
    try std.testing.expect(std.mem.indexOf(u8, http_source, "\"stateRoot\"") != null);

    const async_http_source = @embedFile("../../src/form/network/AsyncHTTPServer.zig");
    try std.testing.expect(std.mem.indexOf(u8, async_http_source, "\"stateRoot\"") != null);

    const gql_source = @embedFile("../../src/app/GraphQL.zig");
    try std.testing.expect(std.mem.indexOf(u8, gql_source, "stateRoot") != null);
    try std.testing.expect(std.mem.indexOf(u8, gql_source, "validator") != null);
    try std.testing.expect(std.mem.indexOf(u8, gql_source, "proposer") != null);
    try std.testing.expect(std.mem.indexOf(u8, gql_source, "M4RpcParams") != null);
}
