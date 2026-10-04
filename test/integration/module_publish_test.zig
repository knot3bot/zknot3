//! End-to-end module publishing through the Executor PTB path.

const std = @import("std");
const root = @import("../../src/root.zig");
const Executor = root.pipeline.Executor;
const Ingress = @import("../../src/pipeline/Ingress.zig");
const ObjectStore = root.form.storage.ObjectStore;
const ModuleRegistry = root.property.move_vm.ModuleRegistry;
const encodePublishPayload = @import("../../src/property/move_vm/ModuleRegistry.zig").encodePublishPayload;

test "PTB Publish operation registers and persists module objects" {
    const allocator = std.testing.allocator;

    const store = try ObjectStore.init(allocator, .{}, ".");
    defer store.deinit();

    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();
    executor.attachObjectStore(store);

    const sender = @as([32]u8, @splat(0x5A));
    const blob = try encodePublishPayload(
        allocator,
        "market",
        .compatible,
        &[_][]const u8{ "list", "buy" },
        &[_]u8{ 0xB0, 0xB1, 0xB2 },
    );

    const modules = try allocator.alloc([]const u8, 1);
    modules[0] = blob;
    const ops = try allocator.alloc(Ingress.Operation, 1);
    ops[0] = .{ .Publish = .{ .modules = modules } };

    const tx = Ingress.Transaction{
        .sender = sender,
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 100_000,
        .sequence = 1,
        .operations = ops,
    };
    defer {
        allocator.free(modules);
        allocator.free(ops);
    }

    const result = try executor.executePTB(tx);
    // modules[0] is reassigned to blob_v2 below; free the first blob now.
    allocator.free(blob);
    try std.testing.expect(result.status == .success);
    try std.testing.expectEqual(@as(usize, 1), result.output_objects.len);
    try std.testing.expect(result.gas_used > 0);

    // The module is registered on-chain under the sender's package.
    const mod = executor.module_registry.findByName(sender, "market") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("market", mod.name);
    try std.testing.expectEqual(@as(u32, 1), mod.version);

    // The module object is retrievable from the object store.
    const module_id = result.output_objects[0];
    if (result.output_objects.len > 0) allocator.free(result.output_objects);
    var stored = try store.get(.{ .bytes = module_id });
    try std.testing.expect(stored != null);
    defer if (stored) |*object| object.deinit(allocator);
    try std.testing.expect(stored.?.type_tag == 2);

    // An upgrade through a second PTB bumps the version.
    const blob_v2 = try encodePublishPayload(
        allocator,
        "market",
        .compatible,
        &[_][]const u8{ "buy", "list" },
        &[_]u8{ 0xB0, 0xB1, 0xB3 },
    );
    defer allocator.free(blob_v2);
    modules[0] = blob_v2;
    const tx2 = Ingress.Transaction{
        .sender = sender,
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 100_000,
        .sequence = 2,
        .operations = ops,
    };
    const result2 = try executor.executePTB(tx2);
    try std.testing.expect(result2.status == .success);
    const mod_v2 = executor.module_registry.findByName(sender, "market") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), mod_v2.version);
    if (result2.output_objects.len > 0) allocator.free(result2.output_objects);
}

test "PTB Publish rejects corrupt module blobs atomically" {
    const allocator = std.testing.allocator;

    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    const sender = @as([32]u8, @splat(0x5B));
    const bad_blob = "not-a-module-container";
    const modules = try allocator.alloc([]const u8, 1);
    modules[0] = bad_blob;
    const ops = try allocator.alloc(Ingress.Operation, 1);
    ops[0] = .{ .Publish = .{ .modules = modules } };
    defer {
        allocator.free(modules);
        allocator.free(ops);
    }

    const tx = Ingress.Transaction{
        .sender = sender,
        .inputs = &.{},
        .program = &.{},
        .gas_budget = 100_000,
        .sequence = 1,
        .operations = ops,
    };

    const result = try executor.executePTB(tx);
    try std.testing.expect(result.status == .invalid_bytecode);
    try std.testing.expectEqual(@as(usize, 0), executor.module_registry.count());
}
