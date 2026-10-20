//! Canonical object-store snapshot for fast sync.
//!
//! A joining peer downloads this blob instead of replaying every object write from
//! genesis, checks the Blake3 digest, then replays only the checkpoints whose
//! `previous_digest` continues from `checkpoint_digest`.

const std = @import("std");

pub const magic = "k3snap01";

pub const SnapshotError = error{
    InvalidSnapshot,
    DigestMismatch,
    DuplicateObject,
};

pub const Header = struct {
    checkpoint_sequence: u64,
    checkpoint_digest: [32]u8,
    object_count: u32,
};

pub const Record = struct {
    key: []const u8,
    value: []const u8,
};

pub const Decoded = struct {
    header: Header,
    records: []Record,
};

pub const ChainLink = struct {
    digest: [32]u8,
    previous_digest: [32]u8,
};

/// `links` must be the checkpoints strictly after the snapshot, in order.
/// Each link's `previous_digest` has to equal the digest that came before it,
/// starting from the snapshot's checkpoint digest.
pub fn verifyContinuation(anchor: [32]u8, links: []const ChainLink) bool {
    var prev = anchor;
    for (links) |link| {
        if (!std.mem.eql(u8, &link.previous_digest, &prev)) return false;
        prev = link.digest;
    }
    return true;
}

pub fn encode(
    allocator: std.mem.Allocator,
    checkpoint_sequence: u64,
    checkpoint_digest: [32]u8,
    records: []const Record,
) ![]u8 {
    if (records.len > std.math.maxInt(u32)) return error.InvalidSnapshot;

    var order = try allocator.alloc(usize, records.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, records, struct {
        fn lessThan(items: []const Record, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, items[a].key, items[b].key);
        }
    }.lessThan);
    for (order[1..], 0..) |idx, prev_i| {
        if (std.mem.eql(u8, records[order[prev_i]].key, records[idx].key)) return error.DuplicateObject;
    }

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    var b8: [8]u8 = undefined;
    std.mem.writeInt(u64, &b8, checkpoint_sequence, .big);
    try payload.appendSlice(allocator, &b8);
    try payload.appendSlice(allocator, &checkpoint_digest);
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u32, &b4, @intCast(records.len), .big);
    try payload.appendSlice(allocator, &b4);
    for (order) |idx| {
        const rec = records[idx];
        if (rec.key.len > std.math.maxInt(u32) or rec.value.len > std.math.maxInt(u32)) return error.InvalidSnapshot;
        std.mem.writeInt(u32, &b4, @intCast(rec.key.len), .big);
        try payload.appendSlice(allocator, &b4);
        try payload.appendSlice(allocator, rec.key);
        std.mem.writeInt(u32, &b4, @intCast(rec.value.len), .big);
        try payload.appendSlice(allocator, &b4);
        try payload.appendSlice(allocator, rec.value);
    }

    var digest: [32]u8 = undefined;
    var ctx = std.crypto.hash.Blake3.init(.{});
    ctx.update(payload.items);
    ctx.final(&digest);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    try out.appendSlice(allocator, &digest);
    try out.appendSlice(allocator, payload.items);
    return out.toOwnedSlice(allocator);
}

pub fn header(bytes: []const u8) SnapshotError!Header {
    const payload = try payloadBytes(bytes);
    if (payload.len < 8 + 32 + 4) return error.InvalidSnapshot;
    return .{
        .checkpoint_sequence = std.mem.readInt(u64, payload[0..8], .big),
        .checkpoint_digest = payload[8..40].*,
        .object_count = std.mem.readInt(u32, payload[40..44], .big),
    };
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    const payload = try payloadBytes(bytes);
    if (payload.len < 44) return error.InvalidSnapshot;
    const hdr = Header{
        .checkpoint_sequence = std.mem.readInt(u64, payload[0..8], .big),
        .checkpoint_digest = payload[8..40].*,
        .object_count = std.mem.readInt(u32, payload[40..44], .big),
    };
    var off: usize = 44;
    const rest = payload.len - off;
    if (@as(usize, hdr.object_count) > rest / 8) return error.InvalidSnapshot;
    const records = try allocator.alloc(Record, hdr.object_count);
    errdefer allocator.free(records);
    var filled: usize = 0;
    errdefer {
        for (records[0..filled]) |rec| {
            allocator.free(rec.key);
            allocator.free(rec.value);
        }
    }
    var previous: ?[]u8 = null;
    while (filled < hdr.object_count) {
        const key_len = try readU32(payload, &off);
        const key_end = std.math.add(usize, off, key_len) catch return error.InvalidSnapshot;
        if (key_end > payload.len) return error.InvalidSnapshot;
        const key = try allocator.dupe(u8, payload[off..][0..key_len]);
        off += key_len;
        errdefer allocator.free(key);
        if (previous) |prev| {
            if (std.mem.order(u8, prev, key) != .lt) return error.DuplicateObject;
        }
        const val_len = try readU32(payload, &off);
        const val_end = std.math.add(usize, off, val_len) catch return error.InvalidSnapshot;
        if (val_end > payload.len) return error.InvalidSnapshot;
        const value = try allocator.dupe(u8, payload[off..][0..val_len]);
        off += val_len;
        records[filled] = .{ .key = key, .value = value };
        previous = key;
        filled += 1;
    }
    if (off != payload.len) return error.InvalidSnapshot;
    return .{ .header = hdr, .records = records };
}

