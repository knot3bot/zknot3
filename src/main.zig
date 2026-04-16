//! zknot3 Node - Main entry point
//!
//! This is the entry point for the zknot3-node executable.
//! Supports various command-line options for configuration.

const std = @import("std");
const app = @import("app.zig");
const Node = app.Node;
const Config = app.Config;
const ConfigWithBuffer = app.ConfigWithBuffer;
const ConfigModule = @import("app/Config.zig");
const NodeDependencies = app.NodeDependencies;
const HTTPServer = @import("form/network/HTTPServer.zig").HTTPServer;
const ConsensusIntegration = @import("form/consensus/ConsensusIntegration.zig").ConsensusIntegration;
const Log = @import("app/Log.zig");

/// Global shutdown flag with atomic access
var running = std.atomic.Value(bool).init(true);

/// Global I/O instance for compatibility with Zig 0.16.0 API

/// Command line options
const Options = struct {
    help: bool = false,
    version: bool = false,
    dev: bool = false,
    validator: bool = false,
    config_file: ?[]const u8 = null,
    rpc_port: ?u16 = null,
    p2p_port: ?u16 = null,
    log_level: []const u8 = "info",
    data_dir: ?[]const u8 = null,
};

/// Print usage information
fn printUsage() void {
    std.debug.print(
        \\zknot3 Blockchain Node v{s}
        \\
        \\Usage: zknot3-node [options]
        \\
        \\Options:
        \\  -h, --help           Show this help message
        \\  -v, --version        Show version information
        \\  -d, --dev            Start in development mode (validator enabled)
        \\  --validator          Enable validator mode
        \\  -c, --config <file>  Load configuration from file
        \\  --rpc-port <port>    Set RPC server port (default: 9000)
        \\  --p2p-port <port>    Set P2P server port (default: 8080)
        \\  --log-level <level>  Set log level: error, warn, info, debug, trace
        \\  --data-dir <path>    Set data directory (default: ./data)
        \\
        \\Examples:
        \\  zknot3-node --dev                    Start in development mode
        \\  zknot3-node --validator --dev         Start as validator in dev mode
        \\  zknot3-node --rpc-port 9001          Use custom RPC port
        \\  zknot3-node --log-level debug         Enable debug logging
        \\
    , .{"0.1.0"});
}

/// Print version information
fn printVersion() void {
    std.debug.print(
        \\zknot3 Blockchain Node
        \\Version: 0.1.0
        \\Protocol: Knot3-compatible
        \\VM: Move VM (Zig interpreter)
        \\Consensus: Mysticeti (DAG-based BFT)
        \\
    , .{});
}

/// Parse command line arguments
fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !Options {
    var opts = Options{};

    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();

    // Skip program name
    _ = it.next();

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            opts.version = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dev")) {
            opts.dev = true;
        } else if (std.mem.eql(u8, arg, "--validator")) {
            opts.validator = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            const next = it.next() orelse return error.MissingArgument;
            opts.config_file = try allocator.dupe(u8, next);
        } else if (std.mem.eql(u8, arg, "--rpc-port")) {
            const next = it.next() orelse return error.MissingArgument;
            opts.rpc_port = try std.fmt.parseInt(u16, next, 10);
        } else if (std.mem.eql(u8, arg, "--p2p-port")) {
            const next = it.next() orelse return error.MissingArgument;
            opts.p2p_port = try std.fmt.parseInt(u16, next, 10);
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            const next = it.next() orelse return error.MissingArgument;
            opts.log_level = try allocator.dupe(u8, next);
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            const next = it.next() orelse return error.MissingArgument;
            opts.data_dir = try allocator.dupe(u8, next);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        }
    }

    return opts;
}

/// Apply parsed options to configuration
fn applyOptions(opts: Options, config: *Config) void {
    if (opts.dev) {
        // Only set dev-specific defaults if not already configured
        if (config.consensus.validator_enabled == false) {
            config.*.consensus.validator_enabled = true;
        }
        if (config.network.p2p_enabled == false) {
            config.*.network.p2p_enabled = true;
        }
    }
    if (opts.validator) {
        config.*.network.p2p_enabled = true;
    }
    if (opts.rpc_port) |port| {
        config.*.network.rpc_port = port;
    }
    if (opts.p2p_port) |port| {
        config.*.network.p2p_port = port;
        config.*.network.p2p_enabled = true;
    }
    if (opts.data_dir) |dir| {
        config.*.storage.data_dir = dir;
    }
}

fn applyLogLevel(level_str: []const u8) void {
    if (std.mem.eql(u8, level_str, "error")) {
        Log.global_level = .err;
    } else if (std.mem.eql(u8, level_str, "warn")) {
        Log.global_level = .warn;
    } else if (std.mem.eql(u8, level_str, "info")) {
        Log.global_level = .info;
    } else if (std.mem.eql(u8, level_str, "debug") or std.mem.eql(u8, level_str, "trace")) {
        Log.global_level = .debug;
    }
}

/// Signal handler for SIGINT and SIGTERM
fn handleSignal(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx: ?*const anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx;
    requestShutdown();
}

/// Request graceful shutdown (can be called from signal handler or other threads)
pub fn requestShutdown() void {
    running.store(false, .seq_cst);
}

