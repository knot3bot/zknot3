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
            .vector, .struct_ => {
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
            .vector, .struct_ => {
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
        /// Padding to 40 bytes (multiple of the union's 8-byte alignment).
        /// Without it the 33-byte field leaves odd padding inside `Data`
        /// and this Zig 0.17.0-dev toolchain miscompiles ReleaseFast
        /// copies of `Value` (tag reads as a different variant; verified
        /// with a standalone repro). Zero-cost at every other optimize level.
        _pad: [7]u8 = @as([7]u8, @splat(0)),
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
    /// Transfer, share, and freeze effects. The slice lives with the interpreter.
    object_effects: []ObjectEffect = &.{},
    err: ?anyerror,
};

/// A native object effect. `recipient` is the transfer destination.
/// Share and freeze leave it all zeros.
pub const ObjectEffect = struct {
    kind: Kind,
    object_id: [32]u8,
    recipient: [32]u8,

    pub const Kind = enum(u8) {
        transfer = 1,
        share = 2,
        freeze = 3,
    };
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
    object_effects: std.ArrayList(ObjectEffect),
    /// Phase 2: native function registry
    registry: ?*Registry = null,
    /// Phase 2: transaction context injection
    tx_context: ?*TxContext = null,
    /// Phase 2: events emitted during execution
    events: std.ArrayList(Event),
    /// Bytecode verification cache — avoids re-verifying repeated contracts
    verified_cache: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty,
    /// Resources already returned by move_from or borrow_global.
    loaded_ids: std.AutoArrayHashMapUnmanaged(ObjectID, void) = .empty,

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
            .object_effects = std.ArrayList(ObjectEffect).empty,
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
        self.object_effects.deinit(self.allocator);
        self.call_stack.deinit();
        for (self.events.items) |evt| self.allocator.free(evt.payload);
        self.events.deinit(self.allocator);
        self.verified_cache.deinit(self.allocator);
        self.loaded_ids.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn collectOutputObjects(self: *Self) !void {
        for (self.stack.items) |value| try self.collectFromValue(value);
    }

    fn collectFromValue(self: *Self, value: Value) !void {
        switch (value.tag) {
            .resource => try self.output_objects.append(self.allocator, value.data.resource.id),
            .vector, .struct_ => {
                for (value.data.vector) |field| try self.collectFromValue(field);
            },
            else => {},
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

    fn resetEffects(self: *Self) void {
        self.output_objects.clearRetainingCapacity();
        self.object_effects.clearRetainingCapacity();
        for (self.events.items) |evt| self.allocator.free(evt.payload);
        self.events.clearRetainingCapacity();
        for (self.locals.items) |local| local.deinit(self.allocator);
        self.locals.clearRetainingCapacity();
    }

    pub fn execute(self: *Self, module: Bytecode.VerifiedModule) !ExecutionResult {
        self.resetEffects();
        self.instructions = module.instructions;
        self.pc = 0;

        while (self.pc < self.instructions.len) {
            const instr = self.instructions[self.pc];
            try self.gas.consume(instr.complexity());
            try self.executeInstruction(instr);
            self.pc += 1;
        }

        const return_value = if (self.stack.items.len > 0) self.stack.pop() else null;
        errdefer if (return_value) |rv| rv.deinit(self.allocator);
        if (return_value) |rv| try self.collectFromValue(rv);
        try self.collectOutputObjects();

        return ExecutionResult{
            .success = true,
            .return_value = return_value,
            .gas_consumed = self.gas.getConsumed(),
            .resources_used = self.resource_tracker.activeCount(),
            .output_objects = self.output_objects.items,
            .events = self.events.items,
            .object_effects = self.object_effects.items,
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

    /// Duplicate the top value. Resources without the Copy ability stay on the stack.
    fn duplicateTop(self: *Self) !void {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        const top = self.stack.pop().?;
        if (copyForbidden(top)) {
            try self.stack.append(self.allocator, top);
            return error.InvalidResource;
        }
        const cloned = top.clone(self.allocator) catch |err| {
            self.stack.append(self.allocator, top) catch {
                top.deinit(self.allocator);
                return err;
            };
            return err;
        };
        self.stack.append(self.allocator, top) catch |err| {
            cloned.deinit(self.allocator);
            top.deinit(self.allocator);
            return err;
        };
        self.stack.append(self.allocator, cloned) catch |err| {
            cloned.deinit(self.allocator);
            return err;
        };
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
    const AbilityKey = 0x01; // can be stored in global state (move_to)
    const AbilityCopy = 0x02; // can be duplicated (copy_resource)
    const AbilityDrop = 0x04; // can be deleted (delete_resource)
    const AbilityStore = 0x08; // can be stored inside other structs

    /// Look up abilities for a resource type_tag. Resources default to
    /// Key|Drop|Store (no Copy — linear types). Special types can opt into Copy.
    /// Map a tracked `ResourceTag` onto the ability type tag used on the stack.
    /// Tag 0 has no abilities, so a loaded value must not stay at 0.
    fn stackTypeTag(tag: Resource.ResourceTag) u8 {
        return switch (tag) {
            .Coin => 1,
            .NFT => 3,
            .SharedObject => 4,
            .Custom => 5,
        };
    }

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

    /// A value cannot be copied when it, or a nested field, is a resource
    /// without the Copy ability.
    fn copyForbidden(value: Value) bool {
        switch (value.tag) {
            .resource => return !hasCopyAbility(value),
            .vector, .struct_ => {
                for (value.data.vector) |field| {
                    if (copyForbidden(field)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn hasDropAbility(value: Value) bool {
        if (value.tag != .resource) return true; // non-resource values are always droppable
        return (typeAbilities(value.data.resource.type_tag) & AbilityDrop) != 0;
    }

    /// A value cannot be discarded when it, or a nested field, lacks Drop.
    fn dropForbidden(value: Value) bool {
        switch (value.tag) {
            .resource => return !hasDropAbility(value),
            .vector, .struct_ => {
                for (value.data.vector) |field| {
                    if (dropForbidden(field)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn consumeTracked(self: *Self, value: Value) !void {
        switch (value.tag) {
            .resource => {
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &value.data.resource.id);
                if (self.resource_tracker.isTracked(oid)) {
                    try self.resource_tracker.recordConsume(oid);
                }
                _ = self.loaded_ids.orderedRemove(oid);
            },
            .vector, .struct_ => {
                for (value.data.vector) |field| try self.consumeTracked(field);
            },
            else => {},
        }
    }

    /// Storage opcodes require the transaction signer.
    /// A resource that already has an owner must belong to that signer.
    /// `storage_address` is set for loads: an unowned resource may only be
    /// loaded when that address is the signer. `move_to_sender` passes null
    /// so an unowned value held by this transaction can be published.
    pub fn requireSenderOwns(self: *Self, oid: ObjectID, storage_address: ?[32]u8) !void {
        const ctx = self.tx_context orelse return error.MissingSigner;
        const tracked = self.resource_tracker.get(oid) orelse return error.ResourceNotFound;
        if (tracked.owner) |owner| {
            if (!std.mem.eql(u8, &owner, &ctx.sender)) return error.NotResourceOwner;
            return;
        }
        if (storage_address) |addr| {
            if (!std.mem.eql(u8, &addr, &ctx.sender)) return error.NotResourceOwner;
        }
    }

    /// Load a tracked resource onto the value stack, keeping its ability tag.
    /// On failure the address operand is put back.
    fn takeTrackedResource(self: *Self, addr: Value) !Value {
        const resource_id = addr.data.address;
        var oid = ObjectID.zero;
        @memcpy(&oid.bytes, &resource_id);
        if (self.loaded_ids.contains(oid)) {
            try self.stack.append(self.allocator, addr);
            return error.InvalidResource;
        }
        const tracked = self.resource_tracker.get(oid) orelse {
            try self.stack.append(self.allocator, addr);
            return error.ResourceNotFound;
        };
        self.requireSenderOwns(oid, resource_id) catch |err| {
            try self.stack.append(self.allocator, addr);
            return err;
        };
        self.loaded_ids.put(self.allocator, oid, {}) catch |err| {
            try self.stack.append(self.allocator, addr);
            return err;
        };
        return .{
            .tag = .resource,
            .data = .{ .resource = .{ .id = resource_id, .type_tag = stackTypeTag(tracked.tag) } },
        };
    }

    /// `execute` advances `pc` after every instruction. A branch target is an
    /// absolute instruction index, so store one less and let that advance land
    /// on the target.
    fn jumpTo(self: *Self, payload: []const u8) !void {
        const target = std.mem.readInt(u16, payload[0..2], .big);
        if (target >= self.instructions.len) return error.InvalidInstructionPayload;
        self.pc = @as(usize, target) -% 1;
    }

    fn executeInstruction(self: *Self, instr: Bytecode.Instruction) !void {
        switch (instr.opcode) {
            .nop => {},
            .branch => {
                if (instr.payload.len < 2) return error.InvalidInstructionPayload;
                try self.jumpTo(instr.payload[0..2]);
                return;
            },
            .branch_if => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                if (instr.payload.len < 2) return error.InvalidInstructionPayload;
                const cond = self.stack.pop().?;
                if (cond.tag != .boolean) {
                    try self.stack.append(self.allocator, cond);
                    return error.TypeMismatch;
                }
                if (cond.data.bool) {
                    try self.jumpTo(instr.payload[0..2]);
                    return;
                }
            },
            .pop => {
                if (self.stack.items.len == 0) return error.StackUnderflow;
                const val = self.stack.pop().?;
                if (dropForbidden(val)) {
                    try self.stack.append(self.allocator, val);
                    return error.InvalidResource;
                }
                self.consumeTracked(val) catch |err| {
                    try self.stack.append(self.allocator, val);
                    return err;
                };
                var dropped = val;
                dropped.deinit(self.allocator);
            },
            .dup, .copy_resource => {
                try self.duplicateTop();
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
                if (overflow != 0) {
                    @branchHint(.cold);
                    return error.ArithmeticOverflow;
                }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
            },
            .sub => {
                const ints = try self.popTwoInts();
                const result, const overflow = @subWithOverflow(ints.a.data.int, ints.b.data.int);
                if (overflow != 0) {
                    @branchHint(.cold);
                    return error.ArithmeticOverflow;
                }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
            },
            .mul => {
                const ints = try self.popTwoInts();
                const result, const overflow = @mulWithOverflow(ints.a.data.int, ints.b.data.int);
                if (overflow != 0) {
                    @branchHint(.cold);
                    return error.ArithmeticOverflow;
                }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = result } });
            },
            .div => {
                const ints = try self.popTwoInts();
                if (ints.b.data.int == 0) {
                    @branchHint(.cold);
                    return error.DivisionByZero;
                }
                if (ints.a.data.int == std.math.minInt(i64) and ints.b.data.int == -1) {
                    @branchHint(.cold);
                    return error.ArithmeticOverflow;
                }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @divTrunc(ints.a.data.int, ints.b.data.int) } });
            },
            .mod => {
                const ints = try self.popTwoInts();
                if (ints.b.data.int == 0) {
                    @branchHint(.cold);
                    return error.DivisionByZero;
                }
                // @rem(minInt, -1) is safety-checked undefined behavior. The remainder is 0.
                if (ints.a.data.int == std.math.minInt(i64) and ints.b.data.int == -1) {
                    @branchHint(.cold);
                    try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = 0 } });
                } else {
                    try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = @rem(ints.a.data.int, ints.b.data.int) } });
                }
            },
            .neg => {
                const a = try self.popOneInt();
                const result, const overflow = @subWithOverflow(@as(i64, 0), a.data.int);
                if (overflow != 0) {
                    @branchHint(.cold);
                    return error.ArithmeticOverflow;
                }
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
                if (ints.b.data.int < 0 or ints.b.data.int >= 64) {
                    @branchHint(.cold);
                    return error.ArithmeticOverflow;
                }
                const shift = @as(u6, @intCast(ints.b.data.int));
                const shifted, const overflow = @shlWithOverflow(ints.a.data.int, shift);
                if (overflow != 0) {
                    @branchHint(.cold);
                    return error.ArithmeticOverflow;
                }
                try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = shifted } });
            },
            .shr => {
                const ints = try self.popTwoInts();
                if (ints.b.data.int < 0 or ints.b.data.int >= 64) {
                    @branchHint(.cold);
                    return error.ArithmeticOverflow;
                }
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
                if (!hasKeyAbility(resource)) {
                    try self.stack.append(self.allocator, destination);
                    try self.stack.append(self.allocator, resource);
                    return error.InvalidResource;
                }
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &resource.data.resource.id);
                try self.resource_tracker.recordMove(oid);
                _ = self.loaded_ids.orderedRemove(oid);
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
                if (!self.resource_tracker.isTracked(oid)) {
                    try self.stack.append(self.allocator, resource);
                    return error.ResourceNotFound;
                }
                self.requireSenderOwns(oid, null) catch |err| {
                    try self.stack.append(self.allocator, resource);
                    return err;
                };
                try self.resource_tracker.recordMove(oid);
                _ = self.loaded_ids.orderedRemove(oid);
            },
            .move_from => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const addr = self.stack.pop().?;
                if (addr.tag != .address) {
                    try self.stack.append(self.allocator, addr);
                    return error.TypeMismatch;
                }
                const loaded = try self.takeTrackedResource(addr);
                try self.stack.append(self.allocator, loaded);
            },
            .borrow_global => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const addr = self.stack.pop().?;
                if (addr.tag != .address) {
                    try self.stack.append(self.allocator, addr);
                    return error.TypeMismatch;
                }
                const loaded = try self.takeTrackedResource(addr);
                try self.stack.append(self.allocator, loaded);
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
                if (!hasDropAbility(resource)) {
                    try self.stack.append(self.allocator, resource);
                    return error.InvalidResource;
                }
                var oid = ObjectID.zero;
                @memcpy(&oid.bytes, &resource.data.resource.id);
                if (!self.resource_tracker.isTracked(oid)) {
                    try self.stack.append(self.allocator, resource);
                    return error.ResourceNotFound;
                }
                self.requireSenderOwns(oid, null) catch |err| {
                    try self.stack.append(self.allocator, resource);
                    return err;
                };
                try self.resource_tracker.recordConsume(oid);
                _ = self.loaded_ids.orderedRemove(oid);
            },
            .vec_len => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector) {
                    self.stack.append(self.allocator, vec) catch {
                        vec.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    return error.TypeMismatch;
                }
                if (@as(u128, vec.data.vector.len) > std.math.maxInt(i64)) {
                    self.stack.append(self.allocator, vec) catch {
                        vec.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    return error.ArithmeticOverflow;
                }
                const len: i64 = @intCast(vec.data.vector.len);
                self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = len } }) catch {
                    self.stack.append(self.allocator, vec) catch {
                        vec.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    return error.OutOfMemory;
                };
                vec.deinit(self.allocator);
            },
            .vec_push => {
                if (self.stack.items.len < 2) return error.StackUnderflow;
                const value = self.stack.pop().?;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector) {
                    self.stack.append(self.allocator, vec) catch {
                        vec.deinit(self.allocator);
                        value.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    self.stack.append(self.allocator, value) catch {
                        value.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    return error.TypeMismatch;
                }
                const new_vec = self.allocator.alloc(Value, vec.data.vector.len + 1) catch {
                    self.stack.append(self.allocator, vec) catch {
                        vec.deinit(self.allocator);
                        value.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    self.stack.append(self.allocator, value) catch {
                        value.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    return error.OutOfMemory;
                };
                @memcpy(new_vec[0..vec.data.vector.len], vec.data.vector);
                self.allocator.free(vec.data.vector);
                new_vec[vec.data.vector.len] = value;
                self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = new_vec } }) catch {
                    var owned = Value{ .tag = .vector, .data = .{ .vector = new_vec } };
                    owned.deinit(self.allocator);
                    return error.OutOfMemory;
                };
            },
            .vec_pop => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector) {
                    try self.stack.append(self.allocator, vec);
                    return error.TypeMismatch;
                }
                if (vec.data.vector.len == 0) {
                    try self.stack.append(self.allocator, vec);
                    return error.IndexOutOfBounds;
                }
                const new_vec = self.allocator.alloc(Value, vec.data.vector.len - 1) catch {
                    self.stack.append(self.allocator, vec) catch {
                        vec.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    return error.OutOfMemory;
                };
                @memcpy(new_vec, vec.data.vector[0 .. vec.data.vector.len - 1]);
                const popped = vec.data.vector[vec.data.vector.len - 1];
                self.stack.append(self.allocator, popped) catch {
                    self.allocator.free(new_vec);
                    self.stack.append(self.allocator, vec) catch {
                        vec.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    return error.OutOfMemory;
                };
                self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = new_vec } }) catch {
                    _ = self.stack.pop();
                    self.allocator.free(new_vec);
                    self.stack.append(self.allocator, vec) catch {
                        vec.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                    return error.OutOfMemory;
                };
                self.allocator.free(vec.data.vector);
            },
            .vec_pack => {
                const MAX_VEC_PACK: u32 = 4096;
                var count: u32 = 0;
                var consumed_count_from_stack = false;

                if (self.stack.items.len > 0) {
                    const top = self.stack.items[self.stack.items.len - 1];
                    if (top.tag == .integer and top.data.int >= 0) {
                        if (top.data.int > MAX_VEC_PACK) return error.InvalidInstructionPayload;
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
                if (self.stack.items.len < count) {
                    if (consumed_count_from_stack) {
                        try self.stack.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = count } });
                    }
                    return error.StackUnderflow;
                }
                {
                    var elems = try std.ArrayList(Value).initCapacity(self.allocator, count);
                    for (0..count) |_| {
                        const item = self.stack.pop().?;
                        elems.append(self.allocator, item) catch |err| {
                            item.deinit(self.allocator);
                            for (elems.items) |*elem| elem.deinit(self.allocator);
                            elems.deinit(self.allocator);
                            return err;
                        };
                    }
                    std.mem.reverse(Value, elems.items);
                    const vec = elems.toOwnedSlice(self.allocator) catch |err| {
                        for (elems.items) |*elem| elem.deinit(self.allocator);
                        elems.deinit(self.allocator);
                        return err;
                    };
                    self.stack.append(self.allocator, Value{ .tag = .vector, .data = .{ .vector = vec } }) catch {
                        var owned = Value{ .tag = .vector, .data = .{ .vector = vec } };
                        owned.deinit(self.allocator);
                        return error.OutOfMemory;
                    };
                }
            },
            .vec_unpack => {
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const vec = self.stack.pop().?;
                if (vec.tag != .vector) {
                    try self.stack.append(self.allocator, vec);
                    return error.TypeMismatch;
                }
                const before = self.stack.items.len;
                for (vec.data.vector) |elem| {
                    self.stack.append(self.allocator, elem) catch {
                        self.stack.shrinkRetainingCapacity(before);
                        self.stack.append(self.allocator, vec) catch {
                            vec.deinit(self.allocator);
                            return error.OutOfMemory;
                        };
                        return error.OutOfMemory;
                    };
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
                if (index.data.int < 0 or @as(usize, @intCast(index.data.int)) >= vec.data.vector.len) {
                    self.stack.append(self.allocator, vec) catch |err| {
                        vec.deinit(self.allocator);
                        return err;
                    };
                    return error.IndexOutOfBounds;
                }
                const idx: usize = @intCast(index.data.int);
                if (copyForbidden(vec.data.vector[idx])) {
                    self.stack.append(self.allocator, vec) catch |err| {
                        vec.deinit(self.allocator);
                        return err;
                    };
                    return error.InvalidResource;
                }
                const borrowed = try vec.data.vector[idx].clone(self.allocator);
                self.stack.append(self.allocator, vec) catch |err| {
                    borrowed.deinit(self.allocator);
                    vec.deinit(self.allocator);
                    return err;
                };
                self.stack.append(self.allocator, borrowed) catch |err| {
                    borrowed.deinit(self.allocator);
                    return err;
                };
            },
            .ld_loc => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                const idx: usize = instr.payload[0];
                if (idx >= self.locals.items.len) return error.InvalidLocalIndex;
                if (copyForbidden(self.locals.items[idx])) return error.InvalidResource;
                const val = try self.locals.items[idx].clone(self.allocator);
                self.stack.append(self.allocator, val) catch |err| {
                    val.deinit(self.allocator);
                    return err;
                };
            },
            .st_loc => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                if (self.stack.items.len < 1) return error.StackUnderflow;
                const val = self.stack.pop().?;
                const idx: usize = instr.payload[0];
                while (self.locals.items.len <= idx) {
                    self.locals.append(self.allocator, Value{ .tag = .integer, .data = .{ .int = 0 } }) catch |err| {
                        self.stack.append(self.allocator, val) catch {
                            val.deinit(self.allocator);
                            return err;
                        };
                        return err;
                    };
                }
                if (dropForbidden(self.locals.items[idx])) {
                    try self.stack.append(self.allocator, val);
                    return error.InvalidResource;
                }
                const old = self.locals.items[idx];
                self.locals.items[idx] = val;
                self.consumeTracked(old) catch |err| {
                    self.locals.items[idx] = old;
                    try self.stack.append(self.allocator, val);
                    return err;
                };
                var dropped = old;
                dropped.deinit(self.allocator);
            },
            .pack => {
                if (instr.payload.len < 1) return error.InvalidInstructionPayload;
                const field_count: usize = instr.payload[0];
                if (self.stack.items.len < field_count) return error.StackUnderflow;
                // The struct owns this buffer. Releasing it here would dangle the stack value.
                const fields = try self.allocator.alloc(Value, field_count);
                var owned = true;
                errdefer if (owned) {
                    for (fields) |field| field.deinit(self.allocator);
                    self.allocator.free(fields);
                };
                var i: usize = field_count;
                while (i > 0) {
                    i -= 1;
                    fields[i] = self.stack.pop().?;
                }
                try self.stack.append(self.allocator, Value{ .tag = .struct_, .data = .{ .vector = fields } });
                owned = false;
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
                if (field_idx >= s.data.vector.len) {
                    self.stack.append(self.allocator, s) catch |err| {
                        s.deinit(self.allocator);
                        return err;
                    };
                    return error.IndexOutOfBounds;
                }
                if (copyForbidden(s.data.vector[field_idx])) {
                    self.stack.append(self.allocator, s) catch |err| {
                        s.deinit(self.allocator);
                        return err;
                    };
                    return error.InvalidResource;
                }
                const field = try s.data.vector[field_idx].clone(self.allocator);
                self.stack.append(self.allocator, s) catch |err| {
                    field.deinit(self.allocator);
                    s.deinit(self.allocator);
                    return err;
                };
                self.stack.append(self.allocator, field) catch |err| {
                    field.deinit(self.allocator);
                    return err;
                };
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
                if (field_idx >= s.data.vector.len) {
                    self.stack.append(self.allocator, s) catch |err| {
                        s.deinit(self.allocator);
                        return err;
                    };
                    return error.IndexOutOfBounds;
                }
                if (copyForbidden(s.data.vector[field_idx])) {
                    self.stack.append(self.allocator, s) catch |err| {
                        s.deinit(self.allocator);
                        return err;
                    };
                    return error.InvalidResource;
                }
                const field = try s.data.vector[field_idx].clone(self.allocator);
                self.stack.append(self.allocator, s) catch |err| {
                    field.deinit(self.allocator);
                    s.deinit(self.allocator);
                    return err;
                };
                self.stack.append(self.allocator, field) catch |err| {
                    field.deinit(self.allocator);
                    return err;
                };
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
        // Clones are released on every exit, including a failed native.
        const native_args = try self.allocator.alloc(Value, arg_count);
        var cloned: usize = 0;
        var args_live = true;
        errdefer if (args_live) {
            for (native_args[0..cloned]) |*arg| arg.deinit(self.allocator);
            self.allocator.free(native_args);
        };
        for (0..arg_count) |i| {
            native_args[i] = try self.stack.items[args_start + i].clone(self.allocator);
            cloned += 1;
        }

        const native = reg.resolve(module_name, func_name) orelse return error.UnimplementedInstruction;
        const result = native(self, native_args) catch |err| switch (err) {
            error.InvalidArgumentCount => return error.InvalidArgumentCount,
            error.TypeMismatch => return error.TypeMismatch,
            error.ResourceNotFound => return error.ResourceNotFound,
            error.NotResourceOwner => return error.NotResourceOwner,
            error.MissingSigner => return error.MissingSigner,
            error.OutOfMemory => return error.OutOfMemory,
            error.UnimplementedNative => return error.UnimplementedInstruction,
            error.ArithmeticOverflow => return error.ArithmeticOverflow,
        };

        for (native_args[0..cloned]) |*arg| arg.deinit(self.allocator);
        self.allocator.free(native_args);
        args_live = false;
        // Remove original args from stack
        for (self.stack.items[args_start..]) |*arg| arg.deinit(self.allocator);
        self.stack.shrinkRetainingCapacity(args_start);
        errdefer result.deinit(self.allocator);
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

fn testInterpreter(allocator: std.mem.Allocator, gas: *Gas.GasMeter, tracker: *Resource.ResourceTracker) !*Interpreter {
    return Interpreter.init(allocator, gas, tracker);
}

test "move_to_sender refuses a missing signer and a foreign owner" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    const sender: [32]u8 = @splat(0x11);
    const other: [32]u8 = @splat(0x22);
    const oid = ObjectID{ .bytes = sender };
    const resource = try Resource.Resource.init(oid, .Coin, "1", other, allocator);
    try tracker.track(resource);

    var interpreter = try testInterpreter(allocator, &gas, &tracker);
    defer interpreter.deinit();
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = oid.bytes, .type_tag = 0 } },
    });
    const module = Bytecode.VerifiedModule{
        .name = "own",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .move_to_sender, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.MissingSigner, interpreter.execute(module));
    try std.testing.expect(tracker.isTracked(oid));

    var ctx = TxContext{
        .sender = sender,
        .tx_hash = @splat(0),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interpreter.tx_context = &ctx;
    interpreter.pc = 0;
    try std.testing.expectError(error.NotResourceOwner, interpreter.execute(module));
    try std.testing.expect(tracker.isTracked(oid));
}

