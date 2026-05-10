const std = @import("std");
const values = @import("../../src/property/move_vm/values.zig");
const Value = values.Value;
const IntegerValue = values.IntegerValue;
const StructValue = values.StructValue;
const AbilitySet = values.AbilitySet;

test "values: copy and equals" {
    const allocator = std.testing.allocator;
    const v1 = Value.makeU64(42);
    const v2 = try v1.copyValue(allocator);
    defer v2.deinit(allocator);
    try std.testing.expect(try v1.equals(v2));
}

test "values: checked arithmetic" {
    const a = IntegerValue{ .U64 = 10 };
    const b = IntegerValue{ .U64 = 3 };
    const sum = try IntegerValue.addChecked(a, b);
    try std.testing.expectEqual(@as(u64, 13), sum.U64);
    const prod = try IntegerValue.mulChecked(a, b);
    try std.testing.expectEqual(@as(u64, 30), prod.U64);
}

test "values: overflow detection" {
    const a = IntegerValue{ .U8 = 250 };
    const b = IntegerValue{ .U8 = 10 };
    try std.testing.expectError(error.Overflow, IntegerValue.addChecked(a, b));
}

test "values: type mismatch" {
    const a = IntegerValue{ .U8 = 1 };
    const b = IntegerValue{ .U16 = 2 };
    try std.testing.expectError(error.TypeMismatch, IntegerValue.addChecked(a, b));
}

test "values: struct pack" {
    const allocator = std.testing.allocator;
    const fields = [_]Value{ Value.makeU8(10), Value.makeU64(20) };
    var s = try StructValue.pack(allocator, &fields, AbilitySet.default());
    defer s.deinit(allocator);
    try std.testing.expect(s.impl.Container.data.items.len == 2);
}

test "values: ref counting" {
    const allocator = std.testing.allocator;
    const fields = [_]Value{ Value.makeU64(1) };
    var s = try StructValue.pack(allocator, &fields, AbilitySet.default());
    defer s.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), s.impl.Container.ref_count);
}
