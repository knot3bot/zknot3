//! Canonical chain identity.
//!
//! A genesis file is `k3gen01 || blake3(body) || body`. Peers refuse a
//! handshake when the digests differ. Validator public keys are sorted before
//! hashing so file order does not change the digest.

const std = @import("std");

pub const magic = "k3gen01";

pub const Validator = struct {
    public_key: [32]u8,
    stake: u64,
};

pub const Document = struct {
    chain_id: [32]u8,
    protocol_major: u32,
    protocol_minor: u32,
    protocol_patch: u32,
    epoch_duration_secs: u64,
    min_gas_price: u64,
    epoch_reward: u64,
    validators: []Validator,
};

pub const LoadError = error{
    InvalidGenesis,
    DigestMismatch,
    DuplicateValidator,
    EpochRewardEnabled,
    OutOfMemory,
};

pub fn chainIdFromText(text: []const u8) [32]u8 {
    var out: [32]u8 = @splat(0);
    const n = @min(text.len, out.len);
    @memcpy(out[0..n], text[0..n]);
    return out;
}

/// Mainnet sample: four equal stakes, no epoch mint, protocol 0.1.0.
pub fn sampleMainnetValidators() [4]Validator {
    var out: [4]Validator = undefined;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        var pk: [32]u8 = @splat(@intCast(i + 1));
        pk[0] = @intCast(0xA0 + i);
        out[i] = .{ .public_key = pk, .stake = 1_000_000_000 };
    }
    return out;
}

pub fn sampleMainnet(validators: []Validator) Document {
    return .{
        .chain_id = chainIdFromText("zknot3-mainnet-0"),
        .protocol_major = 0,
        .protocol_minor = 1,
        .protocol_patch = 0,
        .epoch_duration_secs = 86400,
        .min_gas_price = 1000,
        .epoch_reward = 0,
        .validators = validators,
    };
}

pub fn encode(allocator: std.mem.Allocator, doc: Document) LoadError![]u8 {
    const body = try canonical(allocator, doc);
    defer allocator.free(body);
    const dig = hash(body);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    try out.appendSlice(allocator, &dig);
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) LoadError!Document {
    const body = try bodyBytes(bytes);
    var off: usize = 0;
    if (body.len < 32 + 12 + 24 + 4) return error.InvalidGenesis;
    const chain_id = body[0..32].*;
    off = 32;
    const protocol_major = readU32(body, &off);
    const protocol_minor = readU32(body, &off);
    const protocol_patch = readU32(body, &off);
    const epoch_duration_secs = readU64(body, &off);
    const min_gas_price = readU64(body, &off);
    const epoch_reward = readU64(body, &off);
    const count = readU32(body, &off);
    const validators = try allocator.alloc(Validator, count);
    errdefer allocator.free(validators);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (off + 32 + 8 > body.len) return error.InvalidGenesis;
        const public_key = body[off..][0..32].*;
        off += 32;
        const stake = readU64(body, &off);
        if (i > 0 and std.mem.order(u8, &validators[i - 1].public_key, &public_key) != .lt) {
            return error.DuplicateValidator;
        }
        validators[i] = .{ .public_key = public_key, .stake = stake };
    }
    if (off != body.len) return error.InvalidGenesis;
    return .{
        .chain_id = chain_id,
        .protocol_major = protocol_major,
        .protocol_minor = protocol_minor,
        .protocol_patch = protocol_patch,
        .epoch_duration_secs = epoch_duration_secs,
        .min_gas_price = min_gas_price,
        .epoch_reward = epoch_reward,
        .validators = validators,
    };
}