test "move_to_sender publishes the signer's resource and move_from rejects another address" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    const sender: [32]u8 = @splat(0x11);
    const oid = ObjectID{ .bytes = @as([32]u8, @splat(0x44)) };
    const owned = try Resource.Resource.init(oid, .Coin, "1", sender, allocator);
    tracker.track(owned) catch |err| {
        owned.deinit(allocator);
        allocator.destroy(owned);
        return err;
    };

    var ctx = TxContext{
        .sender = sender,
        .tx_hash = @splat(1),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    var interpreter = try testInterpreter(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.tx_context = &ctx;
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = oid.bytes, .type_tag = 0 } },
    });
    const publish = Bytecode.VerifiedModule{
        .name = "publish",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .move_to_sender, .payload = &.{} },
        },
        .local_count = 0,
    };
    _ = try interpreter.execute(publish);
    try std.testing.expect(tracker.wasMoved(oid));

    const foreign = ObjectID{ .bytes = @as([32]u8, @splat(0x55)) };
    const foreign_res = try Resource.Resource.init(foreign, .Coin, "1", @as([32]u8, @splat(0x22)), allocator);
    try tracker.track(foreign_res);
    try interpreter.stack.append(allocator, .{
        .tag = .address,
        .data = .{ .address = foreign.bytes },
    });
    const load = Bytecode.VerifiedModule{
        .name = "load",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .move_from, .payload = &.{} },
        },
        .local_count = 0,
    };
    interpreter.pc = 0;
    try std.testing.expectError(error.NotResourceOwner, interpreter.execute(load));
    try std.testing.expect(tracker.isTracked(foreign));
}

