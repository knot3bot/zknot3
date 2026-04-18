//! Debugger - Move VM debugging and testing framework
//!
//! Provides comprehensive debugging capabilities for Move smart contracts,
//! including:
//! - Source-level debugging with breakpoints
//! - Step-by-step execution
//! - Stack and variable inspection
//! - Memory and resource tracking
//! - Execution trace and logging

const std = @import("std");
const core = @import("../../core.zig");
const Bytecode = @import("Bytecode.zig");
const Interpreter = @import("Interpreter.zig").Interpreter;
const ExecutionResult = @import("Interpreter.zig").ExecutionResult;
const Value = @import("Interpreter.zig").Value;
const Gas = @import("Gas.zig");
const Resource = @import("Resource.zig");
const ObjectID = core.ObjectID;

/// Debugger configuration
pub const DebuggerConfig = struct {
    /// Enable source-level debugging
    enable_source_debug: bool = true,
    /// Maximum trace depth
    max_trace_depth: usize = 1000,
    /// Enable detailed instruction tracing
    trace_instructions: bool = false,
    /// Enable gas consumption tracking
    track_gas: bool = true,
    /// Enable memory allocation tracking
    track_memory: bool = false,
};

/// Debugger state
pub const DebuggerState = enum {
    running,
    paused,
    stopped,
    breakpoint,
    error_state,
};

/// Breakpoint information
pub const Breakpoint = struct {
    /// Instruction offset
    offset: usize,
    /// Source file name (if available)
    source_file: ?[]const u8 = null,
    /// Source line number (if available)
    source_line: ?usize = null,
    /// Hit count
    hit_count: usize = 0,
};

/// Execution context for debugging
pub const DebugContext = struct {
    /// Current instruction offset
    pc: usize,
    /// Call stack
    call_stack: []const FrameInfo,
    /// Current stack
    stack: []const Value,
    /// Local variables (if available)
    locals: []const Value,
    /// Gas consumed so far
    gas_consumed: u64,
    /// Resources used
    resources_used: usize,
};

/// Call stack frame information
pub const FrameInfo = struct {
    /// Function name
    function_name: []const u8,
    /// Return address
    return_address: usize,
    /// Stack height
    stack_height: usize,
};

/// Debug event types
pub const DebugEvent = union(enum) {
    /// Breakpoint hit
    breakpoint: Breakpoint,
    /// Instruction executed
    instruction: InstructionInfo,
    /// Function call
    function_call: FrameInfo,
    /// Function return
    function_return: FrameInfo,
    /// Error occurred
    error_event: anyerror,
};

/// Instruction information for debugging
pub const InstructionInfo = struct {
    /// Offset in module
    offset: usize,
    /// Opcode
    opcode: Bytecode.Opcode,
    /// Payload bytes
    payload: []const u8,
};

/// Debugger interface for Move VM
pub const Debugger = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    interpreter: *Interpreter,
    config: DebuggerConfig,
    state: DebuggerState = .running,
    breakpoints: std.ArrayList(Breakpoint),
    events: std.ArrayList(DebugEvent),
    trace: std.ArrayList(InstructionInfo),
    paused: bool = false,

    /// Initialize debugger
    pub fn init(allocator: std.mem.Allocator, interpreter: *Interpreter, config: DebuggerConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .interpreter = interpreter,
            .config = config,
            .breakpoints = std.ArrayList(Breakpoint).empty,
            .events = std.ArrayList(DebugEvent).empty,
            .trace = std.ArrayList(InstructionInfo).empty,
        };
        return self;
    }

    /// Deinitialize debugger
    pub fn deinit(self: *Self) void {
        self.breakpoints.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.trace.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Add breakpoint at instruction offset
    pub fn addBreakpoint(self: *Self, offset: usize, source_file: ?[]const u8, source_line: ?usize) !void {
        try self.breakpoints.append(self.allocator, .{
            .offset = offset,
            .source_file = source_file,
            .source_line = source_line,
        });
    }

    /// Remove breakpoint at instruction offset
    pub fn removeBreakpoint(self: *Self, offset: usize) void {
        for (0..self.breakpoints.items.len) |i| {
            if (self.breakpoints.items[i].offset == offset) {
                _ = self.breakpoints.orderedRemove(i);
                break;
            }
        }
    }

    /// Check if offset has a breakpoint
    pub fn hasBreakpoint(self: *Self, offset: usize) ?Breakpoint {
        for (self.breakpoints.items) |bp| {
            if (bp.offset == offset) {
                return bp;
            }
        }
        return null;
    }

    /// Step to next instruction
    pub fn step(self: *Self) !DebugEvent {
        return self.executeStep(true);
    }

    /// Continue execution until breakpoint or end
    pub fn run(self: *Self) !DebugEvent {
        return self.executeStep(false);
    }

    /// Execute one step
    fn executeStep(self: *Self, single_step: bool) !DebugEvent {
        self.state = .running;
        const result = try self.interpreter.execute();
        return try self.processResult(result);
    }

    /// Get current debugging context
    pub fn getContext(self: *Self) !DebugContext {
        return .{
            .pc = self.interpreter.pc,
            .call_stack = &.{}, // TODO: Implement call stack extraction
            .stack = self.interpreter.stack.items,
            .locals = &.{}, // TODO: Implement local variable support
            .gas_consumed = self.interpreter.gas.getConsumed(),
            .resources_used = self.interpreter.resource_tracker.activeCount(),
        };
    }

    /// Get execution trace
    pub fn getTrace(self: *Self) []const InstructionInfo {
        return self.trace.items;
    }

    /// Get recent events
    pub fn getEvents(self: *Self, max_events: ?usize) []const DebugEvent {
        if (max_events) |count| {
            const start = if (self.events.items.len > count) self.events.items.len - count else 0;
            return self.events.items[start..];
        }
        return self.events.items;
    }

    /// Clear all breakpoints
    pub fn clearBreakpoints(self: *Self) void {
        self.breakpoints.clearRetainingCapacity();
    }

    /// Clear execution trace
    pub fn clearTrace(self: *Self) void {
        self.trace.clearRetainingCapacity();
    }

    /// Process execution result and generate debug events
    fn processResult(self: *Self, result: ExecutionResult) !DebugEvent {
        if (result.err) |err| {
            self.state = .error_state;
            const error_event: DebugEvent = .{ .error_event = err };
            try self.events.append(self.allocator, error_event);
            return error_event;
        }

        if (result.success) {
            self.state = .stopped;
        }

        return .{ .instruction = .{
            .offset = self.interpreter.pc,
            .opcode = self.interpreter.instructions[self.interpreter.pc].opcode,
            .payload = self.interpreter.instructions[self.interpreter.pc].payload,
        } };
    }
};

