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
const ResourceTracker = property.move_vm.ResourceTracker;
const Interpreter = property.move_vm.Interpreter;
const Bytecode = property.move_vm.Bytecode;
const Registry = property.move_vm.Registry;
const TxContext = property.move_vm.TxContext;
const Event = property.move_vm.Event;
const Ingress = @import("Ingress.zig");
const DependencyGraph = @import("DependencyGraph.zig").DependencyGraph;
const Log = @import("../app/Log.zig");

/// Execution result
pub const ExecutionResult = struct {
    digest: [32]u8,
    status: ExecutionStatus,
    gas_used: u64,
    output_objects: [][32]u8,
    /// Phase 2: events emitted during VM execution
    events: []Event,

    /// Release all owned memory
    pub fn deinit(self: ExecutionResult, allocator: std.mem.Allocator) void {
        if (self.output_objects.len > 0) allocator.free(self.output_objects);
        for (self.events) |evt| {
            if (evt.payload.len > 0) allocator.free(evt.payload);
        }
        if (self.events.len > 0) allocator.free(self.events);
    }
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
    resource_tracker: *ResourceTracker,
    /// Phase 2: optional native function registry for VM calls
    registry: ?*Registry = null,

    pub fn init(allocator: std.mem.Allocator, config: ExecutorConfig) !*Self {
        const tracker = try allocator.create(ResourceTracker);
        tracker.* = ResourceTracker.init(allocator);
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
            .registry = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.registry) |reg| {
            reg.deinit();
            self.allocator.destroy(reg);
        }
        self.resource_tracker.deinit();
        self.allocator.destroy(self.resource_tracker);
        self.allocator.destroy(self);
    }

    /// Execute a single transaction (legacy wrapper without tx context)
    pub fn execute(self: *Self, tx: Ingress.Transaction) !ExecutionResult {
        return self.executeWithContext(tx, null);
    }

    /// Execute a single transaction with optional tx context for native functions
    pub fn executeWithContext(self: *Self, tx: Ingress.Transaction, tx_context: ?*TxContext) !ExecutionResult {
        // Initialize gas meter
        const gas_config: Gas.GasConfig = .{
            .initial_budget = tx.gas_budget,
            .max_gas = self.config.max_gas,
        };
        var gas = Gas.GasMeter.init(gas_config);

        // Initialize interpreter
        var interpreter = try Interpreter.init(
            self.allocator,
            &gas,
            self.resource_tracker,
        );
        defer interpreter.deinit();
        interpreter.registry = self.registry;
        interpreter.tx_context = tx_context;

        // Parse and verify bytecode
        var verifier = Bytecode.BytecodeVerifier.init(self.allocator);
        var module = verifier.verify(tx.program) catch {
            return ExecutionResult{
                .digest = undefined,
                .status = .invalid_bytecode,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
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
                .events = &.{},
            };
        };
        // Release the return value (not used by Executor) to avoid leaking
        // any heap-allocated data (e.g. vectors) left on the stack.
        if (result.return_value) |rv| {
            rv.deinit(self.allocator);
        }

        // Validate resource tracking (void function - debug assert)
        self.resource_tracker.validate() catch |err| {
            Log.err("[ERR] Resource validation failed: {}", .{err});
            if (result.output_objects.len > 0) self.allocator.free(result.output_objects);
            for (result.events) |evt| { if (evt.payload.len > 0) self.allocator.free(evt.payload); }
            if (result.events.len > 0) self.allocator.free(result.events);
            return ExecutionResult{
                .digest = undefined,
                .status = .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            };
        };

        // Check for resource leaks - all resources should be consumed or moved
        self.resource_tracker.checkLeaks() catch |err| {
            Log.err("[ERR] Resource leak check failed: {}", .{err});
            if (result.output_objects.len > 0) self.allocator.free(result.output_objects);
            for (result.events) |evt| { if (evt.payload.len > 0) self.allocator.free(evt.payload); }
            if (result.events.len > 0) self.allocator.free(result.events);
            return ExecutionResult{
                .digest = undefined,
                .status = .resource_error,
                .gas_used = gas.getConsumed(),
                .output_objects = &.{},
                .events = &.{},
            };
        };

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
            .events = result.events,
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
                    .events = &.{},
                };
                continue;
            };
        }
        return results;
    }

    /// Execute transactions with dependency ordering using DependencyGraph.
    /// Batches within a level have no conflicts and could run in parallel;
    /// currently they are executed sequentially within the batch.
    pub fn executeOrdered(self: *Self, transactions: []const Ingress.Transaction) ![]ExecutionResult {
        const allocator = self.allocator;
        var graph = try DependencyGraph.init(allocator, transactions);
        defer graph.deinit();

        const batches = try graph.topologicalBatches(allocator);
        defer {
            for (batches) |b| allocator.free(b);
            allocator.free(batches);
        }

        const results = try allocator.alloc(ExecutionResult, transactions.len);
        for (batches) |batch| {
            for (batch) |idx| {
                results[idx] = self.executeWithContext(transactions[idx], null) catch |err| {
                    results[idx] = ExecutionResult{
                        .digest = [_]u8{0} ** 32,
                        .status = if (err == error.OutOfGas) .out_of_gas else .resource_error,
                        .gas_used = 0,
                        .output_objects = &.{},
                        .events = &.{},
                    };
                };
            }
        }
        return results;
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
