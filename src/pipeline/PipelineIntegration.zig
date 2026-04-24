//! Pipeline Integration Tests
//!
//! Tests the full transaction flow: Ingress -> Executor -> Egress

const std = @import("std");
const core = @import("../core.zig");
const Ingress = @import("Ingress.zig");
const Executor = @import("Executor.zig");
const Egress = @import("Egress.zig");

/// Full pipeline integration test
test "Pipeline: Ingress -> Executor -> Egress" {
    const allocator = std.testing.allocator;
    
    // Initialize pipeline components
    var ingress = try Ingress.init(allocator, .{ .max_pending = 100 });
    defer ingress.deinit(allocator);
    
    var executor = try Executor.init(allocator, .{ .parallelism = 2 });
    defer executor.deinit();
    
    var egress = try Egress.init(allocator, 3000); // quorum = 2/3 of 3000
    defer egress.deinit(allocator);
    
    // Submit a transaction
    const tx = Transaction{
        .sender = [_]u8{0x42} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "move_true"),
        .gas_budget = 1000,
        .sequence = 1,
    };
    try ingress.submit(tx);
    try std.testing.expect(ingress.pendingCount() == 1);
    
    // Verify transaction
    try ingress.verify();
    try std.testing.expect(ingress.pendingCount() == 0);
    try std.testing.expect(ingress.verifiedCount() == 1);
    
    // Get verified transaction
    const verified_tx = ingress.getVerified();
    try std.testing.expect(verified_tx != null);
    
    // Execute transaction
    const execution = try executor.execute(verified_tx.?);
    try std.testing.expect(execution.status == .success);
    try std.testing.expect(execution.gas_used > 0);
    
    // Create certificate
    const signatures = &[_]SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{0xAA} ** 64, .stake = 1500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{0xBB} ** 64, .stake = 1500 },
    };
    
    const cert = try egress.aggregate(execution, signatures);
    try std.testing.expect(cert.stake_total == 3000);
    try std.testing.expect(egress.verifyCertificate(cert) == true);
    
    // Commit certificate
    const commit = try egress.commit(cert);
    try std.testing.expect(commit.checkpoint_sequence == 1);
    try std.testing.expect(commit.certificate.stake_total == 3000);
}

test "Pipeline: Multiple transactions batch execution" {
    const allocator = std.testing.allocator;
    
    var ingress = try Ingress.init(allocator, .{ .max_pending = 100 });
    defer ingress.deinit(allocator);
    
    var executor = try Executor.init(allocator, .{ .parallelism = 2 });
    defer executor.deinit();
    
    // Submit multiple transactions
    const num_txs = 5;
    for (0..num_txs) |i| {
        const tx = Transaction{
            .sender = [_]u8{@intCast(i)} ** 32,
            .inputs = &.{},
            .program = try allocator.dupe(u8, "nop"),
            .gas_budget = 1000,
            .sequence = @intCast(i),
        };
        try ingress.submit(tx);
    }
    
    try std.testing.expect(ingress.pendingCount() == num_txs);
    
    // Verify all
    try ingress.verify();
    try std.testing.expect(ingress.verifiedCount() == num_txs);
    
    // Collect transactions
    var txs = std.ArrayList(Transaction).init(allocator);
    defer txs.deinit(allocator);
    
    while (ingress.getVerified()) |tx| {
        try txs.append(tx);
    }
    
    // Execute batch
    const results = try executor.executeBatch(txs.items);
    defer allocator.free(results);
    
    try std.testing.expect(results.len == num_txs);
    
    // All should succeed (or at least complete)
    for (results) |result| {
        _ = result; // Check each completes without panic
    }
}

test "Pipeline: Transaction digest consistency" {
    const allocator = std.testing.allocator;
    
    const tx = Transaction{
        .sender = [_]u8{0xAB} ** 32,
        .inputs = &.{},
        .program = "test_program",
        .gas_budget = 5000,
        .sequence = 42,
    };
    
    // Multiple calls to digest should return same value
    const digest1 = tx.digest();
    const digest2 = tx.digest();
    const digest3 = tx.digest();
    
    try std.testing.expect(std.mem.eql(u8, &digest1, &digest2));
    try std.testing.expect(std.mem.eql(u8, &digest2, &digest3));
    
    // Digest should not be all zeros
    const is_zero = for (digest1) |b| {
        if (b != 0) break false;
    } else true;
    try std.testing.expect(is_zero == false);
}

test "Pipeline: Egress quorum validation" {
    const allocator = std.testing.allocator;
    
    var egress = try Egress.init(allocator, 3000); // Need 2000 for quorum
    defer egress.deinit(allocator);
    
    const execution = Executor.ExecutionResult{
        .digest = [_]u8{0xDE} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
        .events = &.{},
    };
    
    // Insufficient stake should fail
    const low_stake_sigs = &[_]SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 1000 },
    };
    
    const result = egress.aggregate(execution, low_stake_sigs);
    try std.testing.expect(result == error.InsufficientStake);
    
    // Sufficient stake should succeed
    const sufficient_sigs = &[_]SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 1500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{2} ** 64, .stake = 1000 },
    };
    
    const cert = try egress.aggregate(execution, sufficient_sigs);
    try std.testing.expect(cert.stake_total == 2500);
}

test "Pipeline: Certificate signature verification" {
    const allocator = std.testing.allocator;
    
    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit(allocator);
    
    const execution = Executor.ExecutionResult{
        .digest = [_]u8{0xAD} ** 32,
        .status = .success,
        .gas_used = 50,
        .output_objects = &.{},
        .events = &.{},
    };
    
    const signatures = &[_]SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{0xFF} ** 64, .stake = 2000 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{0xFE} ** 64, .stake = 1500 },
    };
    
    const cert = try egress.aggregate(execution, signatures);
    
    // Certificate should pass signature verification (format check)
    try std.testing.expect(egress.verifySignatures(cert) == true);
    
    // Certificate should have sufficient stake
    try std.testing.expect(egress.verifyCertificate(cert) == true);
}

test "Pipeline: Ingress backpressure" {
    const allocator = std.testing.allocator;
    
    // Very small pending limit
    var ingress = try Ingress.init(allocator, .{ .max_pending = 2 });
    defer ingress.deinit(allocator);
    
    // First two should succeed
    try ingress.submit(.{ .sender = [_]u8{1} ** 32, .inputs = &.{}, .program = "a", .gas_budget = 1000, .sequence = 1 });
    try ingress.submit(.{ .sender = [_]u8{2} ** 32, .inputs = &.{}, .program = "b", .gas_budget = 1000, .sequence = 2 });
    
    // Third should fail
    const result = ingress.submit(.{ .sender = [_]u8{3} ** 32, .inputs = &.{}, .program = "c", .gas_budget = 1000, .sequence = 3 });
    try std.testing.expect(result == error.TooManyPending);
}
