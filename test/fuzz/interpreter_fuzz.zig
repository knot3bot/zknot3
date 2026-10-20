//! Bounded interpreter fuzz.
//!
//! Random and malformed bytecode must come back as an error from the verifier
//! or the interpreter. A safety panic here is a node crash on untrusted input.
//! The suite also runs one well-formed program so a verifier that rejects
//! everything does not look green.

const std = @import("std");
const Bytecode = @import("../../src/property/move_vm/Bytecode.zig");
const Gas = @import("../../src/property/move_vm/Gas.zig");
const Interpreter = @import("../../src/property/move_vm/Interpreter.zig");
const Resource = @import("../../src/property/move_vm/Resource.zig");

fn runOnce(allocator: std.mem.Allocator, bytecode: []const u8) !void {
    var verifier = Bytecode.BytecodeVerifier.init(allocator);
    const module = verifier.verify(bytecode) catch return;
    defer allocator.free(module.instructions);

    var gas = Gas.GasMeter.init(.{
        .initial_budget = 2_000,
        .max_gas = 2_000,
        .min_gas = 1,
    });
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();
    var interpreter = try Interpreter.Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    const result = interpreter.execute(module) catch return;
    try std.testing.expect(result.gas_consumed <= 2_000);
    if (result.return_value) |value| value.deinit(allocator);
}

test "interpreter fuzz: random bytecode returns an error or a bounded result" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x6e6f7433);
    const random = prng.random();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const len = random.intRangeAtMost(usize, 0, 48);
        const buf = try allocator.alloc(u8, len);
        defer allocator.free(buf);
        random.bytes(buf);
        try runOnce(allocator, buf);
    }

    // Opcode 0xFE is a hole in the opcode enum. It must not panic.
    try runOnce(allocator, &[_]u8{0xFE});
    try runOnce(allocator, &.{});

    // ld_u64 1; ld_u64 2; add; ret
    var program: [1 + 8 + 1 + 8 + 1 + 1]u8 = undefined;
    program[0] = 0x34;
    std.mem.writeInt(u64, program[1..9], 1, .big);
    program[9] = 0x34;
    std.mem.writeInt(u64, program[10..18], 2, .big);
    program[18] = 0x40;
    program[19] = 0x01;

    var verifier = Bytecode.BytecodeVerifier.init(allocator);
    const module = try verifier.verify(&program);
    defer allocator.free(module.instructions);
    var gas = Gas.GasMeter.init(.{ .initial_budget = 2_000, .max_gas = 2_000, .min_gas = 1 });
    var tracker = Resource.ResourceTracker.init(allocator);
    defer tracker.deinit();
    var interpreter = try Interpreter.Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();
    const result = try interpreter.execute(module);
    try std.testing.expect(result.success);
    try std.testing.expect(result.return_value != null);
    try std.testing.expectEqual(@as(i64, 3), result.return_value.?.data.int);
    result.return_value.?.deinit(allocator);
}
