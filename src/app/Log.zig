//! Simple structured logger
const std = @import("std");

pub const Level = enum {
    err,
    warn,
    info,
    debug,
};

/// Global log level filter
pub var global_level: Level = .info;

/// Check if a message at the given level should be emitted
pub fn isEnabled(level: Level) bool {
    return @intFromEnum(level) <= @intFromEnum(global_level);
}

/// Emit a log message. Caller must include [LEVEL] prefix and \n in fmt.
pub fn log(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!isEnabled(level)) return;
    var buf: [1024]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, fmt, args) catch |e| {
        if (e == error.NoSpaceLeft) {
            const allocated = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch {
                std.debug.print("[LOG] format error\n", .{});
                return;
            };
            defer std.heap.page_allocator.free(allocated);
            std.debug.print("{s}\n", .{allocated});
            return;
        }
        std.debug.print("[LOG] bufPrint error: {s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("{s}\n", .{full});
}

/// Shorthand helpers — callers include [LEVEL] prefix in format string
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}
