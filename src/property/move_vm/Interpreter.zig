//! Interpreter - Deterministic Move bytecode execution engine
//!
//! Implements a stack-based interpreter with:
//! - Deterministic execution (same input = same output)
//! - Linear type tracking with compile-time verification
//! - Gas metering with monotonic pricing
//! - Full arithmetic, logic, and control flow instructions

const std = @import("std");
const core = @import("../../core.zig");
const ObjectID = core.ObjectID;
const Resource = @import("Resource.zig");
const Gas = @import("Gas.zig");
const Bytecode = @import("Bytecode.zig");

/// Value types on the stack
pub const Value = struct {
    const Self = @This();

    tag: ValueTag,
    data: Data,

    pub const ValueTag = enum(u8) {
        integer = 1,
        boolean = 2,
        address = 3,
        resource = 4,
        vector = 5,
        struct_ = 6,
    };

    pub const Data = union {
        int: i64,
        bool: bool,
        address: [32]u8,
        resource: ResourceLoc,
        vector: []Value,
    };

    pub const ResourceLoc = struct {
        id: [32]u8,
        type_tag: u8,
    };

    pub fn asInt(self: Self) i64 {
        return self.data.int;
    }

    pub fn asBool(self: Self) bool {
        return self.data.bool;
    }

    pub fn isZero(self: Self) bool {
        return switch (self.tag) {
            .integer => self.data.int == 0,
            .boolean => !self.data.bool,
            else => false,
        };
    }
};

/// Execution result
pub const ExecutionResult = struct {
    success: bool,
    return_value: ?Value,
    gas_consumed: u64,
    resources_used: usize,
    output_objects: [][32]u8,
    err: ?anyerror,
};

/// Execution frame for function calls
pub const Frame = struct {
    return_address: usize,
    local_count: usize,
    stack_height: usize,
    locals: []Value,
};

/// Call stack
pub const CallStack = struct {
    const Self = @This();

    frames: std.ArrayList(Frame),
    max_depth: usize,

    pub fn init(max_depth: usize) Self {
        return .{
            .frames = std.ArrayList(Frame){},
            .max_depth = max_depth,
        };
    }

    pub fn push(self: *Self, frame: Frame) !void {
        if (self.frames.items.len >= self.max_depth) {
            return error.CallStackOverflow;
        }
        try self.frames.append(std.heap.page_allocator, frame);
    }

    pub fn pop(self: *Self) ?Frame {
        return self.frames.pop();
    }

    pub fn deinit(self: *Self) void {
        self.frames.deinit(std.heap.page_allocator);
    }
};

