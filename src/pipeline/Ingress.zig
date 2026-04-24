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
    /// Protocol v1 frozen commitment: sender || inputs || program || gas_budget (be64) || sequence (be64)
    pub fn digest(self: Self) [32]u8 {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&self.sender);
        for (self.inputs) |id| {
            ctx.update(id.asBytes());
        }
        ctx.update(self.program);
        var gas_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &gas_buf, self.gas_budget, .big);
        ctx.update(&gas_buf);
        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, self.sequence, .big);
        ctx.update(&seq_buf);
        var tx_digest: [32]u8 = undefined;
        ctx.final(&tx_digest);
        return tx_digest;
    }

    /// Canonical serialization for protocol v1 wire format.
    /// Layout: sender[32] | inputs_len[4] | inputs[] | program_len[4] | program[] | gas_budget[8] | sequence[8] | sig_flag[1] | sig[64]? | pk[32]?
    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, &self.sender);
        var inputs_len: [4]u8 = undefined;
        std.mem.writeInt(u32, &inputs_len, @intCast(self.inputs.len), .big);
        try buf.appendSlice(allocator, &inputs_len);
        for (self.inputs) |id| {
            try buf.appendSlice(allocator, id.asBytes());
        }
        var prog_len: [4]u8 = undefined;
        std.mem.writeInt(u32, &prog_len, @intCast(self.program.len), .big);
        try buf.appendSlice(allocator, &prog_len);
        try buf.appendSlice(allocator, self.program);
        var gas_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &gas_buf, self.gas_budget, .big);
        try buf.appendSlice(allocator, &gas_buf);
        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, self.sequence, .big);
        try buf.appendSlice(allocator, &seq_buf);
        const has_sig: u8 = if (self.signature != null) 1 else 0;
        try buf.append(allocator, has_sig);
        if (self.signature) |sig| {
            try buf.appendSlice(allocator, &sig);
        }
        const has_pk: u8 = if (self.public_key != null) 1 else 0;
        try buf.append(allocator, has_pk);
        if (self.public_key) |pk| {
            try buf.appendSlice(allocator, &pk);
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Deserialize protocol v1 wire format.
    pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Transaction {
        if (bytes.len < 32 + 4 + 4 + 8 + 8 + 1 + 1) return error.MalformedTransaction;
        var pos: usize = 0;
        const sender: [32]u8 = bytes[0..32].*;
        pos += 32;
        const inputs_len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        pos += 4;
        const input_size: usize = @as(usize, inputs_len) * 32;
        if (bytes.len < pos + input_size) return error.MalformedTransaction;
        var inputs = try allocator.alloc(core.ObjectID, inputs_len);
        errdefer allocator.free(inputs);
        for (0..inputs_len) |i| {
            inputs[i] = core.ObjectID{ .bytes = bytes[pos..][0..32].* };
            pos += 32;
        }
        const prog_len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        pos += 4;
        if (bytes.len < pos + prog_len) return error.MalformedTransaction;
        const program = try allocator.dupe(u8, bytes[pos..][0..prog_len]);
        errdefer allocator.free(program);
        pos += prog_len;
        if (bytes.len < pos + 8 + 8 + 1 + 1) return error.MalformedTransaction;
        const gas_budget = std.mem.readInt(u64, bytes[pos..][0..8], .big);
        pos += 8;
        const sequence = std.mem.readInt(u64, bytes[pos..][0..8], .big);
        pos += 8;
        const has_sig = bytes[pos];
        pos += 1;
        var signature: ?[64]u8 = null;
        if (has_sig != 0) {
            if (bytes.len < pos + 64) return error.MalformedTransaction;
            signature = bytes[pos..][0..64].*;
            pos += 64;
        }
        const has_pk = bytes[pos];
        pos += 1;
        var public_key: ?[32]u8 = null;
        if (has_pk != 0) {
            if (bytes.len < pos + 32) return error.MalformedTransaction;
            public_key = bytes[pos..][0..32].*;
            pos += 32;
        }
        return .{
            .sender = sender,
            .inputs = inputs,
            .program = program,
            .gas_budget = gas_budget,
            .sequence = sequence,
            .signature = signature,
            .public_key = public_key,
        };
    }

    /// Verify the transaction signature
    /// SECURITY: Returns false if no signature is provided.
    /// Previously returned true for unsigned txs - signature bypass vulnerability!
    pub fn verifySignature(self: Self) bool {
        // SECURITY FIX: No signature = verification FAILS
        const sig = self.signature orelse return false;
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
            .pending = std.ArrayList(Transaction).empty,
            .verified = std.ArrayList(Transaction).empty,
        };
        // Pre-allocate based on max_pending to avoid reallocations
        try self.pending.ensureTotalCapacity(allocator, config.max_pending);
        try self.verified.ensureTotalCapacity(allocator, config.max_pending / 2);
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
        self.allocator.destroy(self);
    }

    /// Submit a new transaction (deep-copies slices so Ingress owns the data)
    pub fn submit(self: *Self, transaction: Transaction) !void {
        if (self.pending.items.len >= self.config.max_pending) {
            return error.TooManyPending;
        }
        var tx_copy = transaction;
        tx_copy.inputs = try self.allocator.dupe(core.ObjectID, transaction.inputs);
        tx_copy.program = try self.allocator.dupe(u8, transaction.program);
        try self.pending.append(self.allocator, tx_copy);
    }

    /// Verify pending transactions with full signature verification
    pub fn verify(self: *Self) !void {
        // Move transactions from pending to verified after verification
        while (self.pending.items.len > 0) {
            var tx = self.pending.pop().?;
            // 1. Check minimum gas budget
            if (tx.gas_budget < self.config.min_gas_budget) {
                tx.deinit(self.allocator);
                continue;
            }

            // 2. Verify signature if required
            if (self.config.require_signatures) {
                if (!tx.verifySignature()) {
                    tx.deinit(self.allocator);
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
    const config = IngressConfig{ .require_signatures = false };
    var ingress = try Ingress.init(allocator, config);
    defer ingress.deinit();

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
    const sig = try Signature.sign(&digest, keypair.secret_key, .ed25519);
    tx.signature = sig.bytes;
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

    var tx = Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "test program"),
        .gas_budget = 1000,
        .sequence = 1,
        .signature = null, // No signature
        .public_key = null,
    };
    defer tx.deinit(allocator);

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

    try ingress.submit(tx);
    try ingress.verify();

    // Transaction SHOULD be verified because signature requirement is disabled
    try std.testing.expect(ingress.verifiedCount() == 1);
}