/// Load a genesis file. An empty path yields the all-zero digest used by tests
/// that have not pinned a chain. A non-dev node rejects epoch minting.
pub fn load(allocator: std.mem.Allocator, path: []const u8, allow_epoch_reward: bool) LoadError!struct { digest: [32]u8, epoch_reward: u64 } {
    if (path.len == 0) return .{ .digest = @splat(0), .epoch_reward = 0 };
    const bytes = std.Io.Dir.cwd().readFileAlloc(@import("io_instance").io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch return error.InvalidGenesis;
    defer allocator.free(bytes);
    const doc = try decode(allocator, bytes);
    defer allocator.free(doc.validators);
    if (!allow_epoch_reward and doc.epoch_reward != 0) return error.EpochRewardEnabled;
    return .{ .digest = bytes[magic.len..][0..32].*, .epoch_reward = doc.epoch_reward };
}

fn canonical(allocator: std.mem.Allocator, doc: Document) LoadError![]u8 {
    var order = try allocator.alloc(usize, doc.validators.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, doc.validators, struct {
        fn lessThan(items: []const Validator, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, &items[a].public_key, &items[b].public_key);
        }
    }.lessThan);
    for (order[1..], 0..) |idx, prev_i| {
        if (std.mem.eql(u8, &doc.validators[order[prev_i]].public_key, &doc.validators[idx].public_key)) {
            return error.DuplicateValidator;
        }
    }

    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, &doc.chain_id);
    try writeU32(&body, allocator, doc.protocol_major);
    try writeU32(&body, allocator, doc.protocol_minor);
    try writeU32(&body, allocator, doc.protocol_patch);
    try writeU64(&body, allocator, doc.epoch_duration_secs);
    try writeU64(&body, allocator, doc.min_gas_price);
    try writeU64(&body, allocator, doc.epoch_reward);
    try writeU32(&body, allocator, @intCast(doc.validators.len));
    for (order) |idx| {
        const v = doc.validators[idx];
        try body.appendSlice(allocator, &v.public_key);
        try writeU64(&body, allocator, v.stake);
    }
    return body.toOwnedSlice(allocator);
}

fn hash(body: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    var ctx = std.crypto.hash.Blake3.init(.{});
    ctx.update(body);
    ctx.final(&out);
    return out;
}

fn bodyBytes(bytes: []const u8) LoadError![]const u8 {
    if (bytes.len < magic.len + 32) return error.InvalidGenesis;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidGenesis;
    const dig = bytes[magic.len..][0..32];
    const body = bytes[magic.len + 32 ..];
    const got = hash(body);
    if (!std.mem.eql(u8, &got, dig)) return error.DigestMismatch;
    return body;
}

fn writeU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try buf.appendSlice(allocator, &b);
}

fn writeU64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .big);
    try buf.appendSlice(allocator, &b);
}

fn readU32(bytes: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .big);
    off.* += 4;
    return v;
}

fn readU64(bytes: []const u8, off: *usize) u64 {
    const v = std.mem.readInt(u64, bytes[off.*..][0..8], .big);
    off.* += 8;
    return v;
}

/// 64 hex characters, optional surrounding whitespace. The bytes are a seed,
/// never logged by the caller.
pub fn parseHex32(text: []const u8) error{InvalidSigningKey}![32]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != 64) return error.InvalidSigningKey;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, trimmed) catch return error.InvalidSigningKey;
    return out;
}

pub fn digestAccepted(local: [32]u8, remote: [32]u8) bool {
    return std.mem.eql(u8, &local, &remote);
}

test "genesis digest is order-independent and rejects a flipped byte" {
    const allocator = std.testing.allocator;
    var vals = sampleMainnetValidators();
    const forward = try encode(allocator, sampleMainnet(&vals));
    defer allocator.free(forward);
    std.mem.reverse(Validator, &vals);
    const backward = try encode(allocator, sampleMainnet(&vals));
    defer allocator.free(backward);
    try std.testing.expectEqualSlices(u8, forward, backward);

    const doc = try decode(allocator, forward);
    defer allocator.free(doc.validators);
    try std.testing.expectEqual(@as(u64, 0), doc.epoch_reward);
    try std.testing.expectEqual(@as(usize, 4), doc.validators.len);

    var tampered = try allocator.dupe(u8, forward);
    defer allocator.free(tampered);
    tampered[magic.len] ^= 0x01;
    try std.testing.expectError(error.DigestMismatch, decode(allocator, tampered));
    try std.testing.expect(!digestAccepted(forward[magic.len..][0..32].*, @as([32]u8, @splat(1))));
}