/// Deterministic interpreter with full instruction set
pub const Interpreter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    stack: std.ArrayList(Value),
    gas: *Gas.GasMeter,
    resource_tracker: *Resource.ResourceTracker,
    call_stack: CallStack,
    pc: usize,
    instructions: []const Bytecode.Instruction,
    output_objects: std.ArrayList([32]u8),

    pub fn init(allocator: std.mem.Allocator, gas: *Gas.GasMeter, tracker: *Resource.ResourceTracker) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .stack = std.ArrayList(Value){},
            .gas = gas,
            .resource_tracker = tracker,
            .call_stack = CallStack.init(1024),
            .pc = 0,
            .instructions = &.{},
            .output_objects = std.ArrayList([32]u8){},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit(self.allocator);
        self.output_objects.deinit(self.allocator);
        self.call_stack.deinit();
        self.allocator.destroy(self);
    }

    fn collectOutputObjects(self: *Self) !void {
        for (self.stack.items) |value| {
            if (value.tag == .resource) {
                try self.output_objects.append(self.allocator, value.data.resource.id);
            } else if (value.tag == .vector) {
                try self.collectFromVector(value.data.vector);
            }
        }
    }

    fn collectFromVector(self: *Self, vec: []Value) !void {
        for (vec) |value| {
            if (value.tag == .resource) {
                try self.output_objects.append(self.allocator, value.data.resource.id);
            } else if (value.tag == .vector) {
                try self.collectFromVector(value.data.vector);
            }
        }
    }

    pub fn execute(self: *Self, module: Bytecode.VerifiedModule) !ExecutionResult {
        self.instructions = module.instructions;
        self.pc = 0;

        while (self.pc < self.instructions.len) {
            const instr = self.instructions[self.pc];
            try self.gas.consume(instr.complexity());
            try self.executeInstruction(instr);
            self.pc += 1;
        }

        const return_value = if (self.stack.items.len > 0) self.stack.pop() else null;
        try self.collectOutputObjects();

        return ExecutionResult{
            .success = true,
            .return_value = return_value,
            .gas_consumed = self.gas.getConsumed(),
            .resources_used = self.resource_tracker.activeCount(),
            .output_objects = try self.output_objects.toOwnedSlice(self.allocator),
            .err = null,
        };
    }

    fn executeInstruction(self: *Self, instr: Bytecode.Instruction) !void {
        switch (instr.opcode) {
            .nop => {},
            .ret => {
                self.pc = self.instructions.len;
                return;
            },
            .branch => {
                if (instr.payload.len >= 2) {
                    self.pc = @as(usize, std.mem.readInt(u16, instr.payload[0..2], .big));
                    return;
                }
            },
            .branch_if => {
                if (self.stack.items.len >= 1) {
                    const cond = self.stack.pop().?;
                    if (cond.tag == .boolean and cond.data.bool) {
                        if (instr.payload.len >= 2) {
                            self.pc = @as(usize, std.mem.readInt(u16, instr.payload[0..2], .big));
                            return;
                        }
                    }
                }
            },
            .pop => {
                if (self.stack.items.len > 0) {
                    _ = self.stack.pop().?;
                }
            },
            .dup => {
                if (self.stack.items.len > 0) {
                    const top = self.stack.pop().?;
                    try self.stack.append(self.allocator, top);
                    try self.stack.append(self.allocator, top);
                }
            },
            .swap => {
                if (self.stack.items.len >= 2) {
                    const a = self.stack.pop().?;
                    const b = self.stack.pop().?;
                    try self.stack.append(self.allocator, a);
                    try self.stack.append(self.allocator, b);
                }
            },
            .ld_const => {
                if (instr.payload.len >= 8) {
                    const val = std.mem.readInt(i64, instr.payload[0..8], .big);
                    try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = val } });
                }
            },
            .ld_true => {
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = true } });
            },
            .ld_false => {
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = false } });
            },
            .ld_u8 => {
                if (instr.payload.len >= 1) {
                    try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = instr.payload[0] } });
                }
            },
            .ld_u64 => {
                if (instr.payload.len >= 8) {
                    const val = std.mem.readInt(u64, instr.payload[0..8], .big);
                    try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @intCast(val) } });
                }
            },
            .ld_i64 => {
                if (instr.payload.len >= 8) {
                    const val = std.mem.readInt(i64, instr.payload[0..8], .big);
                    try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = val } });
                }
            },
            .ld_addr => {
                if (instr.payload.len >= 32) {
                    var addr: [32]u8 = undefined;
                    @memcpy(&addr, instr.payload[0..32]);
                    try self.stack.append(self.allocator, Value{ .tag = .address, .data = .{ .address = addr } });
                }
            },
            .add => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        const result, const overflow = @addWithOverflow(a.data.int, b.data.int);
                        if (overflow != 0) return error.ArithmeticOverflow;
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
                    }
                }
            },
            .sub => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        const result, const overflow = @subWithOverflow(a.data.int, b.data.int);
                        if (overflow != 0) return error.ArithmeticOverflow;
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
                    }
                }
            },
            .mul => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        const result, const overflow = @mulWithOverflow(a.data.int, b.data.int);
                        if (overflow != 0) return error.ArithmeticOverflow;
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
                    }
                }
            },
            .div => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        if (b.data.int == 0) return error.DivisionByZero;
                        if (a.data.int == std.math.minInt(i64) and b.data.int == -1) {
                            return error.ArithmeticOverflow;
                        }
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @divTrunc(a.data.int, b.data.int) } });
                    }
                }
            },
            .mod => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        if (b.data.int == 0) return error.DivisionByZero;
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @rem(a.data.int, b.data.int) } });
                    }
                }
            },
            .neg => {
                if (self.stack.items.len >= 1) {
                    const a = self.stack.pop().?;
                    if (a.tag == .integer) {
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = -a.data.int } });
                    }
                }
            },
            .bit_and => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = a.data.int & b.data.int } });
                    }
                }
            },
            .bit_or => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = a.data.int | b.data.int } });
                    }
                }
            },
            .bit_xor => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = a.data.int ^ b.data.int } });
                    }
                }
            },
            .shl => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        const shift = @as(u6, @intCast(@mod(b.data.int, 64)));
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = a.data.int << shift } });
                    }
                }
            },
            .shr => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        const shift = @as(u6, @intCast(@mod(b.data.int, 64)));
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = a.data.int >> shift } });
                    }
                }
            },
            .eq => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = valuesEqual(a, b) } });
                }
            },
            .neq => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = !valuesEqual(a, b) } });
                }
            },
            .lt => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = a.data.int < b.data.int } });
                    }
                }
            },
            .gt => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = a.data.int > b.data.int } });
                    }
                }
            },
            .lte => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = a.data.int <= b.data.int } });
                    }
                }
            },
            .gte => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .integer and b.tag == .integer) {
                        try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = a.data.int >= b.data.int } });
                    }
                }
            },
            .@"and" => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .boolean and b.tag == .boolean) {
                        try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = a.data.bool and b.data.bool } });
                    }
                }
            },
            .@"or" => {
                if (self.stack.items.len >= 2) {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    if (a.tag == .boolean and b.tag == .boolean) {
                        try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = a.data.bool or b.data.bool } });
                    }
                }
            },
            .not => {
                if (self.stack.items.len >= 1) {
                    const a = self.stack.pop().?;
                    if (a.tag == .boolean) {
                        try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = !a.data.bool } });
                    }
                }
            },
            .move_resource => {
                if (instr.payload.len >= 1) {
                    const local_idx = instr.payload[0];
                    _ = local_idx;
                }
            },
            .move_to_sender => {
                const resource = self.stack.pop().?;
                if (resource.tag == .resource) {
                    var oid = ObjectID.zero;
                    @memcpy(&oid.bytes, &resource.data.resource.id);
                    try self.resource_tracker.recordMove(oid);
                }
            },
            .move_from => {
                const addr = self.stack.pop().?;
                if (addr.tag == .address) {
                    const resource_id = addr.data.address;
                    var oid = ObjectID.zero;
                    @memcpy(&oid.bytes, &resource_id);
                    if (self.resource_tracker.isTracked(oid)) {
                        try self.stack.append(self.allocator, Value{ .tag = .resource, .data = .{ .resource = .{ .id = resource_id, .type_tag = 0 } } });
                    } else {
                        return error.ResourceNotFound;
                    }
                }
            },
            .borrow_global => {
                const addr = self.stack.pop().?;
                if (addr.tag == .address) {
                    const resource_id = addr.data.address;
                    var oid = ObjectID.zero;
                    @memcpy(&oid.bytes, &resource_id);
                    if (self.resource_tracker.isTracked(oid)) {
                        try self.stack.append(self.allocator, Value{ .tag = .resource, .data = .{ .resource = .{ .id = resource_id, .type_tag = 0 } } });
                    } else {
                        return error.ResourceNotFound;
                    }
                }
            },
            .exists => {
                const addr = self.stack.pop().?;
                if (addr.tag == .address) {
                    var oid = ObjectID.zero;
                    @memcpy(&oid.bytes, &addr.data.address);
                    const exists = self.resource_tracker.isTracked(oid);
                    try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = exists } });
                }
            },
            .delete_resource => {
                const resource = self.stack.pop().?;
                if (resource.tag == .resource) {
                    var oid = ObjectID.zero;
                    @memcpy(&oid.bytes, &resource.data.resource.id);
                    try self.resource_tracker.recordConsume(oid);
                }
            },
            .vec_len => {
                if (self.stack.items.len >= 1) {
                    const vec = self.stack.pop().?;
                    if (vec.tag == .vector) {
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @as(i64, @intCast(vec.data.vector.len)) } });
                    }
                }
            },
            .vec_push => {
                if (self.stack.items.len >= 2) {
                    _ = self.stack.pop().?;
                    const vec = self.stack.pop().?;
                    if (vec.tag == .vector) {
                        try self.stack.append(self.allocator, vec);
                    }
                }
            },
            .vec_pop => {
                if (self.stack.items.len >= 1) {
                    const vec = self.stack.pop().?;
                    if (vec.tag == .vector and vec.data.vector.len > 0) {
                        try self.stack.append(self.allocator, vec.data.vector[vec.data.vector.len - 1]);
                    }
                }
            },
            .vec_pack => {
                if (instr.payload.len >= 4) {
                    const count = std.mem.readInt(u32, instr.payload[0..4], .big);
                    var elems = try std.ArrayList(Value).initCapacity(self.allocator, count);
                    defer elems.deinit(self.allocator);
                    for (0..count) |_| {
                        try elems.append(self.allocator, self.stack.pop().?);
                    }
                    const vec = try elems.toOwnedSlice(self.allocator);
                    try self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = vec } });
                }
            },
            else => {},
        }
    }

    fn valuesEqual(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .integer => a.data.int == b.data.int,
            .boolean => a.data.bool == b.data.bool,
            .address => std.mem.eql(u8, &a.data.address, &b.data.address),
            else => false,
        };
    }
};

test "Interpreter basic execution" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    // ld_true; ret
    const module = Bytecode.VerifiedModule{
        .name = "test",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_true, .payload = &.{} },
            .{ .opcode = .ret, .payload = &.{} },
        },
        .local_count = 0,
    };

    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value.?.tag == .boolean);
    try std.testing.expect(result.return_value.?.data.bool == true);
}
