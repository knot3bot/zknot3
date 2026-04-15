//! Egress - Certificate aggregation and state commitment

const std = @import("std");
const core = @import("../core.zig");
const Executor = @import("Executor.zig");

/// Certificate for committed transactions
pub const Certificate = struct {
    digest: [32]u8,
    signatures: []const SignaturePair,
    stake_total: u128,
};

/// Signature from validator
pub const SignaturePair = struct {
    validator: [32]u8,
    signature: [64]u8,
    stake: u128,
};

/// Commit result
pub const CommitResult = struct {
    checkpoint_sequence: u64,
    certificate: Certificate,
    state_root: [32]u8,
    timestamp: i64,
};

/// Egress processor
pub const Egress = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    pending_certificates: std.Fifo(Certificate),
    quorum_stake: u128,

    pub fn init(allocator: std.mem.Allocator, quorum_stake: u128) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .pending_certificates = std.Fifo(Certificate){},
            .quorum_stake = quorum_stake,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        while (self.pending_certificates.readItem()) |cert| {
            self.allocator.free(cert.signatures);
        }
    }

    /// Aggregate signatures into certificate
    pub fn aggregate(self: *Self, execution: Executor.ExecutionResult, signatures: []const SignaturePair) !Certificate {
        // Calculate total stake
        var total_stake: u128 = 0;
        for (signatures) |sig| {
            total_stake += sig.stake;
        }

        // Check quorum
        if (total_stake * 3 < self.quorum_stake * 2) {
            return error.InsufficientStake;
        }

        return Certificate{
            .digest = execution.digest,
            .signatures = try self.allocator.dupe(SignaturePair, signatures),
            .stake_total = total_stake,
        };
    }

    /// Commit certificate and produce checkpoint
    pub fn commit(self: *Self, cert: Certificate) !CommitResult {
        // In production would:
        // 1. Verify all signatures
        // 2. Update object store
        // 3. Create checkpoint
        // 4. Broadcast checkpoint
        // Compute state root (simplified)
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&cert.digest);
        for (cert.signatures) |sig| {
            ctx.update(&sig.validator);
            ctx.update(&sig.signature);
        }
        var state_root: [32]u8 = undefined;
        ctx.final(&state_root);

        // Generate checkpoint sequence based on committed count
        const checkpoint_seq = self.pending_certificates.count + 1;

        return CommitResult{
            .checkpoint_sequence = checkpoint_seq,
            .certificate = cert,
            .state_root = state_root,
            .timestamp = std.time.timestamp(),
        };
    }

    /// Add pending certificate
    pub fn addPending(self: *Self, cert: Certificate) !void {
        try self.pending_certificates.writeItem(cert);
    }

    /// Get next pending certificate
    pub fn getPending(self: *Self) ?Certificate {
        return self.pending_certificates.readItem();
    }

    /// Verify a certificate has sufficient stake for quorum
    pub fn verifyCertificate(self: Self, cert: Certificate) bool {
        return cert.stake_total > self.quorum_stake;
    }

    /// Verify all signatures in a certificate are non-zero (format check)
    /// In production, would verify cryptographic signatures against validator keys
    pub fn verifySignatures(self: Self, cert: Certificate) bool {
        _ = self;
        for (cert.signatures) |sig| {
            // Check signature is not all zeros
            const is_zero = for (sig.signature) |b| {
                if (b != 0) break false;
            } else true;
            if (is_zero) return false;
            // Check validator ID is not zero
            const id_is_zero = for (sig.validator) |b| {
                if (b != 0) break false;
            } else true;
            if (id_is_zero) return false;
        }
        return true;
    }
};

test "Egress certificate aggregation" {
    const allocator = std.testing.allocator;
    var egress = try Egress.init(allocator, 3000); // Need 2/3 of 3000 = 2000
    defer egress.deinit(allocator);

    const execution = Executor.ExecutionResult{
        .digest = [_]u8{1} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
    };

    const signatures = &[_]SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 1500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{2} ** 64, .stake = 1000 },
    };

    const cert = try egress.aggregate(execution, signatures);
    try std.testing.expect(cert.stake_total == 2500); // > 2000 quorum
}
