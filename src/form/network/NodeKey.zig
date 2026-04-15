//! NodeKey - Persistent cryptographic identity for P2P nodes
//!
//! Handles:
//! - Ed25519 key pair generation
//! - Secure storage to disk
//! - Loading on startup
//! - Peer ID derivation from public key

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

pub const KEY_VERSION: u32 = 1;
pub const KEY_FILE_NAME = "node_key.pem";

pub const NodeKey = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data_dir: []const u8,
    public_key: [32]u8,
    secret_key: [64]u8,

    /// Initialize or load node key
    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .data_dir = try allocator.dupe(u8, data_dir),
            .public_key = undefined,
            .secret_key = undefined,
        };

        const key_path = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, KEY_FILE_NAME });
        defer allocator.free(key_path);

        // Try to load existing key
        if (loadKeyFromFile(key_path, &self.secret_key, &self.public_key)) {
            return self;
        }

        // Generate new key pair
        try generateKeyPair(&self.secret_key, &self.public_key);

        // Save to disk
        try saveKeyToFile(key_path, self.secret_key, self.public_key);

        return self;
    }

    /// Deinitialize and free memory
    pub fn deinit(self: *Self) void {
        // Zero out sensitive key material before freeing
        @memset(&self.secret_key, 0);
        self.allocator.free(self.data_dir);
        self.allocator.destroy(self);
    }

    /// Get peer ID (BLAKE3 hash of public key)
    pub fn peerId(self: *Self) [32]u8 {
        var ctx = Blake3.init(.{});
        ctx.update(&self.public_key);
        var id: [32]u8 = undefined;
        ctx.final(&id);
        return id;
    }

    /// Get public key bytes
    pub fn getPublicKey(self: *Self) *[32]u8 {
        return &self.public_key;
    }
};

/// Generate Ed25519 key pair
fn generateKeyPair(secret_key: *[64]u8, public_key: *[32]u8) !void {
    // Use std.crypto.sign.Ed25519 for key generation
    // Ed25519 key pair: first 32 bytes are the secret, next 32 are the public key
    const seed = generateSeed();

    const ctx = std.crypto.sign.Ed25519.createKeyPair(seed) catch {
        return error.KeyGenerationFailed;
    };

    secret_key.* = ctx.secret_key;
    public_key.* = ctx.public_key;
}

/// Generate random seed for key generation
fn generateSeed() [32]u8 {
    var seed: [32]u8 = undefined;
    std.crypto.random.bytes(&seed);
    return seed;
}

/// Load key from PEM file
fn loadKeyFromFile(path: []const u8, secret_key: *[64]u8, public_key: *[32]u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    // Read file content
    var content: [1024]u8 = undefined;
    const bytes_read = file.readAll(&content) catch return false;
    if (bytes_read < 128) return false; // Need at least 128 bytes for key

    // Simple PEM-like format: "ZKNOT3_KEY_V1\n" + hex(secret_key || public_key)
    var pos: usize = 0;

    // Skip header line
    while (pos < bytes_read and content[pos] != '\n') : (pos += 1) {}
    pos += 1;
    if (pos >= bytes_read) return false;

    // Decode hex (simplified - just copy raw bytes for now)
    // In production, use proper hex decode
    const key_data = content[pos..];
    if (key_data.len < 64) return false;

    @memcpy(secret_key[0..32], key_data[0..32]);
    @memcpy(public_key[0..32], key_data[32..64]);

    // Verify key pair matches
    const expected_pk = derivePublicKey(secret_key[0..32]) catch return false;
    if (!std.mem.eql(u8, public_key, &expected_pk)) return false;

    return true;
}

/// Save key to PEM file
fn saveKeyToFile(path: []const u8, secret_key: [64]u8, public_key: [32]u8) !void {
    // Create data directory if needed
    const dir = try std.fs.cwd().makeOpenPath(std.fs.path.dirname(path).?, .{});
    defer dir.close();

    const file = try dir.createFile(std.fs.path.basename(path), .{});
    defer file.close();

    // Write header
    try file.writeAll("ZKNOT3_KEY_V1\n");

    // Write key data as hex
    for (secret_key[0..32]) |b| {
        try file.writeAll(std.fmt.formatHex(b, .{}));
    }
    for (public_key) |b| {
        try file.writeAll(std.fmt.formatHex(b, .{}));
    }
    try file.writeAll("\n");
}

/// Derive public key from secret seed
fn derivePublicKey(seed: [32]u8) ![32]u8 {
    const ctx = std.crypto.sign.Ed25519.createKeyPair(seed) catch {
        return error.InvalidSeed;
    };
    return ctx.public_key;
}

test "NodeKey generation" {
    const allocator = std.testing.allocator;

        // Use temp directory
        const tmp_dir = "/tmp/zknot3_test_keys";
    // Create temp dir if not exists
    std.fs.cwd().makeDir(tmp_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // First init - should generate new key
    var key1 = try NodeKey.init(allocator, tmp_dir);
    defer key1.deinit();

    const peer_id1 = key1.peerId();

    // Second init - should load existing key
    var key2 = try NodeKey.init(allocator, tmp_dir);
    defer key2.deinit();

    const peer_id2 = key2.peerId();

    // Peer IDs should match (same key loaded)
    try std.testing.expect(std.mem.eql(u8, &peer_id1, &peer_id2));
}

test "Peer ID derivation" {
        const allocator = std.testing.allocator;
        const tmp_dir = "/tmp/zknot3_test_keys2";
    // Create temp dir if not exists
    std.fs.cwd().makeDir(tmp_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var key = try NodeKey.init(allocator, tmp_dir);
    defer key.deinit();

    const peer_id = key.peerId();

    // Peer ID should be non-zero
    var all_zero = true;
    for (peer_id) |b| {
        if (b != 0) all_zero = false;
    }
    try std.testing.expect(!all_zero);
}