pub fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {
    for (records) |rec| {
        allocator.free(rec.key);
        allocator.free(rec.value);
    }
    allocator.free(records);
}

fn payloadBytes(bytes: []const u8) SnapshotError![]const u8 {
    if (bytes.len < magic.len + 32) return error.InvalidSnapshot;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidSnapshot;
    const digest = bytes[magic.len..][0..32];
    const payload = bytes[magic.len + 32 ..];
    var got: [32]u8 = undefined;
    var ctx = std.crypto.hash.Blake3.init(.{});
    ctx.update(payload);
    ctx.final(&got);
    if (!std.mem.eql(u8, &got, digest)) return error.DigestMismatch;
    return payload;
}

fn readU32(bytes: []const u8, off: *usize) SnapshotError!u32 {
    const end = std.math.add(usize, off.*, 4) catch return error.InvalidSnapshot;
    if (end > bytes.len) return error.InvalidSnapshot;
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .big);
    off.* += 4;
    return v;
}

test "state snapshot roundtrip rejects a flipped digest and checks the chain" {
    const allocator = std.testing.allocator;
    const digest = @as([32]u8, @splat(0xAB));
    const records = [_]Record{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
    };
    const blob = try encode(allocator, 7, digest, &records);
    defer allocator.free(blob);

    const decoded = try decode(allocator, blob);
    defer freeRecords(allocator, decoded.records);
    try std.testing.expectEqual(@as(u64, 7), decoded.header.checkpoint_sequence);
    try std.testing.expectEqual(@as(usize, 2), decoded.records.len);
    try std.testing.expectEqualStrings("a", decoded.records[0].key);
    try std.testing.expectEqualStrings("b", decoded.records[1].key);

    var tampered = try allocator.dupe(u8, blob);
    defer allocator.free(tampered);
    tampered[magic.len] ^= 0x01;
    try std.testing.expectError(error.DigestMismatch, decode(allocator, tampered));

    const next = @as([32]u8, @splat(0xCD));
    try std.testing.expect(verifyContinuation(digest, &.{
        .{ .digest = next, .previous_digest = digest },
    }));
    try std.testing.expect(!verifyContinuation(digest, &.{
        .{ .digest = next, .previous_digest = @as([32]u8, @splat(0x11)) },
    }));
}

test "state snapshot encode rejects more records than its count field can hold" {
    const allocator = std.testing.allocator;
    const records: []const Record = @as([*]const Record, @ptrFromInt(0x1000))[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try std.testing.expectError(error.InvalidSnapshot, encode(allocator, 1, @as([32]u8, @splat(0)), records));
}

test "state snapshot decode rejects a count the body cannot hold" {
    const allocator = std.testing.allocator;
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    var b8: [8]u8 = undefined;
    std.mem.writeInt(u64, &b8, 1, .big);
    try payload.appendSlice(allocator, &b8);
    try payload.appendNTimes(allocator, 0, 32);
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u32, &b4, 1_000_000, .big);
    try payload.appendSlice(allocator, &b4);

    var digest: [32]u8 = undefined;
    var ctx = std.crypto.hash.Blake3.init(.{});
    ctx.update(payload.items);
    ctx.final(&digest);

    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(allocator);
    try blob.appendSlice(allocator, magic);
    try blob.appendSlice(allocator, &digest);
    try blob.appendSlice(allocator, payload.items);

    try std.testing.expectError(error.InvalidSnapshot, decode(allocator, blob.items));
}
