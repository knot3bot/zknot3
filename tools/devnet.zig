//! Devnet - 4-validator development network for zknot3
//!
//! This tool starts a local development network with 4 validators
//! for integration testing and development.

const std = @import("std");
ZP|const root = @import("../src/root.zig");

const Node = root.app.Node;
const Config = root.app.Config.Config;

const NUM_VALIDATORS = 4;
const BASE_PORT: u16 = 9000;
const BASE_P2P_PORT: u16 = 9100;

/// Print usage information
fn printUsage() void {
    std.debug.print(
        \\zknot3 Devnet - Local Development Network
        \\
        \\Usage: zknot3-devnet [options]
        \\
        \\Options:
        \\  -h, --help        Show this help message
        \\  -v, --verbose     Enable verbose logging
        \\  --num-validators  Number of validators (default: 4)
        \\  --port-base       Base port number (default: 9000)
        \\
    , .{});
}

/// Validator configuration for devnet
fn createValidatorConfig(
    allocator: std.mem.Allocator,
    index: usize,
    port_base: u16,
) !Config {
    const name = try std.fmt.allocPrint(allocator, "devnet-validator-{d}", .{index});
    defer allocator.free(name);

    return Config{
        .network = .{
            .address = "127.0.0.1",
            .port = port_base + @as(u16, @intCast(index * 100)),
            .p2p_port = port_base + 1000 + @as(u16, @intCast(index * 100)),
        },
        .consensus = .{
            .validator_enabled = true,
        },
        .authority = .{
            .name = name,
            .stake = 1000000000000000, // 1M SUI in MIST
            .signing_key = null,
        },
    };
}

/// Start the devnet
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments
    var args = std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var num_validators: usize = NUM_VALIDATORS;
    var port_base: u16 = BASE_PORT;
    var verbose = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--num-validators")) {
            if (args.next()) |n| {
                num_validators = try std.fmt.parseInt(usize, n, 10);
            }
        } else if (std.mem.eql(u8, arg, "--port-base")) {
            if (args.next()) |p| {
                port_base = try std.fmt.parseInt(u16, p, 10);
            }
        }
    }

    std.debug.print("Starting zknot3 Devnet with {d} validators...\n", .{num_validators});

    // Create nodes
    var nodes: std.ArrayList(*Node) = std.ArrayList(*Node).init(allocator);
    defer {
        for (nodes.items) |n| n.deinit();
        nodes.deinit();
    }

    var i: usize = 0;
    while (i < num_validators) : (i += 1) {
        const config = try createValidatorConfig(allocator, i, port_base);
        const node = try Node.init(allocator, &config);
        try nodes.append(node);

        std.debug.print("  Validator {d}: port={d}, p2p={d}\n", .{
            i,
            config.network.port,
            config.network.p2p_port,
        });
    }

    std.debug.print("\nStarting all validators...\n", .{});

    // Start all nodes
    for (nodes.items) |node| {
        try node.start();
    }

    std.debug.print("\nDevnet running! Press Ctrl+C to stop.\n", .{});

    // Wait for shutdown signal
    try std.event.Loop.instance.?.run();
}
