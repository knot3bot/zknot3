//! Strict parsing for M4 JSON-RPC / HTTP JSON bodies (object params only).
//! Shared by `RPC.zig`, `HTTPServer.zig`, and `AsyncHTTPServer.zig`.

const std = @import("std");
const MainnetExtensionHooks = @import("../../app/MainnetExtensionHooks.zig");

pub const PlainArg = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParseError = error{
    MissingParams,
    NotObject,
    MissingField,
    InvalidHex,
    InvalidAmount,
    InvalidAction,
    InvalidKind,
    EmptyString,
    InvalidSequence,
};

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// 32-byte address: 64 hex chars, optional `0x` prefix.
pub fn parseHex32Str(hex_in: []const u8) ParseError![32]u8 {
    var hex = hex_in;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len != 64) return error.InvalidHex;
    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = hexNibble(hex[i * 2]) orelse return error.InvalidHex;
        const lo = hexNibble(hex[i * 2 + 1]) orelse return error.InvalidHex;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn expectStringField(o: std.json.ObjectMap, name: []const u8) ParseError![]const u8 {
    const v = o.get(name) orelse return error.MissingField;
    return switch (v) {
        .string => |s| s,
        else => error.NotObject,
    };
}

fn parseStakeActionStrict(raw: []const u8) ParseError!MainnetExtensionHooks.StakeAction {
    if (std.mem.eql(u8, raw, "stake")) return .stake;
    if (std.mem.eql(u8, raw, "unstake")) return .unstake;
    if (std.mem.eql(u8, raw, "reward")) return .reward;
    if (std.mem.eql(u8, raw, "slash")) return .slash;
    return error.InvalidAction;
}

fn parseGovernanceKindStrict(raw: []const u8) ParseError!MainnetExtensionHooks.GovernanceKind {
    if (std.mem.eql(u8, raw, "parameter_change")) return .parameter_change;
    if (std.mem.eql(u8, raw, "chain_upgrade")) return .chain_upgrade;
    if (std.mem.eql(u8, raw, "treasury_action")) return .treasury_action;
    return error.InvalidKind;
}

pub fn parseStakeOperationInput(params: ?std.json.Value) ParseError!MainnetExtensionHooks.StakeOperationInput {
    const root = params orelse return error.MissingParams;
    const o = switch (root) {
        .object => |obj| obj,
        else => return error.NotObject,
    };
    const val = try parseHex32Str(try expectStringField(o, "validator"));
    const del = try parseHex32Str(try expectStringField(o, "delegator"));
    const amt_v = o.get("amount") orelse return error.MissingField;
    const amount: u64 = switch (amt_v) {
        .integer => |n| blk: {
            if (n <= 0) return error.InvalidAmount;
            break :blk @as(u64, @intCast(n));
        },
        else => return error.NotObject,
    };
    if (amount == 0) return error.InvalidAmount;
    const action = try parseStakeActionStrict(try expectStringField(o, "action"));
    var metadata: []const u8 = &.{};
    if (o.get("metadata")) |mv| {
        metadata = switch (mv) {
            .string => |s| s,
            else => return error.NotObject,
        };
    }
    return .{
        .validator = val,
        .delegator = del,
        .amount = amount,
        .action = action,
        .metadata = metadata,
    };
}

pub fn parseGovernanceProposalInput(params: ?std.json.Value) ParseError!MainnetExtensionHooks.GovernanceProposalInput {
    const root = params orelse return error.MissingParams;
    const o = switch (root) {
        .object => |obj| obj,
        else => return error.NotObject,
    };
    const proposer = try parseHex32Str(try expectStringField(o, "proposer"));
    const title = try expectStringField(o, "title");
    const description = try expectStringField(o, "description");
    if (title.len == 0 or description.len == 0) return error.EmptyString;
    const kind = try parseGovernanceKindStrict(try expectStringField(o, "kind"));
    var activation_epoch: ?u64 = null;
    if (o.get("activation_epoch")) |v| {
        activation_epoch = switch (v) {
            .null => null,
            .integer => |n| blk: {
                if (n < 0) return error.InvalidAmount;
                break :blk @as(u64, @intCast(n));
            },
            else => return error.NotObject,
        };
    }
    return .{
        .proposer = proposer,
        .title = title,
        .description = description,
        .kind = kind,
        .activation_epoch = activation_epoch,
    };
}

pub fn parseCheckpointProofRequest(params: ?std.json.Value) ParseError!MainnetExtensionHooks.CheckpointProofRequest {
    const root = params orelse return error.MissingParams;
    const o = switch (root) {
        .object => |obj| obj,
        else => return error.NotObject,
    };
    const seq_v = o.get("sequence") orelse return error.MissingField;
    const sequence: u64 = switch (seq_v) {
        .integer => |n| blk: {
            if (n < 0) return error.InvalidSequence;
            break :blk @as(u64, @intCast(n));
        },
        else => return error.InvalidSequence,
    };
    const object_id = try parseHex32Str(try expectStringField(o, "objectId"));
    return .{ .sequence = sequence, .object_id = object_id };
}

fn findPlain(args: []const PlainArg, name: []const u8) ?[]const u8 {
    for (args) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.value;
    }
    return null;
}

/// GraphQL `ArgValue` has the same layout as `PlainArg`.
pub fn parseStakeOperationFromPlainArgs(args: []const PlainArg) ParseError!MainnetExtensionHooks.StakeOperationInput {
    const val = try parseHex32Str(findPlain(args, "validator") orelse return error.MissingField);
    const del = try parseHex32Str(findPlain(args, "delegator") orelse return error.MissingField);
    const amt_s = findPlain(args, "amount") orelse return error.MissingField;
    const amount = std.fmt.parseInt(u64, amt_s, 10) catch return error.InvalidAmount;
    if (amount == 0) return error.InvalidAmount;
    const action = try parseStakeActionStrict(findPlain(args, "action") orelse return error.MissingField);
    const metadata = findPlain(args, "metadata") orelse "";
    return .{
        .validator = val,
        .delegator = del,
        .amount = amount,
        .action = action,
        .metadata = metadata,
    };
}

pub fn parseGovernanceProposalFromPlainArgs(args: []const PlainArg) ParseError!MainnetExtensionHooks.GovernanceProposalInput {
    const proposer = try parseHex32Str(findPlain(args, "proposer") orelse return error.MissingField);
    const title = findPlain(args, "title") orelse return error.MissingField;
    const description = findPlain(args, "description") orelse return error.MissingField;
    if (title.len == 0 or description.len == 0) return error.EmptyString;
    const kind = try parseGovernanceKindStrict(findPlain(args, "kind") orelse return error.MissingField);
    var activation_epoch: ?u64 = null;
    if (findPlain(args, "activationEpoch")) |ae| {
        activation_epoch = std.fmt.parseInt(u64, ae, 10) catch return error.InvalidSequence;
    }
    return .{
        .proposer = proposer,
        .title = title,
        .description = description,
        .kind = kind,
        .activation_epoch = activation_epoch,
    };
}

pub fn parseCheckpointProofFromPlainArgs(args: []const PlainArg) ParseError!MainnetExtensionHooks.CheckpointProofRequest {
    const seq_s = findPlain(args, "sequence") orelse return error.MissingField;
    const sequence = std.fmt.parseInt(u64, seq_s, 10) catch return error.InvalidSequence;
    const object_id = try parseHex32Str(findPlain(args, "objectId") orelse return error.MissingField);
    return .{ .sequence = sequence, .object_id = object_id };
}
