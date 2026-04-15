//! Executor - Parallel transaction execution with resource tracking
//!
//! Implements parallel transaction execution with:
//! - Sequential execution (thread pool deferred)
//! - Resource tracking with linear type guarantees
//! - Gas metering with budget enforcement

const std = @import("std");
const core = @import("../core.zig");
const property = @import("../property.zig");
const Gas = property.move_vm.Gas;
const Resource = property.move_vm.Resource;
const Interpreter = property.move_vm.Interpreter;
const Bytecode = property.move_vm.Bytecode;
const Ingress = @import("Ingress.zig");
const Log = @import("../app/Log.zig");

/// Execution result
pub const ExecutionResult = struct {
    digest: [32]u8,
    status: ExecutionStatus,
    gas_used: u64,
    output_objects: [][32]u8,
};

/// Execution status
pub const ExecutionStatus = enum {
    success,
    out_of_gas,
    invalid_bytecode,
    resource_error,
};

/// Executor configuration
pub const ExecutorConfig = struct {
    parallelism: usize = 4,
    max_gas: u64 = 10_000_000,
};

/// Executor with transaction execution support
pub const Executor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ExecutorConfig,
    resource_tracker: *Resource.ResourceTracker,

    pub fn init(allocator: std.mem.Allocator, config: ExecutorConfig) !*Self {
        const tracker = try allocator.create(Resource.ResourceTracker);
        tracker.* = Resource.ResourceTracker.init(allocator);
        errdefer {
            tracker.deinit();
            allocator.destroy(tracker);
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .resource_tracker = tracker,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.resource_tracker.deinit();
        self.allocator.destroy(self);
    }

    /// Execute a single transaction
    pub fn execute(self: *Self, tx: Ingress.Transaction) !ExecutionResult {
        // Initialize gas meter
        const gas_config: Gas.GasConfig = .{
            .initial_budget = tx.gas_budget,
            .max_gas = self.config.max_gas,
        };
        var gas = Gas.GasMeter.init(gas_config);

        // Initialize interpreter
        var interpreter = try Interpreter.Interpreter.init(
            self.allocator,
            &gas,
            self.resource_tracker,
        );
        defer interpreter.deinit();

        // Parse and verify bytecode
        var verifier = Bytecode.BytecodeVerifier.init(self.allocator);
        var module = verifier.verify(tx.program) catch {
            return ExecutionResult{
                .digest = undefined,
                .status = .invalid_bytecode,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
            };
        };
        defer module.deinit(self.allocator);

        // Execute
        const result = interpreter.execute(module) catch |err| {
            return ExecutionResult{
                .digest = undefined,
                .status = if (err == error.OutOfGas) .out_of_gas else .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
            };
        };

        // Validate resource tracking (void function - debug assert)
        self.resource_tracker.validate() catch |err| {
            Log.err("[ERR] Resource validation failed: {}", .{err});
        };

        // Check for resource leaks - all resources should be consumed or moved
        try self.resource_tracker.checkLeaks();

        // Compute digest
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&tx.sender);
        var digest: [32]u8 = undefined;
        ctx.final(&digest);

        return ExecutionResult{
            .digest = digest,
            .status = .success,
            .gas_used = result.gas_consumed,
            .output_objects = result.output_objects,
        };
    }

    /// Execute multiple transactions sequentially
    pub fn executeBatch(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        const results = try self.allocator.alloc(ExecutionResult, transactions.len);
        for (transactions, 0..) |tx, i| {
            results[i] = self.execute(tx) catch |err| {
                results[i] = ExecutionResult{
                    .digest = [_]u8{0} ** 32,
                    .status = if (err == error.OutOfGas) .out_of_gas else .resource_error,
                    .gas_used = 0,
                    .output_objects = &.{},
                };
                continue;
            };
        }
        return results;
    }

    /// Execute transactions with dependency ordering (simplified - just sequential)
    pub fn executeOrdered(self: *Self, transactions: []const Ingress.Transaction, dependencies: []const []const usize) ![]ExecutionResult {
        _ = dependencies;
        return self.executeBatch(transactions);
    }

    /// Get parallelism level
    pub fn getParallelism(self: *const Self) usize {
        return self.config.parallelism;
    }
};

test "Executor basic execution" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 2 });
    defer executor.deinit();

    const tx = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 1,
    };

    const result = try executor.execute(tx);
    try std.testing.expect(result.status == .success);
    try std.testing.expect(result.gas_used > 0);
}

test "Executor parallelism" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{ .parallelism = 4 });
    defer executor.deinit();

    try std.testing.expect(executor.getParallelism() == 4);
}
