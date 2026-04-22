const std = @import("std");
const M4RpcParams = @import("../../src/form/network/M4RpcParams.zig");

/// 32 zero bytes as 64 hex chars.
const hex64_zeros = "0000000000000000000000000000000000000000000000000000000000000000";

fn parseJsonValue(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "M4 parseStakeOperationInput accepts valid object" {
    const allocator = std.testing.allocator;
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"validator\":\"{s}\",\"delegator\":\"{s}\",\"amount\":42,\"action\":\"stake\",\"metadata\":\"m\"}}",
        .{ hex64_zeros, hex64_zeros },
    );
    defer allocator.free(json);
    var parsed = try parseJsonValue(allocator, json);
    defer parsed.deinit();

    const input = try M4RpcParams.parseStakeOperationInput(parsed.value);
    try std.testing.expectEqual(@as(u64, 42), input.amount);
    try std.testing.expect(input.action == .stake);
}

test "M4 parseStakeOperationInput rejects zero amount" {
    const allocator = std.testing.allocator;
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"validator\":\"{s}\",\"delegator\":\"{s}\",\"amount\":0,\"action\":\"stake\"}}",
        .{ hex64_zeros, hex64_zeros },
    );
    defer allocator.free(json);
    var parsed = try parseJsonValue(allocator, json);
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidAmount, M4RpcParams.parseStakeOperationInput(parsed.value));
}

test "M4 parseCheckpointProofRequest requires objectId camelCase" {
    const allocator = std.testing.allocator;
    const hex_ab = "abababababababababababababababababababababababababababababababab";
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"sequence\":7,\"objectId\":\"{s}\"}}",
        .{hex_ab},
    );
    defer allocator.free(json);
    var parsed = try parseJsonValue(allocator, json);
    defer parsed.deinit();

    const req = try M4RpcParams.parseCheckpointProofRequest(parsed.value);
    try std.testing.expectEqual(@as(u64, 7), req.sequence);
}

test "M4 parseStakeOperationFromPlainArgs matches JSON semantics" {
    const hex_cd = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
    const plain = [_]M4RpcParams.PlainArg{
        .{ .name = "validator", .value = hex64_zeros },
        .{ .name = "delegator", .value = hex_cd },
        .{ .name = "amount", .value = "9" },
        .{ .name = "action", .value = "unstake" },
        .{ .name = "metadata", .value = "" },
    };
    const input = try M4RpcParams.parseStakeOperationFromPlainArgs(&plain);
    try std.testing.expect(input.action == .unstake);
    try std.testing.expectEqual(@as(u64, 9), input.amount);
}

test "M4 parseGovernanceProposalFromPlainArgs rejects empty title" {
    const plain = [_]M4RpcParams.PlainArg{
        .{ .name = "proposer", .value = hex64_zeros },
        .{ .name = "title", .value = "" },
        .{ .name = "description", .value = "x" },
        .{ .name = "kind", .value = "parameter_change" },
    };
    try std.testing.expectError(error.EmptyString, M4RpcParams.parseGovernanceProposalFromPlainArgs(&plain));
}