test "delete_resource refuses a foreign owner and consumes the signer's resource" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    const sender: [32]u8 = @splat(0x11);
    const foreign_id = ObjectID{ .bytes = @as([32]u8, @splat(0x55)) };
    const foreign = try Resource.Resource.init(foreign_id, .Coin, "1", @as([32]u8, @splat(0x22)), allocator);
    try tracker.track(foreign);

    var ctx = TxContext{
        .sender = sender,
        .tx_hash = @splat(3),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    var interpreter = try testInterpreter(allocator, &gas, &tracker);
    defer interpreter.deinit();
    interpreter.tx_context = &ctx;
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = foreign_id.bytes, .type_tag = 1 } },
    });
    const delete_foreign = Bytecode.VerifiedModule{
        .name = "delete-foreign",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .delete_resource, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.NotResourceOwner, interpreter.execute(delete_foreign));
    try std.testing.expect(tracker.isTracked(foreign_id));

    const owned_id = ObjectID{ .bytes = @as([32]u8, @splat(0x66)) };
    const owned = try Resource.Resource.init(owned_id, .Coin, "1", sender, allocator);
    try tracker.track(owned);
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = owned_id.bytes, .type_tag = 1 } },
    });
    const delete_owned = Bytecode.VerifiedModule{
        .name = "delete-owned",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .delete_resource, .payload = &.{} },
        },
        .local_count = 0,
    };
    interpreter.pc = 0;
    _ = try interpreter.execute(delete_owned);
    try std.testing.expect(tracker.wasConsumed(owned_id));
    try std.testing.expect(!tracker.isTracked(owned_id));
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