/// Register signal handlers for graceful shutdown
fn registerSignalHandlers() void {
    var sa = std.posix.Sigaction{
        .handler = .{ .sigaction = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

/// Main entry point
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    @import("io_instance").io = init.io;


    // Parse command line arguments
    const opts = parseArgs(allocator, init.minimal.args) catch |err| {
        switch (err) {
            error.MissingArgument => {
                Log.err("Error: option requires an argument", .{});
            },
            error.UnknownOption => {
                Log.err("Error: unknown option", .{});
            },
            else => {
                Log.err("Error parsing arguments", .{});
            },
        }
        Log.info("Run 'zknot3-node --help' for usage information.", .{});
        return;
    };

    applyLogLevel(opts.log_level);

    // Handle help/version
    if (opts.help) {
        printUsage();
        return;
    }
    if (opts.version) {
        printVersion();
        return;
    }

    // Build configuration
    var config = Config.default();
    var config_with_buffer: ?ConfigWithBuffer = null;
    // Load config from file if specified
    if (opts.config_file) |config_path| {
        Log.info("[CONFIG] Loading config from: {s}", .{config_path});
        const cwb = ConfigModule.loadConfigWithBuffer(allocator, init.io, config_path) catch |err| {
            Log.err("[CONFIG] Failed to load config from {s}: {s}", .{ config_path, @errorName(err) });
            return;
        };
        config = cwb.config;
        config_with_buffer = cwb;
        Log.info("[CONFIG] Config loaded successfully", .{});
    }
    defer {
        if (config_with_buffer) |*cw| {
            cw.deinit(allocator);
        }
    }
    applyOptions(opts, &config);
    registerSignalHandlers();

    // Create node dependencies (empty for CLI - full app would provide real deps)
    const deps = NodeDependencies{
        .object_store = null,
        .consensus = null,
        .executor = null,
        .indexer = null,
        .epoch_bridge = null,
    };

    // Initialize the node
    var node = Node.init(allocator, &config, deps) catch |err| {
        Log.err("Failed to initialize node: {s}", .{@errorName(err)});
        return;
    };
    defer node.deinit();

    // Start the node
    node.start() catch |err| {
        Log.err("Failed to start node: {s}", .{@errorName(err)});
        return;
    };

    // Start HTTP server
    const rpc_addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", config.network.rpc_port) catch {
        Log.err("Invalid RPC address", .{});
        return;
    };
    var http_server = HTTPServer.initWithDashboard(allocator, rpc_addr, node, config.network.max_requests_per_second) catch |init_err| {
        Log.err("Failed to create HTTP server: {s}", .{@errorName(init_err)});
        return;
    };
    http_server.start() catch |http_err| {
        Log.err("Failed to start HTTP server: {s}", .{@errorName(http_err)});
        return;
    };

    Log.info("zknot3 node started.", .{});
    Log.info("  RPC: http://127.0.0.1:{}", .{config.network.rpc_port});
    if (config.network.p2p_enabled) {
        Log.info("  P2P: 0.0.0.0:{}", .{config.network.p2p_port});
    }
    Log.info("  Data: {s}", .{config.storage.data_dir});

    // Initialize consensus integration if P2P is enabled
    var consensus_integration: ?*ConsensusIntegration = null;
    defer {
        if (consensus_integration) |*ci| {
            allocator.destroy(ci.*);
        }
    }
    if (node.getP2PServer()) |p2p| {
        // Derive validator public key from signing_key seed
        const validator_key = if (config.authority.signing_key) |sk| sk else .{0} ** 32;
        const real_kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(validator_key) catch |err| {
            Log.err("[ERR] Failed to derive validator key: {}", .{err});
            return;
        };
        const validator_id = real_kp.public_key.toBytes();
        const validator_index = config.authority.validator_index;
        consensus_integration = ConsensusIntegration.init(allocator, node, p2p, validator_id, validator_key, validator_index) catch null;
        if (consensus_integration) |_| {
            Log.info("  Consensus: Enabled (validator {})", .{validator_index});
        }
    }

    Log.info("\nPress Ctrl+C to stop.", .{});
    // Event loop - accept and handle HTTP and P2P connections
    while (running.load(.seq_cst)) {
        // Accept and handle HTTP connection
        if (http_server.listener) |_| {
            if (http_server.accept()) |conn| {
                http_server.handleConnection(conn) catch |err| {
                    Log.err("[MAIN] HTTP handleConnection error: {s}", .{@errorName(err)});
                };
            } else |err| {
                if (err != error.WouldBlock) {
                    Log.err("[MAIN] HTTP accept error: {s}", .{@errorName(err)});
                    continue;
                }
            }
        }
        // Accept P2P connection if enabled
        if (node.getP2PServer()) |p2p| {
            p2p.acceptOne() catch |err| {
                if (err != error.WouldBlock) {
                    Log.err("[MAIN] P2P acceptOne error: {s}", .{@errorName(err)});
                }
            };
            p2p.maintainBootstrapConnections();
        }
        // Process consensus messages and check for proposals
        if (consensus_integration) |ci| {
            ci.processPeerMessages() catch |err| {
                Log.err("[MAIN] processPeerMessages error: {s}", .{@errorName(err)});
            };
            ci.checkAndPropose() catch |err| {
                Log.err("[MAIN] checkAndPropose error: {s}", .{@errorName(err)});
            };
        }

        // Prevent busy-waiting in the event loop
        try std.Io.sleep(init.io, std.Io.Duration.fromNanoseconds(1 * std.time.ns_per_ms), .awake);
    }

    // Graceful shutdown
    Log.info("\nShutting down gracefully...", .{});
    http_server.deinit();
    node.stop();
    Log.info("Shutdown complete.", .{});
}
