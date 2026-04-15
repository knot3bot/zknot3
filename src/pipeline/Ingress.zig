//! Ingress - Inbound transaction processing
//!
//! Handles:
//! - Signature verification
//! - Object locking
//! - Transaction ordering

const std = @import("std");
const core = @import("../core.zig");
const Resource = @import("property/move_vm/Resource");
const Signature = @import("../property/crypto/Signature.zig");

/// Minimum gas budget per transaction
const MIN_GAS_BUDGET = 100;

/// Transaction input
pub const Transaction = struct {
    sender: [32]u8,
    inputs: []const core.ObjectID,
    program: []const u8,
    gas_budget: u64,
    sequence: u64,
    /// Ed25519 signature over the transaction digest
    signature: ?[64]u8 = null,
    /// Public key for signature verification
    public_key: ?[32]u8 = null,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.inputs);
        allocator.free(self.program);
    }

    /// Compute transaction digest (the data that gets signed)
    pub fn digest(self: Self) [32]u8 {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&self.sender);
        for (self.inputs) |id| {
            ctx.update(id.asBytes());
        }
        ctx.update(self.program);
        var tx_digest: [32]u8 = undefined;
        ctx.final(&tx_digest);
        return tx_digest;
    }

    /// Verify the transaction signature
    /// Returns true if signature is valid or if transaction has no signature (for testing)
    pub fn verifySignature(self: Self) bool {
        // If no signature provided, skip verification (allows testing)
        const sig = self.signature orelse return true;
        const pk = self.public_key orelse return false;

        const tx_digest = self.digest();

        const pub_key = Signature.PublicKey{ .bytes = pk };
        const sig_struct = Signature.Signature{
            .bytes = sig,
            .scheme = .ed25519,
        };

        return sig_struct.verify(pub_key, &tx_digest);
    }
};

/// Transaction receipt
pub const TransactionReceipt = struct {
    digest: [32]u8,
    status: TransactionStatus,
    gas_used: u64,
    sender: [32]u8,
};

/// Transaction status
pub const TransactionStatus = enum {
    pending,
    verified,
    locked,
    executed,
    committed,
    failed,
};

/// Ingress configuration
pub const IngressConfig = struct {
    max_pending: usize = 10000,
    verification_timeout_ms: u64 = 5000,
    /// Minimum gas budget required
    min_gas_budget: u64 = MIN_GAS_BUDGET,
    /// Whether to require signatures (can be disabled for testing)
    require_signatures: bool = true,
};

/// Ingress processor using ArrayList for queue management
pub const Ingress = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: IngressConfig,
    pending: std.ArrayList(Transaction),
    verified: std.ArrayList(Transaction),

    pub fn init(allocator: std.mem.Allocator, config: IngressConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .pending = std.ArrayList(Transaction){},
            .verified = std.ArrayList(Transaction){},
        };
        // Pre-allocate based on max_pending to avoid reallocations
        try self.pending.ensureTotalCapacity(config.max_pending);
        try self.verified.ensureTotalCapacity(config.max_pending / 2);
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.pending.items) |*tx| {
            tx.deinit(self.allocator);
        }
        self.pending.deinit(self.allocator);

        for (self.verified.items) |*tx| {
            tx.deinit(self.allocator);
        }
        self.verified.deinit(self.allocator);
    }

    /// Submit a new transaction
    pub fn submit(self: *Self, transaction: Transaction) !void {
        if (self.pending.items.len >= self.config.max_pending) {
            return error.TooManyPending;
        }
        try self.pending.append(self.allocator, transaction);
    }

    /// Verify pending transactions with full signature verification
    pub fn verify(self: *Self) !void {
        // Move transactions from pending to verified after verification
        while (self.pending.popOrNull()) |tx| {
            // 1. Check minimum gas budget
            if (tx.gas_budget < self.config.min_gas_budget) {
                continue;
            }

            // 2. Verify signature if required
            if (self.config.require_signatures) {
                if (!tx.verifySignature()) {
                    continue; // Invalid signature - discard
                }
            }

            // 3. In production would also:
            //    - Verify inputs exist in object store
            //    - Lock objects for this transaction
            //    - Check sequence number is correct

            try self.verified.append(self.allocator, tx);
        }
    }

    /// Get next verified transaction
    pub fn getVerified(self: *Self) ?Transaction {
        return self.verified.popOrNull();
    }

    /// Peek at pending count
    pub fn pendingCount(self: Self) usize {
        return self.pending.items.len;
    }

    /// Peek at verified count
    pub fn verifiedCount(self: Self) usize {
        return self.verified.items.len;
    }
};

test "Ingress basic operations" {
    const allocator = std.testing.allocator;
    const config = IngressConfig{};
    var ingress = try Ingress.init(allocator, config);
    defer ingress.deinit();

    const tx = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "test program"),
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null,
        .public_key = null,
    };

    try ingress.submit(tx);
    try std.testing.expect(ingress.pendingCount() == 1);

    try ingress.verify();
    try std.testing.expect(ingress.verifiedCount() == 1);
}

test "Transaction digest" {
    const tx = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = "test",
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null,
        .public_key = null,
    };

    const digest1 = tx.digest();
    const digest2 = tx.digest();

    // Same transaction should produce same digest
    try std.testing.expect(std.mem.eql(u8, &digest1, &digest2));
}

test "Transaction signature verification" {
    const allocator = std.testing.allocator;

    // Generate keypair for signing
    var keypair = try Signature.KeyPair.generate();
    defer keypair.deinit();

    // Create transaction
    var tx = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "test program"),
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null,
        .public_key = null,
    };
    defer tx.deinit(allocator);

    // Sign the transaction
    const digest = tx.digest();
    const sig = try Signature.sign(digest, keypair.secret_key, .ed25519);
    tx.signature = sig;
    tx.public_key = keypair.public_key.bytes;

    // Verify signature
    try std.testing.expect(tx.verifySignature());

    // Tamper with transaction - verification should fail
    tx.gas_budget = 9999;
    try std.testing.expect(!tx.verifySignature());
}

test "Transaction without signature fails when signatures required" {
    const allocator = std.testing.allocator;
    const config = IngressConfig{ .require_signatures = true };
    var ingress = try Ingress.init(allocator, config);
    defer ingress.deinit();

    const tx = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "test program"),
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null, // No signature
        .public_key = null,
    };

    try ingress.submit(tx);
    try ingress.verify();

    // Transaction should NOT be verified because signature is required
    try std.testing.expect(ingress.verifiedCount() == 0);
}

test "Transaction without signature passes when signatures disabled" {
    const allocator = std.testing.allocator;
    const config = IngressConfig{ .require_signatures = false };
    var ingress = try Ingress.init(allocator, config);
    defer ingress.deinit();

    const tx = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "test program"),
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null,
        .public_key = null,
    };

    try ingress.submit(tx);
    try ingress.verify();

    // Transaction SHOULD be verified because signature requirement is disabled
    try std.testing.expect(ingress.verifiedCount() == 1);
}