fn u64Payload(comptime value: u64) [8]u8 {
    var bytes: [8]u8 = @splat(0);
    std.mem.writeInt(u64, &bytes, value, .little);
    return bytes;
}

test "vec_len releases the vector and vec_borrow keeps it" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const one = u64Payload(1);
    const seven = u64Payload(7);
    const len_module = Bytecode.VerifiedModule{
        .name = "vec_len",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &seven },
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .vec_pack, .payload = &.{ 1, 0, 0, 0 } },
            .{ .opcode = .vec_len, .payload = &.{} },
        },
        .local_count = 0,
    };
    const len_result = try interpreter.execute(len_module);
    defer if (len_result.return_value) |rv| rv.deinit(allocator);
    const len_value = len_result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(Value.ValueTag.integer, len_value.tag);
    try std.testing.expectEqual(@as(i64, 1), len_value.data.int);

    interpreter.pc = 0;
    const nine = u64Payload(9);
    const zero = u64Payload(0);
    const borrow_module = Bytecode.VerifiedModule{
        .name = "vec_borrow",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &nine },
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .vec_pack, .payload = &.{ 1, 0, 0, 0 } },
            .{ .opcode = .ld_u64, .payload = &zero },
            .{ .opcode = .vec_borrow, .payload = &.{} },
        },
        .local_count = 0,
    };
    const borrowed = try interpreter.execute(borrow_module);
    defer if (borrowed.return_value) |rv| rv.deinit(allocator);
    const borrowed_value = borrowed.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(@as(i64, 9), borrowed_value.data.int);
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.vector, interpreter.stack.items[0].tag);
}

