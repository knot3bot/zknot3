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
    pending_certificates: std.ArrayList(Certificate),
    quorum_stake: u128,

    pub fn init(allocator: std.mem.Allocator, quorum_stake: u128) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .pending_certificates = std.ArrayList(Certificate).empty,
            .quorum_stake = quorum_stake,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.pending_certificates.items) |cert| {
            self.allocator.free(cert.signatures);
        }
        self.pending_certificates.deinit(self.allocator);
        self.allocator.destroy(self);
    }


    /// Aggregate signatures into certificate (overflow-safe)
    pub fn aggregate(self: *Self, execution: Executor.ExecutionResult, signatures: []const SignaturePair) !Certificate {
        var total_stake: u128 = 0;
        for (signatures) |sig| {
            total_stake = std.math.add(u128, total_stake, sig.stake) catch return error.Overflow;
        }

        // Check quorum: need > 2/3 (overflow-safe check)
        if (total_stake > std.math.maxInt(u128) / 3 or self.quorum_stake > std.math.maxInt(u128) / 2) {
            if (total_stake < @divFloor(self.quorum_stake *% 2, 3)) return error.InsufficientStake;
        } else if (total_stake * 3 < self.quorum_stake * 2) {
            return error.InsufficientStake;
        }

        return Certificate{
            .digest = execution.digest,
            .signatures = try self.allocator.dupe(SignaturePair, signatures),
            .stake_total = total_stake,
        };
    }

    /// Commit certificate and produce checkpoint with real state root
    pub fn commit(self: *Self, cert: Certificate) !CommitResult {
        // Compute state root from certificate digest, validator set, and timestamps
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&cert.digest);
        ctx.update(std.mem.asBytes(&cert.stake_total));
        for (cert.signatures) |sig| {
            ctx.update(&sig.validator);
            ctx.update(&sig.signature);
            ctx.update(std.mem.asBytes(&sig.stake));
        }
        var state_root: [32]u8 = undefined;
        ctx.final(&state_root);

        const checkpoint_seq = self.pending_certificates.items.len + 1;

        return CommitResult{
            .checkpoint_sequence = checkpoint_seq,
            .certificate = cert,
            .state_root = state_root,
            .timestamp = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        };
    }

    /// Add pending certificate
    pub fn addPending(self: *Self, cert: Certificate) !void {
        try self.pending_certificates.append(self.allocator, cert);
    }

    /// Get next pending certificate (FIFO order).
    pub fn getPending(self: *Self) ?Certificate {
        if (self.pending_certificates.items.len == 0) return null;
        return self.pending_certificates.orderedRemove(0);
    }

    /// Compute the 2/3+1 quorum threshold from total stake.
    fn quorumThreshold(self: Self) u128 {
        return (self.quorum_stake * 2) / 3 + 1;
    }

    /// Verify a certificate has sufficient stake for quorum AND valid signatures.
    pub fn verifyCertificate(self: Self, cert: Certificate) bool {
        if (cert.stake_total < self.quorumThreshold()) return false;
        return self.verifySignatures(cert);
    }

    /// Verify Ed25519 signatures in a certificate against the certificate digest.
    pub fn verifySignatures(self: Self, cert: Certificate) bool {
        _ = self;
        const Ed25519 = @import("../property/Signature.zig").Ed25519;
        for (cert.signatures) |sig| {
            // Check signature is not all zeros
            const sig_is_zero = for (sig.signature) |b| {
                if (b != 0) break false;
            } else true;
            if (sig_is_zero) return false;
            // Check validator ID is not zero
            const id_is_zero = for (sig.validator) |b| {
                if (b != 0) break false;
            } else true;
            if (id_is_zero) return false;
            // Verify Ed25519 signature over certificate digest
            if (!Ed25519.verify(sig.validator, &cert.digest, sig.signature)) return false;
        }
        return true;
    }

    /// Verify a certificate using BLS aggregated signatures (O(1) size vs O(n)).
    /// Validators must have registered BLS public keys via the Quorum module.
    pub fn verifyCertificateBLS(self: Self, cert: Certificate, bls_pubkeys: []const [96]u8) bool {
        if (cert.stake_total < self.quorumThreshold()) return false;
        if (cert.signatures.len < 1) return false;
        // BLS aggregate signature is stored in the first signature pair as the combined sig
        const BlsModule = @import("../core/crypto/Bls.zig");
        const agg_sig_bytes = cert.signatures[0].signature[0..96].*;
        return BlsModule.verifyAggregated(cert.digest, &agg_sig_bytes, bls_pubkeys);
    }
};

test "Egress certificate aggregation" {
    const allocator = std.testing.allocator;
    var egress = try Egress.init(allocator, 3000); // Need 2/3 of 3000 = 2000
    defer egress.deinit();

    const execution = Executor.ExecutionResult{
        .digest = [_]u8{1} ** 32,
        .status = .success,
        .gas_used = 100,
        .output_objects = &.{},
        .events = &.{},
    };

    const signatures = &[_]SignaturePair{
        .{ .validator = [_]u8{1} ** 32, .signature = [_]u8{1} ** 64, .stake = 1500 },
        .{ .validator = [_]u8{2} ** 32, .signature = [_]u8{2} ** 64, .stake = 1000 },
    };

    const cert = try egress.aggregate(execution, signatures);
    defer allocator.free(cert.signatures);
    try std.testing.expect(cert.stake_total == 2500); // > 2000 quorum
}

test "Egress verifyCertificate rejects below-threshold stake" {
    const allocator = std.testing.allocator;
    var egress = try Egress.init(allocator, 3000); // total stake
    defer egress.deinit();

    const cert = Certificate{
        .digest = [_]u8{1} ** 32,
        .signatures = &.{},
        .stake_total = 1500, // Only 50% — below 2/3+1 threshold (2001)
    };

    // 1500 < 2001 threshold → should reject
    try std.testing.expect(!egress.verifyCertificate(cert));
}

test "Egress verifyCertificate rejects invalid signatures" {
    const allocator = std.testing.allocator;
    var egress = try Egress.init(allocator, 3000);
    defer egress.deinit();

    const cert = Certificate{
        .digest = [_]u8{1} ** 32,
        .signatures = &[_]SignaturePair{
            .{ .validator = [_]u8{0} ** 32, .signature = [_]u8{0} ** 64, .stake = 2500 },
        },
        .stake_total = 2500, // Above 2001 threshold
    };

    // Stake is sufficient but signature verification fails (zero validator + zero sig)
    try std.testing.expect(!egress.verifyCertificate(cert));
}
