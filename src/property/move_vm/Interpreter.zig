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

    allocator: std.mem.Allocator,
    frames: std.ArrayList(Frame),
    max_depth: usize,

    pub fn init(allocator: std.mem.Allocator, max_depth: usize) Self {
        return .{
            .allocator = allocator,
            .frames = std.ArrayList(Frame).empty,
            .max_depth = max_depth,
        };
    }

    pub fn push(self: *Self, frame: Frame) !void {
        if (self.frames.items.len >= self.max_depth) return error.CallStackOverflow;
        try self.frames.append(self.allocator, frame);
    }

    pub fn pop(self: *Self) ?Frame {
        return self.frames.pop();
    }

    pub fn deinit(self: *Self) void {
        self.frames.deinit(self.allocator);
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
    /// Local variable slots (indexed by ld_loc/st_loc operand).
    locals: std.ArrayList(Value),
    pc: usize,
    instructions: []const Bytecode.Instruction,
    output_objects: std.ArrayList([32]u8),
    /// Phase 2: native function registry
    registry: ?*Registry = null,
    /// Phase 2: transaction context injection
    tx_context: ?*TxContext = null,
    /// Phase 2: events emitted during execution
    events: std.ArrayList(Event),
    /// Bytecode verification cache — avoids re-verifying repeated contracts
    verified_cache: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty,

    pub fn init(allocator: std.mem.Allocator, gas: *Gas.GasMeter, tracker: *Resource.ResourceTracker) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .stack = std.ArrayList(Value).empty,
            .gas = gas,
            .resource_tracker = tracker,
            .call_stack = CallStack.init(allocator, 1024),
            .locals = std.ArrayList(Value).empty,
            .pc = 0,
            .instructions = &.{},
            .output_objects = std.ArrayList([32]u8).empty,
            .registry = null,
            .tx_context = null,
            .events = std.ArrayList(Event).empty,
            .verified_cache = .empty,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.stack.items) |v| v.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        for (self.locals.items) |v| v.deinit(self.allocator);
        self.locals.deinit(self.allocator);
        self.output_objects.deinit(self.allocator);
        self.call_stack.deinit();
        for (self.events.items) |evt| self.allocator.free(evt.payload);
        self.events.deinit(self.allocator);
        self.verified_cache.deinit(self.allocator);
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

    /// Check if a module bytecode hash is already verified and cached.
    fn isVerifiedCached(self: *Self, bytecode_hash: [32]u8) bool {
        return self.verified_cache.contains(bytecode_hash);
    }

    /// Cache a module hash as verified.
    fn cacheVerified(self: *Self, bytecode_hash: [32]u8) !void {
        try self.verified_cache.put(self.allocator, bytecode_hash, {});
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

    // NOTE: The canonical bytecode encoding is big-endian. These compat decoders
    // exist to handle legacy mixed-endian bytecode. Once all bytecode generators
    // are updated to emit canonical big-endian, these should be simplified to
    // unconditional big-endian reads.
    fn decodeU64Compat(payload: []const u8) u64 {
        const big = std.mem.readInt(u64, payload[0..8], .big);
        const little = std.mem.readInt(u64, payload[0..8], .little);
        const small_cutoff: u64 = 1 << 40;
        if (little <= small_cutoff and big > small_cutoff) return little;
        if (big <= small_cutoff and little > small_cutoff) return big;
        return big;
    }

    fn decodeI64Compat(payload: []const u8) i64 {
        const big = std.mem.readInt(i64, payload[0..8], .big);
        const little = std.mem.readInt(i64, payload[0..8], .little);
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
        const big = std.mem.readInt(u32, payload[0..4], .big);
        const little = std.mem.readInt(u32, payload[0..4], .little);
        if (little <= max_count and big > max_count) return little;
        if (big <= max_count and little > max_count) return big;
        return big;
    }

    /// Pop two integer-typed values from stack. Returns error.TypeMismatch and
    /// restores the stack if either value is not an integer.
    fn popTwoInts(self: *Self) !struct { a: Value, b: Value } {
        if (self.stack.items.len < 2) return error.StackUnderflow;
        const b = self.stack.pop().?;
        const a = self.stack.pop().?;
        if (a.tag != .integer or b.tag != .integer) {
            try self.stack.append(self.allocator, a);
            try self.stack.append(self.allocator, b);
            return error.TypeMismatch;
        }
        return .{ .a = a, .b = b };
    }

    /// Pop one integer-typed value from stack. Returns error.TypeMismatch and
    /// restores the stack if the value is not an integer.
    fn popTwoBools(self: *Self) !struct { a: Value, b: Value } {
        if (self.stack.items.len < 2) return error.StackUnderflow;
        const b = self.stack.pop().?;
        const a = self.stack.pop().?;
        if (a.tag != .boolean or b.tag != .boolean) {
            try self.stack.append(self.allocator, a);
            try self.stack.append(self.allocator, b);
            return error.TypeMismatch;
        }
        return .{ .a = a, .b = b };
    }

    fn popOneInt(self: *Self) !Value {
        if (self.stack.items.len < 1) return error.StackUnderflow;
        const v = self.stack.pop().?;
        if (v.tag != .integer) {
            try self.stack.append(self.allocator, v);
            return error.TypeMismatch;
        }
        return v;
    }

    /// Type ability bitmask for runtime enforcement.
    const AbilityKey   = 0x01; // can be stored in global state (move_to)
    const AbilityCopy  = 0x02; // can be duplicated (copy_resource)
    const AbilityDrop  = 0x04; // can be deleted (delete_resource)
    const AbilityStore = 0x08; // can be stored inside other structs

    /// Look up abilities for a resource type_tag. Resources default to
    /// Key|Drop|Store (no Copy — linear types). Special types can opt into Copy.
    fn typeAbilities(type_tag: u8) u8 {
        return switch (type_tag) {
            0 => 0, // invalid — no abilities
            1 => AbilityKey | AbilityDrop | AbilityStore, // Coin
            2 => AbilityKey | AbilityDrop | AbilityStore | AbilityCopy, // FungibleToken (copyable)
            3 => AbilityKey | AbilityDrop | AbilityStore, // NFT (not copyable)
            4 => AbilityKey | AbilityStore, // SharedObject (not droppable)
            else => AbilityKey | AbilityDrop | AbilityStore, // default resource
        };
    }

    fn hasKeyAbility(value: Value) bool {
        if (value.tag != .resource) return false;
        return (typeAbilities(value.data.resource.type_tag) & AbilityKey) != 0;
    }

    fn hasCopyAbility(value: Value) bool {
        if (value.tag != .resource) return false;
        return (typeAbilities(value.data.resource.type_tag) & AbilityCopy) != 0;
    }

    fn hasDropAbility(value: Value) bool {
        if (value.tag != .resource) return true; // non-resource values are always droppable
        return (typeAbilities(value.data.resource.type_tag) & AbilityDrop) != 0;
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
                var val = self.stack.pop().?;
                val.deinit(self.allocator);
            },
            .dup => {
                if (self.stack.items.len == 0) return error.StackUnderflow;
                const top = self.stack.pop().?;
                const cloned = try top.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
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
                if (instr.payload.len < 8) return error.InvalidInstructionPayload;
                const val = decodeI64Compat(instr.payload);
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = val } });
            },
            .ld_true => {
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = true } });
            },
            .ld_false => {
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = false } });
            },
            .ld_u8 => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = instr.payload[0] } });
            },
            .ld_u64 => {
                if (instr.payload.len < 8) return error.InvalidInstructionPayload;
                const val = decodeU64Compat(instr.payload);
                if (val > @as(u64, @intCast(std.math.maxInt(i64)))) return error.ArithmeticOverflow;
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @intCast(val) } });
            },
            .ld_i64 => {
                if (instr.payload.len < 8) return error.InvalidInstructionPayload;
                const val = decodeI64Compat(instr.payload);
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = val } });
            },
            .ld_addr => {
                if (instr.payload.len < 32) return error.InvalidInstructionPayload;
                var addr: [32]u8 = undefined;
                @memcpy(&addr, instr.payload[0..32]);
                try self.stack.append(self.allocator, Value{ .tag = .address, .data = .{ .address = addr } });
            },
            .add => {
                const ints = try self.popTwoInts();
                const result, const overflow = @addWithOverflow(ints.a.data.int, ints.b.data.int);
                if (overflow != 0) { @branchHint(.cold); return error.ArithmeticOverflow; }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
            },
            .sub => {
                const ints = try self.popTwoInts();
                const result, const overflow = @subWithOverflow(ints.a.data.int, ints.b.data.int);
                if (overflow != 0) { @branchHint(.cold); return error.ArithmeticOverflow; }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
            },
            .mul => {
                const ints = try self.popTwoInts();
                const result, const overflow = @mulWithOverflow(ints.a.data.int, ints.b.data.int);
                if (overflow != 0) { @branchHint(.cold); return error.ArithmeticOverflow; }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
            },
            .div => {
                const ints = try self.popTwoInts();
                if (ints.b.data.int == 0) { @branchHint(.cold); return error.DivisionByZero; }
                if (ints.a.data.int == std.math.minInt(i64) and ints.b.data.int == -1) { @branchHint(.cold); return error.ArithmeticOverflow; }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @divTrunc(ints.a.data.int, ints.b.data.int) } });
            },
            .mod => {
                const ints = try self.popTwoInts();
                if (ints.b.data.int == 0) { @branchHint(.cold); return error.DivisionByZero; }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @rem(ints.a.data.int, ints.b.data.int) } });
            },
            .neg => {
                const a = try self.popOneInt();
                const result, const overflow = @subWithOverflow(@as(i64, 0), a.data.int);
                if (overflow != 0) { @branchHint(.cold); return error.ArithmeticOverflow; }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
            },
            .bit_and => {
                const ints = try self.popTwoInts();
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = ints.a.data.int & ints.b.data.int } });
            },
            .bit_or => {
                const ints = try self.popTwoInts();
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = ints.a.data.int | ints.b.data.int } });
            },
            .bit_xor => {
                const ints = try self.popTwoInts();
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = ints.a.data.int ^ ints.b.data.int } });
            },
            .shl => {
                const ints = try self.popTwoInts();
                if (ints.b.data.int < 0 or ints.b.data.int >= 64) { @branchHint(.cold); return error.ArithmeticOverflow; }
                const shift = @as(u6, @intCast(ints.b.data.int));
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = ints.a.data.int << shift } });
            },
            .shr => {
                const ints = try self.popTwoInts();
                if (ints.b.data.int < 0 or ints.b.data.int >= 64) { @branchHint(.cold); return error.ArithmeticOverflow; }
                const shift = @as(u6, @intCast(ints.b.data.int));
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = ints.a.data.int >> shift } });
            },
            .eq => {
                if (self.stack.items.len < 2) return error.StackUnderflow;
                const b = self.stack.pop().?;
                const a = self.stack.pop().?;
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = valuesEqual(a, b) } });
            },
            .neq => {
                if (self.stack.items.len < 2) return error.StackUnderflow;
                const b = self.stack.pop().?;
                const a = self.stack.pop().?;
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = !valuesEqual(a, b) } });
            },
            .lt => {
                const ints = try self.popTwoInts();
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = ints.a.data.int < ints.b.data.int } });
            },
            .gt => {
                const ints = try self.popTwoInts();
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = ints.a.data.int > ints.b.data.int } });
            },
            .lte => {
                const ints = try self.popTwoInts();
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = ints.a.data.int <= ints.b.data.int } });
            },
            .gte => {
                const ints = try self.popTwoInts();
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = ints.a.data.int >= ints.b.data.int } });
            },
            .@"and" => {
                const bools = try self.popTwoBools();
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = bools.a.data.bool and bools.b.data.bool } });
            },
            .@"or" => {
                const bools = try self.popTwoBools();
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = bools.a.data.bool or bools.b.data.bool } });
            },
            .not => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const a = self.stack.pop().?;
                if (a.tag != .boolean) {
                    try self.stack.append(self.allocator, a);
                    return error.TypeMismatch;
                }
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = !a.data.bool } });
            },
            .move_resource => {
                if (self.stack.items.len < 2) return error.StackUnderflow;
                const resource = self.stack.pop().?;
                const destination = self.stack.pop().?;
                if (resource.tag != .resource) {
                    try self.stack.append(self.allocator, destination);
                    try self.stack.append(self.allocator, resource);
                    return error.TypeMismatch;
                }
                if (destination.tag != .address) {
                    try self.stack.append(self.allocator, destination);
                    try self.stack.append(self.allocator, resource);
                    return error.TypeMismatch;
                }
                // Enforce key ability: only key-able resources can be moved to storage
                if (!hasKeyAbility(resource)) return error.InvalidResource;
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &resource.data.resource.id);
                try self.resource_tracker.recordMove(oid);
            },
            .call => {
                try self.executeCall(instr);
            },
            .call_indirect => {
                try self.executeCall(instr);
            },
            .ret => {
                self.pc = self.instructions.len;
                return;
            },
            .move_to_sender => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const resource = self.stack.pop().?;
                if (resource.tag != .resource) {
                    try self.stack.append(self.allocator, resource);
                    return error.TypeMismatch;
                }
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &resource.data.resource.id);
                if (!self.resource_tracker.isTracked(oid)) return error.ResourceNotFound;
                // TODO: Validate signer owns resource (requires tx_context.sender check)
                try self.resource_tracker.recordMove(oid);
            },
            .move_from => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const addr = self.stack.pop().?;
                if (addr.tag != .address) {
                    try self.stack.append(self.allocator, addr);
                    return error.TypeMismatch;
                }
                const resource_id = addr.data.address;
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &resource_id);
                if (self.resource_tracker.isTracked(oid)) {
                    try self.stack.append(self.allocator, Value{ .tag = .resource, .data = .{ .resource = .{ .id = resource_id, .type_tag = 0 } } });
                } else {
                    return error.ResourceNotFound;
                }
            },
            .borrow_global => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const addr = self.stack.pop().?;
                if (addr.tag != .address) {
                    try self.stack.append(self.allocator, addr);
                    return error.TypeMismatch;
                }
                const resource_id = addr.data.address;
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &resource_id);
                if (self.resource_tracker.isTracked(oid)) {
                    try self.stack.append(self.allocator, Value{ .tag = .resource, .data = .{ .resource = .{ .id = resource_id, .type_tag = 0 } } });
                } else {
                    return error.ResourceNotFound;
                }
            },
            .exists => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const addr = self.stack.pop().?;
                if (addr.tag != .address) {
                    try self.stack.append(self.allocator, addr);
                    return error.TypeMismatch;
                }
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &addr.data.address);
                const exists = self.resource_tracker.isTracked(oid);
                try self.stack.append(self.allocator, Value{ .tag = .boolean, .data = .{ .bool = exists } });
            },
            .delete_resource => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const resource = self.stack.pop().?;
                if (resource.tag != .resource) {
                    try self.stack.append(self.allocator, resource);
                    return error.TypeMismatch;
                }
                // Enforce drop ability: only droppable resources can be deleted
                if (!hasDropAbility(resource)) return error.InvalidResource;
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &resource.data.resource.id);
                try self.resource_tracker.recordConsume(oid);
            },
            .vec_len => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector) {
                    try self.stack.append(self.allocator, vec);
                    return error.TypeMismatch;
                }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @as(i64, @intCast(vec.data.vector.len)) } });
            },
            .vec_push => {
                if (self.stack.items.len < 2) return error.StackUnderflow;
                const value = self.stack.pop().?;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector) {
                    try self.stack.append(self.allocator, vec);
                    try self.stack.append(self.allocator, value);
                    return error.TypeMismatch;
                }
                var new_vec = try self.allocator.alloc(Value, vec.data.vector.len + 1);
                @memcpy(new_vec[0..vec.data.vector.len], vec.data.vector);
                self.allocator.free(vec.data.vector);
                new_vec[vec.data.vector.len] = value;
                try self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = new_vec } });
            },
            .vec_pop => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector) {
                    try self.stack.append(self.allocator, vec);
                    return error.TypeMismatch;
                }
                if (vec.data.vector.len == 0) return error.IndexOutOfBounds;
                try self.stack.append(self.allocator, vec.data.vector[vec.data.vector.len - 1]);
                const new_vec = try self.allocator.alloc(Value, vec.data.vector.len - 1);
                errdefer self.allocator.free(new_vec);
                @memcpy(new_vec, vec.data.vector[0 .. vec.data.vector.len - 1]);
                self.allocator.free(vec.data.vector);
                try self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = new_vec } });
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
                    errdefer elems.deinit(self.allocator);
                    for (0..count) |_| {
                        try elems.append(self.allocator, self.stack.pop().?);
                    }
                    std.mem.reverse(Value, elems.items);
                    const vec = try elems.toOwnedSlice(self.allocator);
                    errdefer self.allocator.free(vec);
                    try self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = vec } });
                }
            },
            .vec_unpack => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector) {
                    try self.stack.append(self.allocator, vec);
                    return error.TypeMismatch;
                }
                for (vec.data.vector) |elem| {
                    try self.stack.append(self.allocator, elem);
                }
                self.allocator.free(vec.data.vector);
            },
            .vec_borrow => {
                if (self.stack.items.len < 2) return error.StackUnderflow;
                const index = self.stack.pop().?;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector or index.tag != .integer) {
                    try self.stack.append(self.allocator, vec);
                    try self.stack.append(self.allocator, index);
                    return error.TypeMismatch;
                }
                if (index.data.int < 0) return error.IndexOutOfBounds;
                const idx = @as(usize, @intCast(index.data.int));
                if (idx < vec.data.vector.len) {
                    try self.stack.append(self.allocator, vec.data.vector[idx]);
                } else {
                    return error.IndexOutOfBounds;
                }
            },
            .ld_loc => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                const idx: usize = instr.payload[0];
                if (idx >= self.locals.items.len) return error.InvalidLocalIndex;
                const val = try self.locals.items[idx].clone(self.allocator);
                try self.stack.append(self.allocator, val);
            },
            .st_loc => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const val = self.stack.pop().?;
                const idx: usize = instr.payload[0];
                while (self.locals.items.len <= idx) {
                    try self.locals.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = 0 } });
                }
                // Deinit old value before overwriting (prevents vector/resource leak)
                self.locals.items[idx].deinit(self.allocator);
                self.locals.items[idx] = val;
            },
            .pack => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                const field_count: usize = instr.payload[0];
                if (self.stack.items.len < field_count) return error.StackUnderflow;
                // Pop fields from stack and repackage as struct
                const fields = try self.allocator.alloc(Value, field_count);
                defer self.allocator.free(fields);
                var i: usize = field_count;
                while (i > 0) {
                    i -= 1;
                    fields[i] = self.stack.pop().?;
                }
                // Struct is stored as a vector with struct_ tag
                try self.stack.append(self.allocator, Value{ .tag = .struct_, .data = .{ .vector = fields } });
            },
            .unpack => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const s = self.stack.pop().?;
                if (s.tag != .struct_) {
                    try self.stack.append(self.allocator, s);
                    return error.TypeMismatch;
                }
                for (s.data.vector) |field| {
                    try self.stack.append(self.allocator, field);
                }
                self.allocator.free(s.data.vector);
            },
            .borrow_field => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const s = self.stack.pop().?;
                const field_idx: usize = instr.payload[0];
                if (s.tag != .struct_) {
                    try self.stack.append(self.allocator, s);
                    return error.TypeMismatch;
                }
                if (field_idx >= s.data.vector.len) return error.IndexOutOfBounds;
                // Return field value directly (deep copy for safety)
                const field = try s.data.vector[field_idx].clone(self.allocator);
                try self.stack.append(self.allocator, s);
                try self.stack.append(self.allocator, field);
            },
            .borrow_field_mut => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const s = self.stack.pop().?;
                const field_idx: usize = instr.payload[0];
                if (s.tag != .struct_) {
                    try self.stack.append(self.allocator, s);
                    return error.TypeMismatch;
                }
                if (field_idx >= s.data.vector.len) return error.IndexOutOfBounds;
                // Return mutable reference (same as immutable for now — Move semantics deferred)
                const field = try s.data.vector[field_idx].clone(self.allocator);
                try self.stack.append(self.allocator, s);
                try self.stack.append(self.allocator, field);
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

        // Deep-copy args before native call so the native function can hold
        // references without risking dangling pointers after stack shrink.
        const native_args = try self.allocator.alloc(Value, arg_count);
        defer self.allocator.free(native_args);
        for (0..arg_count) |i| {
            native_args[i] = try self.stack.items[args_start + i].clone(self.allocator);
        }

        const native = reg.resolve(module_name, func_name) orelse return error.UnimplementedInstruction;
        const result = native(self, native_args) catch |err| switch (err) {
            error.InvalidArgumentCount => return error.InvalidArgumentCount,
            error.TypeMismatch => return error.TypeMismatch,
            error.ResourceNotFound => return error.ResourceNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            error.UnimplementedNative => return error.UnimplementedInstruction,
        };

        // Free cloned args after native function returns
        for (native_args) |*arg| arg.deinit(self.allocator);
        // Remove original args from stack
        for (self.stack.items[args_start..]) |*arg| arg.deinit(self.allocator);
        self.stack.shrinkRetainingCapacity(args_start);
        try self.stack.append(self.allocator, result);
    }

    fn valuesEqual(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .integer => a.data.int == b.data.int,
            .boolean => a.data.bool == b.data.bool,
            .address => std.mem.eql(u8, &a.data.address, &b.data.address),
            .resource => std.mem.eql(u8, &a.data.resource.id, &b.data.resource.id),
            .vector => blk: {
                if (a.data.vector.len != b.data.vector.len) break :blk false;
                for (a.data.vector, b.data.vector) |va, vb| {
                    if (!valuesEqual(va, vb)) break :blk false;
                }
                break :blk true;
            },
            .struct_ => false,
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