test "vec_pop and vec_borrow restore the vector on an out-of-range index" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const zero = u64Payload(0);
    const empty_pop = Bytecode.VerifiedModule{
        .name = "empty_pop",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &zero },
            .{ .opcode = .vec_pack, .payload = &.{ 0, 0, 0, 0 } },
            .{ .opcode = .vec_pop, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.IndexOutOfBounds, interpreter.execute(empty_pop));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);

    for (interpreter.stack.items) |v| v.deinit(allocator);
    interpreter.stack.clearRetainingCapacity();
    interpreter.pc = 0;

    const nine = u64Payload(9);
    const one = u64Payload(1);
    const oob = Bytecode.VerifiedModule{
        .name = "oob_borrow",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &nine },
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .vec_pack, .payload = &.{ 1, 0, 0, 0 } },
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .vec_borrow, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.IndexOutOfBounds, interpreter.execute(oob));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.vector, interpreter.stack.items[0].tag);
}

test "pack retains the struct and borrow_field clones its fields" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const seven = u64Payload(7);
    const one = u64Payload(1);
    const four = u64Payload(4);
    const packed_module = Bytecode.VerifiedModule{
        .name = "pack_borrow",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &seven },
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .vec_pack, .payload = &.{ 1, 0, 0, 0 } },
            .{ .opcode = .ld_u64, .payload = &four },
            .{ .opcode = .pack, .payload = &.{2} },
            .{ .opcode = .borrow_field, .payload = &.{0} },
        },
        .local_count = 0,
    };
    const borrowed = try interpreter.execute(packed_module);
    defer if (borrowed.return_value) |rv| rv.deinit(allocator);
    const field = borrowed.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(Value.ValueTag.vector, field.tag);
    try std.testing.expectEqual(@as(i64, 7), field.data.vector[0].data.int);
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.struct_, interpreter.stack.items[0].tag);
    try std.testing.expect(field.data.vector.ptr != interpreter.stack.items[0].data.vector[0].data.vector.ptr);

    for (interpreter.stack.items) |v| v.deinit(allocator);
    interpreter.stack.clearRetainingCapacity();
    interpreter.pc = 0;
    const oob = Bytecode.VerifiedModule{
        .name = "pack_oob",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &four },
            .{ .opcode = .pack, .payload = &.{1} },
            .{ .opcode = .borrow_field, .payload = &.{5} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.IndexOutOfBounds, interpreter.execute(oob));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.struct_, interpreter.stack.items[0].tag);
}

