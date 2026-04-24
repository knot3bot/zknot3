const std = @import("std");

pub const HexBytes = struct {
    /// Owns the decoded bytes.
    bytes: []u8,

    pub fn deinit(self: *HexBytes, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn decodeHexAlloc(allocator: std.mem.Allocator, hex: []const u8) !HexBytes {
    var clean = hex;
    if (std.mem.startsWith(u8, clean, "0x")) clean = clean[2..];
    if (clean.len % 2 != 0) return error.InvalidHex;

    const out = try allocator.alloc(u8, clean.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, clean);
    return .{ .bytes = out };
}

pub const CheckpointProof = struct {
    sequence: u64,
    stateRoot: []const u8,
    proof: []const u8,
    signatures: []const u8,
    blsSignature: []const u8,
    blsSignerBitmap: []const u8,
};

pub const ValidatorInfo = struct {
    /// Voting power used for quorum calculation.
    voting_power: u64,
    /// BLS public key bytes (48 bytes compressed G1).
    bls_public_key: [48]u8,
};

/// SDK-side representation of a transaction (protocol v1 compatible).
pub const SdkTransaction = struct {
    sender: [32]u8,
    inputs: []const [32]u8,
    program: []const u8,
    gas_budget: u64,
    sequence: u64,
    signature: ?[64]u8 = null,
    public_key: ?[32]u8 = null,

    pub fn digest(self: SdkTransaction) [32]u8 {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&self.sender);
        for (self.inputs) |id| {
            ctx.update(&id);
        }
        ctx.update(self.program);
        var gas_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &gas_buf, self.gas_budget, .big);
        ctx.update(&gas_buf);
        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, self.sequence, .big);
        ctx.update(&seq_buf);
        var out: [32]u8 = undefined;
        ctx.final(&out);
        return out;
    }
};

/// Event query parameters for SDK consumers.
pub const EventQuery = struct {
    transaction_digest: ?[32]u8 = null,
    event_type: ?[]const u8 = null,
    start_time: ?i64 = null,
    end_time: ?i64 = null,
    limit: usize = 50,
    cursor: ?u64 = null,
};

/// Object query parameters for SDK consumers.
pub const ObjectQuery = struct {
    object_id: ?[32]u8 = null,
    owner: ?[32]u8 = null,
    object_type: ?[]const u8 = null,
    limit: usize = 50,
    cursor: ?[]const u8 = null,
};

/// Standardized SDK response envelope.
pub const SdkResponse = struct {
    success: bool,
    data: ?std.json.Value = null,
    err: ?SdkError = null,
    trace_id: ?[]const u8 = null,
};

pub const SdkError = struct {
    code: SdkErrorCode,
    message: []const u8,
};

pub const SdkErrorCode = enum(i32) {
    success = 0,
    transport = 1000,
    timeout = 1001,
    retry_exhausted = 1002,
    protocol_decode = 2000,
    protocol_invalid_response = 2001,
    rpc_error = 3000,
    node_missing_signing_key = 3001,
    invalid_signature = 4000,
    nonce_too_old = 4001,
    nonce_too_new = 4002,
    transaction_already_executed = 4003,
    rate_limited = 5000,
    service_unavailable = 5001,
    unknown = 9999,
};
