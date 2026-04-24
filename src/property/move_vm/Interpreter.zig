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
const NativeFunction = @import("NativeFunction.zig");
const Registry = NativeFunction.Registry;
const TxContextModule = @import("TxContext.zig");
const TxContext = TxContextModule.TxContext;
const EventEmitter = @import("EventEmitter.zig");
const Event = EventEmitter.Event;

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

    /// Recursively release any heap-allocated data owned by this Value.
    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        switch (self.tag) {
            .vector => {
                for (self.data.vector) |v| {
                    v.deinit(allocator);
                }
                allocator.free(self.data.vector);
            },
            else => {},
        }
    }

    /// Deep-clone a Value. For scalar types this is a bitwise copy;
    /// for vectors it recursively clones every element so that the
    /// caller owns an independent copy.
    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        switch (self.tag) {
            .vector => {
                const new_vec = try allocator.alloc(Value, self.data.vector.len);
                errdefer allocator.free(new_vec);
                for (self.data.vector, 0..) |v, i| {
                    new_vec[i] = try v.clone(allocator);
                }
                var copy = self;
                copy.data.vector = new_vec;
                return copy;
            },
            else => return self,
        }
    }

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
    events: []Event,
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
            .frames = std.ArrayList(Frame).empty,
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
    /// Phase 2: native function registry
    registry: ?*Registry = null,
    /// Phase 2: transaction context injection
    tx_context: ?*TxContext = null,
    /// Phase 2: events emitted during execution
    events: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator, gas: *Gas.GasMeter, tracker: *Resource.ResourceTracker) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .stack = std.ArrayList(Value).empty,
            .gas = gas,
            .resource_tracker = tracker,
            .call_stack = CallStack.init(1024),
            .pc = 0,
            .instructions = &.{},
            .output_objects = std.ArrayList([32]u8).empty,
            .registry = null,
            .tx_context = null,
            .events = std.ArrayList(Event).empty,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.stack.items) |v| {
            v.deinit(self.allocator);
        }
        self.stack.deinit(self.allocator);
        self.output_objects.deinit(self.allocator);
        self.call_stack.deinit();
        for (self.events.items) |evt| {
            self.allocator.free(evt.payload);
        }
        self.events.deinit(self.allocator);
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
            .output_objects = self.output_objects.items,
            .events = self.events.items,
            .err = null,
        };
    }

    fn decodeU64Compat(payload: []const u8) u64 {
        const little = std.mem.readInt(u64, payload[0..8], .little);
        const big = std.mem.readInt(u64, payload[0..8], .big);
        const small_cutoff: u64 = 1 << 40;
        if (little <= small_cutoff and big > small_cutoff) return little;
        if (big <= small_cutoff and little > small_cutoff) return big;

        var leading: usize = 0;
        while (leading < payload.len and payload[leading] == 0) : (leading += 1) {}
        var trailing: usize = 0;
        while (trailing < payload.len and payload[payload.len - 1 - trailing] == 0) : (trailing += 1) {}
        if (trailing > leading) return little;
        if (leading > trailing) return big;
        return big;
    }

    fn decodeI64Compat(payload: []const u8) i64 {
        const little = std.mem.readInt(i64, payload[0..8], .little);
        const big = std.mem.readInt(i64, payload[0..8], .big);
        const little_abs = i64Magnitude(little);
        const big_abs = i64Magnitude(big);
        if (little_abs < big_abs) return little;
        if (big_abs < little_abs) return big;
        return big;
    }

    fn i64Magnitude(v: i64) u64 {
        if (v == std.math.minInt(i64)) return std.math.maxInt(u64);
        if (v < 0) return @intCast(-v);
        return @intCast(v);
    }

    fn decodeVecCountCompat(payload: []const u8, max_count: u32) u32 {
        const little = std.mem.readInt(u32, payload[0..4], .little);
        const big = std.mem.readInt(u32, payload[0..4], .big);
        if (little <= max_count and big > max_count) return little;
        if (big <= max_count and little > max_count) return big;
        return big;
    }

    fn executeInstruction(self: *Self, instr: Bytecode.Instruction) !void {
        switch (instr.opcode) {
            .nop => {},
            .branch => {
                if (instr.payload.len < 2) return error.InvalidInstructionPayload;
                self.pc = @as(usize, std.mem.readInt(u16, instr.payload[0..2], .big));
                return;
            },
            .branch_if => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                if (instr.payload.len < 2) return error.InvalidInstructionPayload;
                const cond = self.stack.pop().?;
                if (cond.tag != .boolean) return error.TypeMismatch;
                if (cond.data.bool) {
                    self.pc = @as(usize, std.mem.readInt(u16, instr.payload[0..2], .big));
                    return;
                }
            },
            .pop => {
                if (self.stack.items.len == 0) return error.StackUnderflow;
                _ = self.stack.pop().?;
            },
            .dup => {
                if (self.stack.items.len == 0) return error.StackUnderflow;
                const top = self.stack.pop().?;
                const cloned = try top.clone(self.allocator);
                try self.stack.append(self.allocator, top);
                try self.stack.append(self.allocator, cloned);
            },
            .swap => {
                if (self.stack.items.len < 2) return error.StackUnderflow;
                const a = self.stack.pop().?;
                const b = self.stack.pop().?;
                try self.stack.append(self.allocator, a);
                try self.stack.append(self.allocator, b);
            },
            .ld_const => {
                if (instr.payload.len >= 8) {
                    const val = decodeI64Compat(instr.payload);
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
                    const val = decodeU64Compat(instr.payload);
                    try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @intCast(val) } });
                }
            },
            .ld_i64 => {
                if (instr.payload.len >= 8) {
                    const val = decodeI64Compat(instr.payload);
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
                return error.UnimplementedInstruction;
            },
            .call => {
                try self.executeCall(instr);
            },
            .call_indirect => {
                return error.UnimplementedInstruction;
            },
            .ret => {
                self.pc = self.instructions.len;
                return;
            },
            .move_to_sender => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const resource = self.stack.pop().?;
                if (resource.tag == .resource) {
                    var oid = ObjectID.zero;
                    @memcpy(&oid.bytes, &resource.data.resource.id);
                    try self.resource_tracker.recordMove(oid);
                }
            },
            .move_from => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
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
                if (self.stack.items.len < 1) return error.StackUnderflow;
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
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const addr = self.stack.pop().?;
                if (addr.tag == .address) {
                    var oid = ObjectID.zero;
                    @memcpy(&oid.bytes, &addr.data.address);
                    const exists = self.resource_tracker.isTracked(oid);
                    try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = exists } });
                }
            },
            .delete_resource => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
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
                    const value = self.stack.pop().?;
                    const vec = self.stack.pop().?;
                    if (vec.tag == .vector) {
                        var new_vec = try self.allocator.alloc(Value, vec.data.vector.len + 1);
                        @memcpy(new_vec[0..vec.data.vector.len], vec.data.vector);
                        new_vec[vec.data.vector.len] = value;
                        try self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = new_vec } });
                    }
                }
            },
            .vec_pop => {
                if (self.stack.items.len >= 1) {
                    const vec = self.stack.pop().?;
                    if (vec.tag == .vector and vec.data.vector.len > 0) {
                        try self.stack.append(self.allocator, vec.data.vector[vec.data.vector.len - 1]);
                        const new_vec = try self.allocator.alloc(Value, vec.data.vector.len - 1);
                        @memcpy(new_vec, vec.data.vector[0 .. vec.data.vector.len - 1]);
                        try self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = new_vec } });
                    }
                }
            },
            .vec_pack => {
                const MAX_VEC_PACK: u32 = 4096;
                var count: u32 = 0;
                var consumed_count_from_stack = false;

                if (self.stack.items.len > 0) {
                    const top = self.stack.items[self.stack.items.len - 1];
                    if (top.tag == .integer and top.data.int >= 0) {
                        count = @intCast(top.data.int);
                        _ = self.stack.pop();
                        consumed_count_from_stack = true;
                    }
                }

                if (!consumed_count_from_stack) {
                    if (instr.payload.len < 4) return error.InvalidInstructionPayload;
                    count = decodeVecCountCompat(instr.payload, MAX_VEC_PACK);
                }

                if (count > MAX_VEC_PACK) return error.InvalidInstructionPayload;
                if (self.stack.items.len < count) return error.StackUnderflow;
                {
                    var elems = try std.ArrayList(Value).initCapacity(self.allocator, count);
                    defer elems.deinit(self.allocator);
                    for (0..count) |_| {
                        try elems.append(self.allocator, self.stack.pop().?);
                    }
                    // Reverse to maintain order since we popped from stack
                    std.mem.reverse(Value, elems.items);
                    const vec = try elems.toOwnedSlice(self.allocator);
                    try self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = vec } });
                }
            },
            .vec_unpack => {
                if (self.stack.items.len >= 1) {
                    const vec = self.stack.pop().?;
                    if (vec.tag == .vector) {
                        for (vec.data.vector) |elem| {
                            try self.stack.append(self.allocator, elem);
                        }
                    }
                }
            },
            .vec_borrow => {
                if (self.stack.items.len >= 2) {
                    const index = self.stack.pop().?;
                    const vec = self.stack.pop().?;
                    if (vec.tag == .vector and index.tag == .integer) {
                        if (index.data.int < 0) return error.IndexOutOfBounds;
                        const idx = @as(usize, @intCast(index.data.int));
                        if (idx < vec.data.vector.len) {
                            try self.stack.append(self.allocator, vec.data.vector[idx]);
                        } else {
                            return error.IndexOutOfBounds;
                        }
                    }
                }
            },
            else => return error.UnsupportedOpcode,
        }
    }

    /// Base gas charged for every native function call in addition to the
    /// `call` instruction complexity. Prevents gas bypass through cheap loops
    /// of native functions.
    const NATIVE_CALL_BASE_GAS: u64 = 50;

    /// Execute a native function call.
    /// Payload format: [module_len: u8][module: bytes][func_len: u8][func: bytes][arg_count: u8]
    fn executeCall(self: *Self, instr: Bytecode.Instruction) !void {
        const reg = self.registry orelse return error.UnimplementedInstruction;
        const payload = instr.payload;
        if (payload.len < 3) return error.InvalidInstructionPayload;

        var offset: usize = 0;
        const module_len = payload[offset];
        offset += 1;
        if (payload.len < offset + module_len + 1) return error.InvalidInstructionPayload;
        const module_name = payload[offset..][0..module_len];
        offset += module_len;

        const func_len = payload[offset];
        offset += 1;
        if (payload.len < offset + func_len + 1) return error.InvalidInstructionPayload;
        const func_name = payload[offset..][0..func_len];
        offset += func_len;

        const arg_count = payload[offset];

        if (self.stack.items.len < arg_count) return error.StackUnderflow;

        // Charge base gas for native call before execution
        try self.gas.consume(NATIVE_CALL_BASE_GAS);

        // Pop arguments from stack (last arg is top of stack)
        const args_start = self.stack.items.len - arg_count;
        const args = self.stack.items[args_start..];

        const native = reg.resolve(module_name, func_name) orelse return error.UnimplementedInstruction;
        const result = native(self, args) catch |err| switch (err) {
            error.InvalidArgumentCount => return error.InvalidArgumentCount,
            error.TypeMismatch => return error.TypeMismatch,
            error.ResourceNotFound => return error.ResourceNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            error.UnimplementedNative => return error.UnimplementedInstruction,
        };

        // Remove consumed args from stack. Deinit each argument first because
        // native functions receive borrowed values and do not own stack memory.
        for (args) |arg| {
            arg.deinit(self.allocator);
        }
        self.stack.shrinkRetainingCapacity(args_start);
        try self.stack.append(self.allocator, result);
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

test "Interpreter fails safely on unimplemented instruction" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const module = Bytecode.VerifiedModule{
        .name = "test_unimplemented",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .call, .payload = &[_]u8{ 0, 1 } },
        },
        .local_count = 0,
    };

    try std.testing.expectError(error.UnimplementedInstruction, interpreter.execute(module));
}

test "Interpreter returns stack underflow instead of crashing" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const module = Bytecode.VerifiedModule{
        .name = "test_stack_underflow",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .pop, .payload = &.{} },
        },
        .local_count = 0,
    };

    try std.testing.expectError(error.StackUnderflow, interpreter.execute(module));
}