/// Test runner for Move modules
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    gas_config: Gas.GasConfig = .{ .initial_budget = 100000, .max_gas = 1000000 },
    verbose: bool = false,

    pub fn init(allocator: std.mem.Allocator) TestRunner {
        return .{
            .allocator = allocator,
        };
    }

    /// Run all tests in a module
    pub fn runModule(self: *TestRunner, module: Bytecode.VerifiedModule) !TestResults {
        var results = TestResults.init(self.allocator);
        errdefer results.deinit();

        // TODO: Implement test detection and execution

        return results;
    }

    /// Run a specific test function
    pub fn runTest(self: *TestRunner, module: Bytecode.VerifiedModule, test_name: []const u8) !bool {
        // TODO: Implement single test execution

        return true;
    }
};

/// Test results
pub const TestResults = struct {
    allocator: std.mem.Allocator,
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    errors: std.ArrayList(TestError),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(TestError).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.test_name);
        }
        self.errors.deinit(self.allocator);
    }

    pub fn addPassed(self: *Self) void {
        self.total += 1;
        self.passed += 1;
    }

    pub fn addFailed(self: *Self, test_name: []const u8, err: anyerror) !void {
        self.total += 1;
        self.failed += 1;
        try self.errors.append(self.allocator, .{
            .test_name = try self.allocator.dupe(u8, test_name),
            .error = err,
        });
    }

    pub fn getSummary(self: Self) []const u8 {
        const buf = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, 100);
        defer buf.deinit();

        try buf.writer().print("Tests: {d} passed, {d} failed, {d} total\n", .{
            self.passed,
            self.failed,
            self.total,
        });

        return buf.items;
    }
};

/// Test error information
pub const TestError = struct {
    test_name: []const u8,
    error: anyerror,
};

/// Helper function to create a test module
pub fn createTestModule(
    name: []const u8,
    instructions: []const Bytecode.Instruction,
    local_count: usize,
) Bytecode.VerifiedModule {
    return .{
        .name = name,
        .instructions = instructions,
        .local_count = local_count,
    };
}

/// Helper for testing interpreter with debugger
pub fn debugModule(
    module: Bytecode.VerifiedModule,
    gas_config: Gas.GasConfig,
    on_event: ?*const fn (DebugEvent) void,
) !ExecutionResult {
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(std.heap.page_allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(std.heap.page_allocator, &gas, &tracker);
    defer interpreter.deinit();

    const config: DebuggerConfig = .{
        .enable_source_debug = true,
        .trace_instructions = true,
        .track_gas = true,
    };

    var debugger = try Debugger.init(std.heap.page_allocator, &interpreter, config);
    defer debugger.deinit();

    if (on_event) |callback| {
        // TODO: Implement event callback
    }

    return try interpreter.execute(module);
}

test "Debugger basic operations" {
    const allocator = std.testing.allocator;

    // Create a simple test module
    const module = Bytecode.VerifiedModule{
        .name = "test_debugger",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_true, .payload = &.{} },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    var gas = Gas.GasMeter.init(.{ .initial_budget = 1000, .max_gas = 10000 });
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const config: DebuggerConfig = .{ .trace_instructions = true };
    var debugger = try Debugger.init(allocator, &interpreter, config);
    defer debugger.deinit();

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value.?.tag == .boolean);
    try std.testing.expect(result.return_value.?.data.bool == true);

    // Verify trace has instructions
    try std.testing.expect(debugger.trace.items.len > 0);
}

test "Breakpoint functionality" {
    const allocator = std.testing.allocator;

    // Create a simple test module
    const module = Bytecode.VerifiedModule{
        .name = "test_breakpoints",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_true, .payload = &.{} },
            .{ .opcode = .ld_false, .payload = &.{} },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    var gas = Gas.GasMeter.init(.{ .initial_budget = 1000, .max_gas = 10000 });
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    var debugger = try Debugger.init(allocator, &interpreter, .{});
    defer debugger.deinit();

    // Add breakpoint at instruction 1
    try debugger.addBreakpoint(1, null, null);

    try std.testing.expect(debugger.hasBreakpoint(1) != null);

    debugger.removeBreakpoint(1);
    try std.testing.expect(debugger.hasBreakpoint(1) == null);
}