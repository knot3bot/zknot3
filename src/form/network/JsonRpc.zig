//! Shared JSON-RPC encoding. HTTP transports and `RPC.zig` both use this
//! so a string id or error message cannot close the surrounding object.

const std = @import("std");

fn isJsonNumberLiteral(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| switch (c) {
        '0'...'9', '-', '+', '.', 'e', 'E' => {},
        else => return false,
    };
    return true;
}

/// Owned JSON literal for a JSON-RPC `id` (number, string, or null).
pub fn formatJsonRpcId(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    const value = id orelse return allocator.dupe(u8, "null");
    switch (value) {
        .null => return allocator.dupe(u8, "null"),
        .integer => |n| return allocator.print("{d}", .{n}),
        .float => |n| {
            if (!std.math.isFinite(n)) return allocator.dupe(u8, "null");
            return allocator.print("{d}", .{n});
        },
        .number_string => |s| {
            if (!isJsonNumberLiteral(s)) return allocator.dupe(u8, "null");
            return allocator.dupe(u8, s);
        },
        .string => |s| return formatJsonString(allocator, s),
        else => return allocator.dupe(u8, "null"),
    }
}

pub fn formatJsonString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '"');
    for (raw) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var hex: [6]u8 = .{ '\\', 'u', '0', '0', '0', '0' };
                const digits = "0123456789abcdef";
                hex[4] = digits[c >> 4];
                hex[5] = digits[c & 0xf];
                try buf.appendSlice(allocator, &hex);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
    return buf.toOwnedSlice(allocator);
}
