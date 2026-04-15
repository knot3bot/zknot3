//! Test Cluster Runner - Multi-node integration test runner for zknot3
//!
//! This tool provides utilities for running multi-node integration tests.

const std = @import("std");
const root = @import("../src/root.zig");

/// Print usage information
fn printUsage() void {
    std.debug.print(
        \\zknot3 Test Cluster Runner
        \\
        \\Usage: zknot3-test-cluster [options]
        \\
        \\Options:
        \\  -h, --help        Show this help
        \\  -n, --nodes N     Number of nodes (default: 4)
        \\  -t, --test        Run tests only
        \\
    , .{});
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("zknot3 Test Cluster Runner\n", .{});
    std.debug.print("============================\n\n", .{});

    // Parse basic args
    var args = std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var num_nodes: usize = 4;
    var run_tests_only = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--nodes")) {
            if (args.next()) |n| {
                num_nodes = std.fmt.parseInt(usize, n, 10) catch 4;
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--test")) {
            run_tests_only = true;
        }
    }

    std.debug.print("Configured for {d} nodes\n", .{num_nodes});
    std.debug.print("\nUse 'zig build test' to run all tests.\n", .{});

    _ = run_tests_only;
}
