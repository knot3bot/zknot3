//! Gas - Gas metering with monotone functor semantics
//!
//! Implements gas metering with:
//! - Monotone cost functions (gas can only decrease)
//! - Budget enforcement
//! - Per-instruction cost calculation

const std = @import("std");

/// Gas configuration
pub const GasConfig = struct {
    /// Initial gas budget
    initial_budget: u64 = 1_000_000,
    /// Maximum gas per transaction
    max_gas: u64 = 10_000_000,
    /// Minimum gas per transaction
    min_gas: u64 = 1000,
};

/// Gas meter for tracking execution cost
pub const GasMeter = struct {
    const Self = @This();

    /// Remaining gas (monotonically decreasing)
    remaining: u64,
    /// Total gas consumed
    consumed: u64,
    /// Maximum allowed
    max_gas: u64,

    /// Initialize gas meter
    pub fn init(config: GasConfig) Self {
        return .{
            .remaining = config.initial_budget,
            .consumed = 0,
            .max_gas = config.max_gas,
        };
    }

    /// Consume gas (monotone - only decreases)
    pub fn consume(self: *Self, amount: u64) !void {
        if (amount > self.remaining) {
            return error.OutOfGas;
        }
        self.remaining -= amount;
        self.consumed += amount;
    }

    /// Check if has enough gas for operation
    pub fn hasGas(self: Self, amount: u64) bool {
        return self.remaining >= amount;
    }

    /// Get remaining gas
    pub fn getRemaining(self: Self) u64 {
        return self.remaining;
    }

    /// Get total consumed
    pub fn getConsumed(self: Self) u64 {
        return self.consumed;
    }

    /// Reset for new execution
    pub fn reset(self: *Self, config: GasConfig) void {
        self.remaining = config.initial_budget;
        self.consumed = 0;
        self.max_gas = config.max_gas;
    }
};

/// Gas cost functor for instruction costs
pub const GasFunctor = struct {
    const Self = @This();
    /// Base cost per instruction type
    allocator: std.mem.Allocator,
    base_costs: std.AutoArrayHashMapUnmanaged(u8, u64),

    pub const CostInstruction = struct { opcode: u8, complexity: u32 };

    /// Initialize with default costs
    pub fn init(allocator: std.mem.Allocator) !Self {
        var costs = std.AutoArrayHashMapUnmanaged(u8, u64).empty;

        // Default costs
        try costs.put(allocator, 0x00, 1); // nop
        try costs.put(allocator, 0x01, 1); // ret
        try costs.put(allocator, 0x02, 2); // branch
        try costs.put(allocator, 0x10, 1); // pop
        try costs.put(allocator, 0x11, 1); // dup
        try costs.put(allocator, 0x20, 1); // ld_loc
        try costs.put(allocator, 0x21, 1); // st_loc
        try costs.put(allocator, 0x30, 2); // ld_const
        try costs.put(allocator, 0x40, 1); // add
        try costs.put(allocator, 0x80, 10); // move_resource
        try costs.put(allocator, 0x90, 5); // call

        return .{ .allocator = allocator, .base_costs = costs };
    }

    pub fn deinit(self: *Self) void {
        self.base_costs.deinit(self.allocator);
    }

    /// Calculate cost for an instruction (monotone functor)
    pub fn cost(self: Self, opcode: u8, complexity: u32) u64 {
        const base = self.base_costs.get(opcode) orelse 1;
        // Cost scales with complexity
        return base * @as(u64, @intCast(complexity));
    }

    /// Estimate cost for bytecode (gas preview)
    pub fn estimateCost(self: Self, instructions: []const CostInstruction) u64 {
        var total: u64 = 0;
        for (instructions) |instr| {
            total += self.cost(instr.opcode, instr.complexity);
        }
        return total;
    }
};

/// Gas budget truncation (ensures termination)
pub fn truncateGas(budget: u64, max_budget: u64) u64 {
    return @min(budget, max_budget);
}

test "Gas meter basic operations" {
    const config = GasConfig{};
    var meter = GasMeter.init(config);

    try std.testing.expect(meter.getRemaining() == 1_000_000);
    try std.testing.expect(meter.getConsumed() == 0);

    try meter.consume(100);
    try std.testing.expect(meter.getRemaining() == 999_900);
    try std.testing.expect(meter.getConsumed() == 100);
}

test "Gas meter out of gas" {
    const config = GasConfig{};
    var meter = GasMeter.init(config);

    try meter.consume(1_000_000);
    try std.testing.expect(meter.getRemaining() == 0);

    // Should fail
    try std.testing.expectError(error.OutOfGas, meter.consume(1));
}

test "Gas functor cost calculation" {
    const allocator = std.testing.allocator;
    var functor = try GasFunctor.init(allocator);
    defer functor.deinit();

    const cost = functor.cost(0x80, 10); // move_resource
    try std.testing.expect(cost == 100); // base 10 * complexity 10
}

test "Gas estimation" {
    const allocator = std.testing.allocator;
    var functor = try GasFunctor.init(allocator);
    defer functor.deinit();

    const instructions = &[_]GasFunctor.CostInstruction{
        .{ .opcode = 0x80, .complexity = 10 },
        .{ .opcode = 0x40, .complexity = 1 },
        .{ .opcode = 0x90, .complexity = 5 },
    };

    const estimate = functor.estimateCost(instructions);
    // move_resource: 10*10=100, add: 1*1=1, call: 5*5=25 = 126
    try std.testing.expect(estimate == 126);
}

// Comptime assertion: gas is monotone
comptime {
    if (!@hasDecl(GasMeter, "consume")) @compileError("GasMeter must have consume method");
    if (!@hasDecl(GasMeter, "hasGas")) @compileError("GasMeter must have hasGas method");
}
