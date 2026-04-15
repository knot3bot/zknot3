//! Integration tests for zknot3 pipeline
//!
//! Tests the full flow: Ingress → Executor → Egress

const std = @import("std");
const root = @import("root.zig");
const Ingress = root.pipeline.Ingress;
const Executor = root.pipeline.Executor;
const Egress = root.pipeline.Egress;
const ObjectStore = root.form.storage.ObjectStore;
const Signature = root.property.crypto.Signature;
const Checkpoint = root.form.storage.Checkpoint;

test "Full pipeline: submit transaction through ingress" {
    const allocator = std.testing.allocator;

    // Initialize components
    var ingress = try Ingress.init(allocator, .{});
    defer ingress.deinit();

    // Create a transaction
    const tx = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, &.{ 0x31, 0x01 }), // ld_true; ret
        .gas_budget = 1000,
        .sequence = 1,
    };

    // Submit to ingress
    try ingress.submit(tx);
    try std.testing.expect(ingress.pendingCount() == 1);

    // Verify transaction
    try ingress.verify();
    try std.testing.expect(ingress.verifiedCount() == 1);
}

test "Transaction digest is deterministic" {
    const tx = Transaction{
        .sender = [_]u8{0xAB} ** 32,
        .inputs = &.{},
        .program = "test bytecode",
        .gas_budget = 1000,
        .sequence = 5,
    };

    const digest1 = tx.digest();
    const digest2 = tx.digest();

    try std.testing.expect(std.mem.eql(u8, &digest1, &digest2));
}

test "Ingress rejects excess pending transactions" {
    const allocator = std.testing.allocator;
    var ingress = try Ingress.init(allocator, .{ .max_pending = 2 });
    defer ingress.deinit();

    const tx1 = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = "tx1",
        .gas_budget = 1000,
        .sequence = 1,
    };

    const tx2 = Transaction{
        .sender = [_]u8{2} ** 32,
        .inputs = &.{},
        .program = "tx2",
        .gas_budget = 1000,
        .sequence = 2,
    };

    const tx3 = Transaction{
        .sender = [_]u8{3} ** 32,
        .inputs = &.{},
        .program = "tx3",
        .gas_budget = 1000,
        .sequence = 3,
    };

    try ingress.submit(tx1);
    try ingress.submit(tx2);

    // Third submission should fail
    try std.testing.expectError(error.TooManyPending, ingress.submit(tx3));
}

test "Executor produces valid execution result" {
    const allocator = std.testing.allocator;
    var executor = try Executor.init(allocator, .{});
    defer executor.deinit();

    const tx = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = &.{ 0x31, 0x01 }, // ld_true; ret
        .gas_budget = 1000,
        .sequence = 1,
    };

    const result = try executor.execute(tx);
    try std.testing.expect(result.status == .success);
    try std.testing.expect(result.gas_used > 0);
}

test "Egress aggregates certificates with quorum" {
    const allocator = std.testing.allocator;
    var egress = try Egress.init(allocator, 3000); // Need 2/3 of 3000 = 2000
    defer egress.deinit();

    const execution = Executor.ExecutionResult{
        .digest = [_]u8{1} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
    };

    const signatures = &[_]Egress.SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 1500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{2} ** 64, .stake = 1000 },
    };

    const cert = try egress.aggregate(execution, signatures);
    try std.testing.expect(cert.stake_total == 2500); // > 2000 quorum
}

test "Egress rejects insufficient stake" {
    const allocator = std.testing.allocator;
    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit();

    const execution = Executor.ExecutionResult{
        .digest = [_]u8{1} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
    };

    const signatures = &[_]Egress.SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{2} ** 64, .stake = 500 },
    };

    try std.testing.expectError(error.InsufficientStake, egress.aggregate(execution, signatures));
}

test "ObjectStore put and get" {
    const allocator = std.testing.allocator;
    var store = try ObjectStore.init(allocator, .{});
    defer store.deinit();

    const obj = ObjectStore.Object{
        .id = root.core.ObjectID.hash("test_key"),
        .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
        .ownership = root.core.Ownership.ownedBy([_]u8{0xAB} ** 32),
        .type_tag = 1,
        .data = try allocator.dupe(u8, "test data"),
    };

    try store.put(obj);

    const retrieved = try store.getLatest(obj.id);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.id.eql(obj.id));
}

test "Checkpoint creation and serialization" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = root.core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };

    const cp = try Checkpoint.create(1, [_]u8{0} ** 32, &changes, allocator);

    try std.testing.expect(cp.sequence == 1);
    try std.testing.expect(cp.object_changes.len == 1);

    const serialized = try cp.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
}

test "Checkpoint digest is deterministic" {
    const allocator = std.testing.allocator;

    const changes = [_]Checkpoint.ObjectChange{
        .{
            .id = root.core.ObjectID.hash("obj1"),
            .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
            .status = .created,
        },
    };

    const cp = try Checkpoint.create(1, [_]u8{0} ** 32, &changes, allocator);

    const digest1 = cp.digest();
    const digest2 = cp.digest();

    try std.testing.expect(std.mem.eql(u8, &digest1, &digest2));
}

test "Signature sign and verify" {
    const message = "Hello, zknot3!";
    const message_bytes = message.*;

    // Generate keypair
    const seed = [_]u8{0xAB} ** 32;
    const secret_key = Signature.generateSecretKey(seed);
    const public_key = Signature.derivePublicKey(secret_key);

    // Sign
    const signature = Signature.sign(&message_bytes, secret_key);

    // Verify
    const valid = Signature.verify(&message_bytes, signature, public_key);
    try std.testing.expect(valid);
}

test "Signature verify fails with wrong message" {
    const message1 = "Hello";
    const message2 = "World";
    const message1_bytes = message1.*;
    const message2_bytes = message2.*;

    const seed = [_]u8{0xAB} ** 32;
    const secret_key = Signature.generateSecretKey(seed);
    const public_key = Signature.derivePublicKey(secret_key);

    const signature = Signature.sign(&message1_bytes, secret_key);

    const valid = Signature.verify(&message2_bytes, signature, public_key);
    try std.testing.expect(!valid);
}

// Transaction type alias for tests
const Transaction = Ingress.Transaction;