test "branch lands on the target instruction" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const one = u64Payload(1);
    const two = u64Payload(2);
    const four = u64Payload(4);
    const nine = u64Payload(9);
    const to_three = [2]u8{ 0, 3 };
    const to_two = [2]u8{ 0, 2 };
    const taken = Bytecode.VerifiedModule{
        .name = "branch_taken",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_true, .payload = &.{} },
            .{ .opcode = .branch_if, .payload = &to_three },
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .ld_u64, .payload = &two },
        },
        .local_count = 0,
    };
    const taken_result = try interpreter.execute(taken);
    defer if (taken_result.return_value) |rv| rv.deinit(allocator);
    const taken_value = taken_result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(@as(i64, 2), taken_value.data.int);

    const skipped = Bytecode.VerifiedModule{
        .name = "branch_skip",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .branch, .payload = &to_two },
            .{ .opcode = .ld_u64, .payload = &nine },
            .{ .opcode = .ld_u64, .payload = &four },
        },
        .local_count = 0,
    };
    const skipped_result = try interpreter.execute(skipped);
    defer if (skipped_result.return_value) |rv| rv.deinit(allocator);
    const skipped_value = skipped_result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(@as(i64, 4), skipped_value.data.int);

    const fallthrough = Bytecode.VerifiedModule{
        .name = "branch_fallthrough",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_false, .payload = &.{} },
            .{ .opcode = .branch_if, .payload = &to_three },
            .{ .opcode = .ld_u64, .payload = &four },
        },
        .local_count = 0,
    };
    const fallthrough_result = try interpreter.execute(fallthrough);
    defer if (fallthrough_result.return_value) |rv| rv.deinit(allocator);
    const fallthrough_value = fallthrough_result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(@as(i64, 4), fallthrough_value.data.int);

    const vector = Bytecode.VerifiedModule{
        .name = "branch_vector",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .vec_pack, .payload = &.{ 1, 0, 0, 0 } },
            .{ .opcode = .branch_if, .payload = &to_two },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.TypeMismatch, interpreter.execute(vector));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.vector, interpreter.stack.items[0].tag);
}

test "dup refuses a resource without copy and duplicates a copyable one" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const coin = Value{
        .tag = .resource,
        .data = .{ .resource = .{ .id = @as([32]u8, @splat(0x11)), .type_tag = 1 } },
    };
    try interpreter.stack.append(allocator, coin);
    const refuse = Bytecode.VerifiedModule{
        .name = "dup_coin",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .dup, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.InvalidResource, interpreter.execute(refuse));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);

    interpreter.stack.clearRetainingCapacity();
    const token = Value{
        .tag = .resource,
        .data = .{ .resource = .{ .id = @as([32]u8, @splat(0x22)), .type_tag = 2 } },
    };
    try interpreter.stack.append(allocator, token);
    const allow = Bytecode.VerifiedModule{
        .name = "copy_token",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .copy_resource, .payload = &.{} },
        },
        .local_count = 0,
    };
    const copied = try interpreter.execute(allow);
    defer if (copied.return_value) |rv| rv.deinit(allocator);
    const copied_value = copied.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(Value.ValueTag.resource, copied_value.tag);
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.resource, interpreter.stack.items[0].tag);
}

test "pop and delete_resource keep a resource that cannot be dropped" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    const sender: [32]u8 = @splat(0x31);
    const shared_id = ObjectID{ .bytes = @as([32]u8, @splat(0x41)) };
    const shared = try Resource.Resource.init(shared_id, .Coin, "1", sender, allocator);
    try tracker.track(shared);

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = shared_id.bytes, .type_tag = 4 } },
    });
    const pop_shared = Bytecode.VerifiedModule{
        .name = "pop_shared",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .pop, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.InvalidResource, interpreter.execute(pop_shared));
    try std.testing.expect(tracker.isTracked(shared_id));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);

    interpreter.stack.clearRetainingCapacity();
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = shared_id.bytes, .type_tag = 4 } },
    });
    const delete_shared = Bytecode.VerifiedModule{
        .name = "delete_shared",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .delete_resource, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.InvalidResource, interpreter.execute(delete_shared));
    try std.testing.expect(tracker.isTracked(shared_id));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);

    interpreter.stack.clearRetainingCapacity();
    const coin_id = ObjectID{ .bytes = @as([32]u8, @splat(0x42)) };
    const coin = try Resource.Resource.init(coin_id, .Coin, "1", sender, allocator);
    try tracker.track(coin);
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = coin_id.bytes, .type_tag = 1 } },
    });
    const pop_coin = Bytecode.VerifiedModule{
        .name = "pop_coin",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .pop, .payload = &.{} },
        },
        .local_count = 0,
    };
    _ = try interpreter.execute(pop_coin);
    try std.testing.expect(tracker.wasConsumed(coin_id));
    try std.testing.expectEqual(@as(usize, 0), interpreter.stack.items.len);
}

test "load and duplicate refuse a struct that holds a linear resource" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const linear = Value{
        .tag = .resource,
        .data = .{ .resource = .{ .id = @as([32]u8, @splat(0x51)), .type_tag = 1 } },
    };
    try interpreter.stack.append(allocator, linear);
    const load = Bytecode.VerifiedModule{
        .name = "load_linear",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .st_loc, .payload = &.{0} },
            .{ .opcode = .ld_loc, .payload = &.{0} },
        },
        .local_count = 1,
    };
    try std.testing.expectError(error.InvalidResource, interpreter.execute(load));
    try std.testing.expectEqual(@as(usize, 0), interpreter.stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), interpreter.locals.items.len);
    try std.testing.expectEqual(Value.ValueTag.resource, interpreter.locals.items[0].tag);

    try interpreter.stack.append(allocator, linear);
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 7 } });
    const duplicate = Bytecode.VerifiedModule{
        .name = "dup_struct",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .pack, .payload = &.{2} },
            .{ .opcode = .dup, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.InvalidResource, interpreter.execute(duplicate));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.struct_, interpreter.stack.items[0].tag);
}

