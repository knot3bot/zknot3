//! Move Contract Integration Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");

const Resource = root.property.move_vm.Resource;
const ResourceTracker = root.property.move_vm.ResourceTracker;
const Gas = root.property.move_vm.Gas;
const Interpreter = root.property.move_vm.Interpreter;

test "Move: resource creation" {
    const allocator = std.testing.allocator;

    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    const id = root.core.ObjectID.hash("test");
    var res = try Resource.init(id, .Custom, &.{ 0, 1, 2 }, makeId(1), allocator);
    defer res.deinit(allocator);

    try std.testing.expect(res.isValid());
}

test "Move: gas meter" {
    var gas = Gas.GasMeter.init(.{ .max_gas = 1000 });
    try gas.consume(100);
    try std.testing.expect(gas.getRemaining() == 900);
    try std.testing.expect(gas.hasGas(100));
}

test "Move: interpreter init" {
    const allocator = std.testing.allocator;

    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var gas = Gas.GasMeter.init(.{ .max_gas = 10000 });

    var interpreter = try Interpreter.init(allocator, &gas, &tracker);
    defer interpreter.deinit();

    try std.testing.expect(gas.getRemaining() == 10000);
}

fn makeId(i: u8) [32]u8 {
    return [_]u8{i} ** 32;
}
