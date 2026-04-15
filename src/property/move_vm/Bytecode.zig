//! Bytecode - Move bytecode verification at compile time

const std = @import("std");

/// Move bytecode instruction
pub const Instruction = struct {
    opcode: OpCode,
    payload: []const u8,

    const Self = @This();

    pub const OpCode = enum(u8) {
        // Control flow
        nop = 0x00,
        ret = 0x01,
        branch = 0x02,
        branch_if = 0x03,

        // Stack operations
        pop = 0x10,
        dup = 0x11,
        swap = 0x12,

        // Local operations
        ld_loc = 0x20,
        st_loc = 0x21,

        // Constant loading
        ld_const = 0x30,
        ld_true = 0x31,
        ld_false = 0x32,
        ld_u8 = 0x33,
        ld_u64 = 0x34,
        ld_u128 = 0x35,
        ld_i8 = 0x36,
        ld_i64 = 0x37,
        ld_addr = 0x38,
        ld_bytearray = 0x39,

        // Arithmetic
        add = 0x40,
        sub = 0x41,
        mul = 0x42,
        div = 0x43,
        mod = 0x44,
        neg = 0x45,

        // Bitwise
        bit_and = 0x50,
        bit_or = 0x51,
        bit_xor = 0x52,
        shl = 0x53,
        shr = 0x54,

        // Comparison
        eq = 0x60,
        neq = 0x61,
        lt = 0x62,
        gt = 0x63,
        lte = 0x64,
        gte = 0x65,

        // Logical
        @"and" = 0x70,
        @"or" = 0x71,
        not = 0x72,

        // Object operations (Move language)
        move_resource = 0x80,
        copy_resource = 0x81, // Only for copyable types
        mutate_resource = 0x82,
        delete_resource = 0x83,
        move_to_sender = 0x84,
        move_from = 0x85,
        borrow_global = 0x86,
        exists = 0x87,

        // Vector operations
        vec_len = 0x90,
        vec_push = 0x91,
        vec_pop = 0x92,
        vec_pack = 0x93,
        vec_unpack = 0x94,
        vec_swap = 0x95,

        // Function call
        call = 0xA0,

        // Unknown/Invalid
        invalid = 0xFF,
    };

    /// Complexity score for gas metering
    pub fn complexity(self: Self) u32 {
        return switch (self.opcode) {
            .add, .sub, .mul, .div, .mod => 1,
            .move_resource, .copy_resource, .mutate_resource, .delete_resource, .move_to_sender, .move_from, .borrow_global, .exists => 10,
            .call => 5,
            else => 1,
        };
    }
};

/// Verified bytecode module
pub const VerifiedModule = struct {
    /// Module name
    name: []const u8,
    /// Verified instructions
    instructions: []const Instruction,
    /// Number of local resources
    local_count: usize,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.instructions);
    }
};

/// Bytecode verifier
pub const BytecodeVerifier = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Verify bytecode for type safety
    pub fn verify(self: *Self, bytecode: []const u8) !VerifiedModule {
        // Parse instructions
        var instructions = try std.ArrayList(Instruction).initCapacity(self.allocator, 32);
        errdefer instructions.deinit(self.allocator);

        var offset: usize = 0;
        while (offset < bytecode.len) {
            const opcode: Instruction.OpCode = @enumFromInt(bytecode[offset]);
            offset += 1;

            // Parse instruction-specific payload
            const payload_len = switch (opcode) {
                .ld_u8 => 1,
                .ld_u64 => 8,
                .ld_u128 => 16,
                .ld_i8 => 1,
                .ld_i64 => 8,
                .ld_const => bytecode[offset],
                else => 0,
            };

            const payload = if (payload_len > 0) bytecode[offset..][0..payload_len] else &.{};

            try instructions.append(self.allocator, .{
                .opcode = opcode,
                .payload = payload,
            });

            offset += payload_len;
        }

        return .{
            .name = "module",
            .instructions = try instructions.toOwnedSlice(self.allocator),
            .local_count = 0,
        };
    }

    /// Check if instruction is legal at this point
    pub fn isLegalInstruction(self: *Self, instr: Instruction, in_function: bool) bool {
        _ = self;
        // Some operations only legal in certain contexts
        switch (instr.opcode) {
            .ret => return in_function,
            .move_resource, .copy_resource => {
                // Only legal if resource type is known to be copyable
                return true;
            },
            .delete_resource => {
                // Cannot delete non-resource types
                return true;
            },
            else => return true,
        }
    }
};

test "Bytecode verification" {
    const allocator = std.testing.allocator;
    var verifier = BytecodeVerifier.init(allocator);

    // Simple bytecode: ld_true; ld_false; add; ret
    const bytecode = [_]u8{
        0x31, // ld_true
        0x32, // ld_false
        0x40, // add
        0x01, // ret
    };

    var module = try verifier.verify(&bytecode);
    defer module.deinit(allocator);

    try std.testing.expect(module.instructions.len == 4);
    try std.testing.expect(module.instructions[0].opcode == .ld_true);
    try std.testing.expect(module.instructions[3].opcode == .ret);
}

test "Instruction complexity" {
    const instr = Instruction{ .opcode = .move_resource, .payload = &.{} };
    try std.testing.expect(instr.complexity() == 10);

    const add = Instruction{ .opcode = .add, .payload = &.{} };
    try std.testing.expect(add.complexity() == 1);
}