test "st_loc refuses to overwrite a resource that cannot be dropped" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    const sender: [32]u8 = @splat(0x61);
    const shared_id = ObjectID{ .bytes = @as([32]u8, @splat(0x71)) };
    const shared = try Resource.Resource.init(shared_id, .Coin, "1", sender, allocator);
    try tracker.track(shared);

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 9 } });
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = shared_id.bytes, .type_tag = 4 } },
    });
    const keep = Bytecode.VerifiedModule{
        .name = "keep_local",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .st_loc, .payload = &.{0} },
            .{ .opcode = .st_loc, .payload = &.{0} },
        },
        .local_count = 1,
    };
    try std.testing.expectError(error.InvalidResource, interpreter.execute(keep));
    try std.testing.expect(tracker.isTracked(shared_id));
    try std.testing.expectEqual(Value.ValueTag.resource, interpreter.locals.items[0].tag);
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(@as(i64, 9), interpreter.stack.items[0].data.int);

    interpreter.stack.clearRetainingCapacity();
    const coin_id = ObjectID{ .bytes = @as([32]u8, @splat(0x72)) };
    const coin = try Resource.Resource.init(coin_id, .Coin, "1", sender, allocator);
    try tracker.track(coin);
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 3 } });
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = coin_id.bytes, .type_tag = 1 } },
    });
    const replace = Bytecode.VerifiedModule{
        .name = "replace_local",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .st_loc, .payload = &.{1} },
            .{ .opcode = .st_loc, .payload = &.{1} },
        },
        .local_count = 2,
    };
    _ = try interpreter.execute(replace);
    try std.testing.expect(tracker.wasConsumed(coin_id));
    try std.testing.expectEqual(Value.ValueTag.integer, interpreter.locals.items[1].tag);
}

test "move_from keeps the tracked resource type" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    const sender: [32]u8 = @splat(0x81);
    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    var ctx = TxContext{
        .sender = sender,
        .tx_hash = @splat(1),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interpreter.tx_context = &ctx;

    const missing = ObjectID{ .bytes = @as([32]u8, @splat(0x91)) };
    try interpreter.stack.append(allocator, .{ .tag = .address, .data = .{ .address = missing.bytes } });
    const missing_load = Bytecode.VerifiedModule{
        .name = "missing_load",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .move_from, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.ResourceNotFound, interpreter.execute(missing_load));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.address, interpreter.stack.items[0].tag);

    interpreter.stack.clearRetainingCapacity();
    const coin_id = ObjectID{ .bytes = @as([32]u8, @splat(0x92)) };
    const coin = try Resource.Resource.init(coin_id, .Coin, "1", sender, allocator);
    try tracker.track(coin);
    try interpreter.stack.append(allocator, .{ .tag = .address, .data = .{ .address = coin_id.bytes } });
    const load_and_drop = Bytecode.VerifiedModule{
        .name = "load_and_drop",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .move_from, .payload = &.{} },
            .{ .opcode = .delete_resource, .payload = &.{} },
        },
        .local_count = 0,
    };
    _ = try interpreter.execute(load_and_drop);
    try std.testing.expect(tracker.wasConsumed(coin_id));

    const shared_id = ObjectID{ .bytes = @as([32]u8, @splat(0x93)) };
    const shared = try Resource.Resource.init(shared_id, .SharedObject, "1", sender, allocator);
    try tracker.track(shared);
    try interpreter.stack.append(allocator, .{ .tag = .address, .data = .{ .address = shared_id.bytes } });
    const borrow_shared = Bytecode.VerifiedModule{
        .name = "borrow_shared",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .borrow_global, .payload = &.{} },
            .{ .opcode = .pop, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.InvalidResource, interpreter.execute(borrow_shared));
    try std.testing.expect(tracker.isTracked(shared_id));
    try std.testing.expectEqual(Value.ValueTag.resource, interpreter.stack.items[0].tag);
    try std.testing.expectEqual(@as(u8, 4), interpreter.stack.items[0].data.resource.type_tag);
}

test "move_from refuses a resource that is already loaded" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    const sender: [32]u8 = @splat(0xA1);
    const coin_id = ObjectID{ .bytes = @as([32]u8, @splat(0xB1)) };
    const coin = try Resource.Resource.init(coin_id, .Coin, "1", sender, allocator);
    try tracker.track(coin);

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    var ctx = TxContext{
        .sender = sender,
        .tx_hash = @splat(2),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interpreter.tx_context = &ctx;
    try interpreter.stack.append(allocator, .{ .tag = .address, .data = .{ .address = coin_id.bytes } });
    const once = Bytecode.VerifiedModule{
        .name = "load_once",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .move_from, .payload = &.{} },
        },
        .local_count = 0,
    };
    const first = try interpreter.execute(once);
    defer if (first.return_value) |rv| rv.deinit(allocator);
    const loaded = first.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(Value.ValueTag.resource, loaded.tag);

    try interpreter.stack.append(allocator, .{ .tag = .address, .data = .{ .address = coin_id.bytes } });
    try std.testing.expectError(error.InvalidResource, interpreter.execute(once));
    try std.testing.expect(tracker.isTracked(coin_id));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(Value.ValueTag.address, interpreter.stack.items[0].tag);
}

test "execution records a resource id nested in a returned struct" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const object_id: [32]u8 = @splat(0xC1);
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = object_id, .type_tag = 1 } },
    });
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 1 } });
    const module = Bytecode.VerifiedModule{
        .name = "return_struct",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .pack, .payload = &.{2} },
        },
        .local_count = 0,
    };
    const result = try interpreter.execute(module);
    defer if (result.return_value) |rv| rv.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.output_objects.len);
    try std.testing.expectEqualSlices(u8, &object_id, &result.output_objects[0]);

    const second_id: [32]u8 = @splat(0xC2);
    try interpreter.stack.append(allocator, .{
        .tag = .resource,
        .data = .{ .resource = .{ .id = second_id, .type_tag = 1 } },
    });
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 2 } });
    const again = try interpreter.execute(module);
    defer if (again.return_value) |rv| rv.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), again.output_objects.len);
    try std.testing.expectEqualSlices(u8, &second_id, &again.output_objects[0]);
}

test "the next execution drops locals from the previous one" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const seven = u64Payload(7);
    const one = u64Payload(1);
    const store = Bytecode.VerifiedModule{
        .name = "store_local",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_u64, .payload = &seven },
            .{ .opcode = .ld_u64, .payload = &one },
            .{ .opcode = .vec_pack, .payload = &.{ 1, 0, 0, 0 } },
            .{ .opcode = .st_loc, .payload = &.{0} },
        },
        .local_count = 1,
    };
    const stored = try interpreter.execute(store);
    defer if (stored.return_value) |rv| rv.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), interpreter.locals.items.len);

    const next = Bytecode.VerifiedModule{
        .name = "next",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .ld_true, .payload = &.{} },
        },
        .local_count = 0,
    };
    const followed = try interpreter.execute(next);
    defer if (followed.return_value) |rv| rv.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), interpreter.locals.items.len);
    const value = followed.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(Value.ValueTag.boolean, value.tag);
}

