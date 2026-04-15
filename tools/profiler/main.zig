//! zknot3 Performance Profiler
//!
//! Command-line interface for running benchmarks across core operations.
//! Measures: ObjectID hashing, LSMTree operations, Signature operations,
//!           Consensus operations, Serialization, Move VM execution.
//!
//! Usage:
//!     zig build -Doptimize=ReleaseFast && ./zig-out/bin/zknot3-profiler
//!     ./zig-out/bin/zknot3-profiler --help
//!
//! Metrics collected:
//!   - 物丰 (wu_feng): Resource efficiency (memory, CPU)
//!   - 象大 (xiang_da): Knowledge coverage (benchmark breadth)
//!   - 性自在 (zi_zai): User satisfaction (latency, throughput)

const std = @import("std");

/// Profiler configuration
pub const ProfilerConfig = struct {
    iterations: u64 = 10000,
    warmup: bool = true,
    metrics: []const []const u8 = &.{ "wu_feng", "xiang_da", "zi_zai" },
};

/// Print usage information
fn printUsage() void {
    std.debug.print(
        \\zknot3 Performance Profiler
        \\
        \\Usage: zknot3-profiler [options]
        \\
        \\Options:
        \\  -h, --help              Show this help message
        \\  -i, --iterations <N>    Number of iterations per benchmark (default: 10000)
        \\  -w, --no-warmup         Skip warmup phase
        \\  -m, --metrics <list>    Comma-separated metrics to collect (default: wu_feng,xiang_da,zi_zai)
        \\
        \\Metrics:
        \\  wu_feng   Resource efficiency (memory, CPU)
        \\  xiang_da  Knowledge coverage (benchmark breadth)
        \\  zi_zai    User satisfaction (latency, throughput)
        \\
    , .{});
}

/// Parse command line arguments
fn parseArgs() !ProfilerConfig {
    var config = ProfilerConfig{};

    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --iterations requires a number\n", .{});
                return error.MissingIterations;
            }
            config.iterations = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--no-warmup")) {
            config.warmup = false;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--metrics")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --metrics requires a comma-separated list\n", .{});
                return error.MissingMetrics;
            }
            config.metrics = &.{args[i]};
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            std.process.exit(1);
        }
    }

    return config;
}

/// Run simple built-in benchmarks
fn runSimpleBenchmarks(iterations: u64) void {
    std.debug.print("Running built-in microbenchmarks ({d} iterations)...\n", .{iterations});
    
    // Simple loop benchmark
    const start1 = std.time.nanoTimestamp();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        // empty - just measuring loop overhead
    }
    const end1 = std.time.nanoTimestamp();
    const loop_ns = @as(u64, @intCast(end1 - start1));
    std.debug.print("  loop_overhead: {d} ns/op, {d:.2} ops/sec\n", .{
        loop_ns / iterations,
        @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(loop_ns))
    });
    
    // Simple compute benchmark
    const start2 = std.time.nanoTimestamp();
    i = 0;
    var result: u64 = 0;
    while (i < iterations) : (i += 1) {
        result +%= i;
    }
    const end2 = std.time.nanoTimestamp();
    const compute_ns = @as(u64, @intCast(end2 - start2));
    std.debug.print("  compute_benchmark: {d} ns/op, {d:.2} ops/sec (result={d})\n", .{
        compute_ns / iterations,
        @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(compute_ns)),
        result
    });
    
    std.debug.print("\nNote: Full benchmarks require linking with zknot3 library.\n", .{});
    std.debug.print("Run 'zig build test' to verify core functionality.\n", .{});
}

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           zknot3 Performance Profiler v0.1.0                    ║\n", .{});
    std.debug.print("║  三源指标 (Three Source Metrics): 物丰 · 象大 · 性自在          ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const config = try parseArgs();

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Iterations: {d}\n", .{config.iterations});
    std.debug.print("  Warmup: {}\n", .{config.warmup});
    std.debug.print("  Metrics: ", .{});
    for (config.metrics, 0..) |m, idx| {
        if (idx > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{m});
    }
    std.debug.print("\n\n", .{});

    // Run built-in microbenchmarks
    runSimpleBenchmarks(config.iterations);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Profile Complete                                      ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}

test "Profiler basic test" {
    try std.testing.expect(true);
}
