//! SDK Protocol Compatibility Regression Tests
//!
//! Ensures SDK-side types and serialization remain compatible with node protocol v1.

const std = @import("std");
const SdkTransaction = @import("../../src/sdk/types.zig").SdkTransaction;
const NodeTransaction = @import("../../src/pipeline.zig").Transaction;
const RpcClient = @import("../../src/sdk/rpc.zig").RpcClient;

fn makeSdkTx() SdkTransaction {
    return .{
        .sender = [_]u8{0xAB} ** 32,
        .inputs = &.{},
        .program = "transfer",
        .gas_budget = 1000,
        .sequence = 42,
    };
}

fn makeNodeTx(allocator: std.mem.Allocator) !NodeTransaction {
    return .{
        .sender = [_]u8{0xAB} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "transfer"),
        .gas_budget = 1000,
        .sequence = 42,
    };
}

test "sdk-protocol: SdkTransaction digest matches node Transaction digest" {
    const allocator = std.testing.allocator;
    const sdk_tx = makeSdkTx();
    var node_tx = try makeNodeTx(allocator);
    defer node_tx.deinit(allocator);

    const sdk_digest = sdk_tx.digest();
    const node_digest = node_tx.digest();

    try std.testing.expect(std.mem.eql(u8, &sdk_digest, &node_digest));
}

test "sdk-protocol: digest changes with gas_budget and sequence" {
    const tx1 = SdkTransaction{
        .sender = [_]u8{0x01} ** 32,
        .inputs = &.{},
        .program = "noop",
        .gas_budget = 100,
        .sequence = 0,
    };
    var tx2 = tx1;
    tx2.gas_budget = 200;
    var tx3 = tx1;
    tx3.sequence = 1;

    const d1 = tx1.digest();
    const d2 = tx2.digest();
    const d3 = tx3.digest();

    try std.testing.expect(!std.mem.eql(u8, &d1, &d2));
    try std.testing.expect(!std.mem.eql(u8, &d1, &d3));
}

test "sdk-protocol: RpcClient retry exhausts on unreachable endpoint" {
    const allocator = std.testing.allocator;
    var client = RpcClient.init(allocator, "http://127.0.0.1:1/rpc", .{
        .timeout_ms = 50,
        .max_retries = 2,
        .backoff_ms = 10,
    }, std.testing.io);
    const result = client.call([]const u8, "knot3_getEpochs", "[]");
    try std.testing.expectError(error.RetryExhausted, result);
}