test "mod of the minimum integer by negative one is zero" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = std.math.minInt(i64) } });
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = -1 } });
    const module = Bytecode.VerifiedModule{
        .name = "mod_min",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .mod, .payload = &.{} },
        },
        .local_count = 0,
    };
    const result = try interpreter.execute(module);
    defer if (result.return_value) |rv| rv.deinit(allocator);
    const remainder = result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(@as(i64, 0), remainder.data.int);
}

test "shl reports overflow when the signed result does not fit" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 4 } });
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 1 } });
    const shift_one = Bytecode.VerifiedModule{
        .name = "shl_ok",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .shl, .payload = &.{} },
        },
        .local_count = 0,
    };
    const shifted = try interpreter.execute(shift_one);
    defer if (shifted.return_value) |rv| rv.deinit(allocator);
    const value = shifted.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(@as(i64, 8), value.data.int);

    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 1 } });
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 63 } });
    const shift_far = Bytecode.VerifiedModule{
        .name = "shl_overflow",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .shl, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.ArithmeticOverflow, interpreter.execute(shift_far));
}

test "vec_pack rejects a count that does not fit the pack limit" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = std.math.maxInt(i64) } });
    const too_big = Bytecode.VerifiedModule{
        .name = "pack_too_big",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .vec_pack, .payload = &.{ 0, 0, 0, 0 } },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.InvalidInstructionPayload, interpreter.execute(too_big));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(std.math.maxInt(i64), interpreter.stack.items[0].data.int);

    interpreter.stack.clearRetainingCapacity();
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 2 } });
    const short = Bytecode.VerifiedModule{
        .name = "pack_short",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .vec_pack, .payload = &.{ 0, 0, 0, 0 } },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.StackUnderflow, interpreter.execute(short));
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(@as(i64, 2), interpreter.stack.items[0].data.int);
}

test "vec_unpack moves elements onto the stack and frees the vector buffer" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const elems = try allocator.alloc(Value, 2);
    elems[0] = .{ .tag = .integer, .data = .{ .int = 1 } };
    elems[1] = .{ .tag = .integer, .data = .{ .int = 2 } };
    try interpreter.stack.append(allocator, .{ .tag = .vector, .data = .{ .vector = elems } });

    const module = Bytecode.VerifiedModule{
        .name = "unpack",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .vec_unpack, .payload = &.{} },
        },
        .local_count = 0,
    };
    const result = try interpreter.execute(module);
    defer if (result.return_value) |rv| rv.deinit(allocator);
    const top = result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(@as(i64, 2), top.data.int);
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(@as(i64, 1), interpreter.stack.items[0].data.int);
}

test "vec_pop returns the shortened vector and leaves the last element" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const elems = try allocator.alloc(Value, 2);
    elems[0] = .{ .tag = .integer, .data = .{ .int = 1 } };
    elems[1] = .{ .tag = .integer, .data = .{ .int = 2 } };
    try interpreter.stack.append(allocator, .{ .tag = .vector, .data = .{ .vector = elems } });

    const module = Bytecode.VerifiedModule{
        .name = "pop_vec",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .vec_pop, .payload = &.{} },
        },
        .local_count = 0,
    };
    const result = try interpreter.execute(module);
    defer if (result.return_value) |rv| rv.deinit(allocator);
    const shortened = result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(Value.ValueTag.vector, shortened.tag);
    try std.testing.expectEqual(@as(usize, 1), shortened.data.vector.len);
    try std.testing.expectEqual(@as(i64, 1), shortened.data.vector[0].data.int);
    try std.testing.expectEqual(@as(usize, 1), interpreter.stack.items.len);
    try std.testing.expectEqual(@as(i64, 2), interpreter.stack.items[0].data.int);
}

test "vec_push appends the value and keeps every element" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const elems = try allocator.alloc(Value, 2);
    elems[0] = .{ .tag = .integer, .data = .{ .int = 1 } };
    elems[1] = .{ .tag = .integer, .data = .{ .int = 2 } };
    try interpreter.stack.append(allocator, .{ .tag = .vector, .data = .{ .vector = elems } });
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 3 } });

    const module = Bytecode.VerifiedModule{
        .name = "push_vec",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .vec_push, .payload = &.{} },
        },
        .local_count = 0,
    };
    const result = try interpreter.execute(module);
    defer if (result.return_value) |rv| rv.deinit(allocator);
    const pushed = result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(Value.ValueTag.vector, pushed.tag);
    try std.testing.expectEqual(@as(usize, 3), pushed.data.vector.len);
    try std.testing.expectEqual(@as(i64, 1), pushed.data.vector[0].data.int);
    try std.testing.expectEqual(@as(i64, 2), pushed.data.vector[1].data.int);
    try std.testing.expectEqual(@as(i64, 3), pushed.data.vector[2].data.int);
    try std.testing.expectEqual(@as(usize, 0), interpreter.stack.items.len);
}

test "vec_pack keeps element order" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 1 } });
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 2 } });
    try interpreter.stack.append(allocator, .{ .tag = .integer, .data = .{ .int = 2 } });

    const module = Bytecode.VerifiedModule{
        .name = "pack_vec",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .vec_pack, .payload = &.{ 0, 0, 0, 0 } },
        },
        .local_count = 0,
    };
    const result = try interpreter.execute(module);
    defer if (result.return_value) |rv| rv.deinit(allocator);
    const packed_vec = result.return_value orelse return error.MissingReturn;
    try std.testing.expectEqual(Value.ValueTag.vector, packed_vec.tag);
    try std.testing.expectEqual(@as(usize, 2), packed_vec.data.vector.len);
    try std.testing.expectEqual(@as(i64, 1), packed_vec.data.vector[0].data.int);
    try std.testing.expectEqual(@as(i64, 2), packed_vec.data.vector[1].data.int);
    try std.testing.expectEqual(@as(usize, 0), interpreter.stack.items.len);
}

test "vec_len refuses a length that does not fit in i64" {
    const allocator = std.testing.allocator;
    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    var anchor = Value{ .tag = .integer, .data = .{ .int = 1 } };
    const ptr: [*]Value = @ptrCast(&anchor);
    const forged: []Value = ptr[0 .. @as(usize, std.math.maxInt(i64)) + 1];
    try interpreter.stack.append(allocator, .{ .tag = .vector, .data = .{ .vector = forged } });

    const module = Bytecode.VerifiedModule{
        .name = "len_overflow",
        .instructions = &[_]Bytecode.Instruction{
            .{ .opcode = .vec_len, .payload = &.{} },
        },
        .local_count = 0,
    };
    try std.testing.expectError(error.ArithmeticOverflow, interpreter.execute(module));
    const restored = interpreter.stack.pop().?;
    try std.testing.expectEqual(Value.ValueTag.vector, restored.tag);
    try std.testing.expect(restored.data.vector.len > std.math.maxInt(i64));
}
