//! Test framework for zknot3
//!
//! Provides utilities for testing the tri-source metrics framework.

const std = @import("std");

/// Test context
pub const TestContext = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{ .allocator = allocator };
    }
};

/// Assert helpers
pub fn assertTrue(condition: bool, msg: []const u8) !void {
    if (!condition) return error.AssertionFailed;
    _ = msg;
}

pub fn assertEqual(comptime T: type, expected: T, actual: T) !void {
    if (expected != actual) return error.AssertionFailed;
}

pub fn assertApproxEqual(expected: f64, actual: f64, tolerance: f64) !void {
    const diff = @abs(expected - actual);
    if (diff > tolerance) return error.AssertionFailed;
}
