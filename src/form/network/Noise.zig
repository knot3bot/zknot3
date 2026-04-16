//! Noise Protocol Framework for encrypted connections
//!
//! Reference: rust-libp2p noise implementation
//!
//! The Noise Protocol Framework provides:
//! - Authenticated key exchange
//! - Forward secrecy
//! - Identity hiding (optional)
//! - 0-RTT / 1-RTT handshake patterns

const std = @import("std");
const core = @import("../../core.zig");

/// X25519 scalar size
const SCALAR_SIZE = 32;
/// X25519 point size
const POINT_SIZE = 32;

/// BLAKE3 hash output size
const HASHLEN = 32;

pub const NoisePublicKey = struct {
    bytes: [POINT_SIZE]u8,
};

pub const NoiseSecretKey = struct {
    bytes: [SCALAR_SIZE]u8,

    /// Generate a new random secret key
    pub fn generate() @This() {
        var key: @This() = undefined;
        @import("io_instance").io.random(&key.bytes);
        // Ensure scalar is valid (clamp bits as per X25519 spec)
        key.bytes[0] &= 248;
        key.bytes[31] &= 127;
        key.bytes[31] |= 64;
        return key;
    }

    /// Derive public key from secret key using X25519 scalar multiplication
    pub fn toPublic(self: *const @This()) NoisePublicKey {
        // X25519 base point (the generator)
        const base_point = [POINT_SIZE]u8{
            9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        };
        // Perform X25519 scalar multiplication: result = scalar * point
        return .{ .bytes = std.crypto.dh.X25519.scalarMult(base_point, self.bytes) };
    }
};

pub const NoiseKeypair = struct {
    const Self = @This();

    pub const Public = NoisePublicKey;
    pub const Secret = NoiseSecretKey;

    secret: NoiseSecretKey,
    public: NoisePublicKey,

    pub fn generate() !*Self {
        const self = try std.heap.general_allocator.create(Self);
        self.* = .{
            .secret = NoiseSecretKey.generate(),
            .public = undefined,
        };
        self.public = self.secret.toPublic();
        return self;
    }

    pub fn fromSecretKey(secret: NoiseSecretKey) !*Self {
        const self = try std.heap.general_allocator.create(Self);
        self.* = .{
            .secret = secret,
            .public = secret.toPublic(),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Zero out sensitive data before deallocating
        @memset(&self.secret.bytes, 0);
        @memset(&self.public.bytes, 0);
        std.heap.general_allocator.destroy(self);
    }
};

pub const NONCELEN = 12;
pub const MAX_MESSAGE_SIZE = 65535;

/// HMAC-SHA256 helper for proper HKDF construction
fn hmacSha256(key: []const u8, data: []const u8, out: *[32]u8) void {
    // Use std.crypto.auth.mac.Hmac with Sha256
    const Hmac = std.crypto.auth.mac.Hmac;
    const sha256 = std.crypto.hash.sha2.Sha256;
    var mac = Hmac(sha256).init(key);
    mac.update(data);
    mac.final(out);
}

pub const CipherState = struct {
    const Self = @This();

    /// Symmetric encryption key
    k: [32]u8,
    /// Nonce counter
    n: u64,

    pub fn init(k: [32]u8) Self {
        return .{
            .k = k,
            .n = 0,
        };
    }

    /// Encrypt a message with ChaCha20-Poly1305
    /// Uses AEAD construction with incremental nonces
    pub fn encrypt(self: *Self, plaintext: []const u8, dest: []u8) !void {
        if (plaintext.len > MAX_MESSAGE_SIZE - 16) {
            return error.MessageTooLarge;
        }

        // Build 12-byte nonce from counter
        var nonce: [12]u8 = [_]u8{0} ** 12;
        std.mem.writeIntLittle(u64, &nonce, self.n);

        // Seal (encrypt + authenticate)
        const tag = std.crypto.aead.ChaCha20Poly1305.seal(
            dest[0..plaintext.len],
            plaintext,
            null,
            nonce,
            self.k,
        );

        // Append authentication tag
        @memcpy(dest[plaintext.len..][0..16], &tag);
        self.n +%= 1;
    }

    /// Decrypt a message with ChaCha20-Poly1305
    pub fn decrypt(self: *Self, ciphertext: []const u8, dest: []u8) !void {
        if (ciphertext.len < 16) {
            return error.CiphertextTooShort;
        }

        // Build 12-byte nonce from counter
        var nonce: [12]u8 = [_]u8{0} ** 12;
        std.mem.writeIntLittle(u64, &nonce, self.n);

        const plaintext_len = ciphertext.len - 16;

        // Open (decrypt + verify)
        try std.crypto.aead.ChaCha20Poly1305.open(
            dest[0..plaintext_len],
            ciphertext[0..plaintext_len],
            ciphertext[plaintext_len..][0..16],
            nonce,
            self.k,
        );

        self.n +%= 1;
    }
};

pub const SymmetricState = struct {
    const Self = @This();

    /// Protocol name
    name: []const u8,
    /// Hash state
    hash: [HASHLEN]u8,
    /// Cipher state for encryption
    enc: CipherState,
    /// Cipher state for decryption
    dec: CipherState,
    /// Chaining key for mixHash and mixKey
    ck: [HASHLEN]u8,

    pub fn init(name: []const u8, protocol_name: []const u8) !Self {
        var hash_input: [64]u8 = undefined;
        @memcpy(hash_input[0..name.len], name);
        @memcpy(hash_input[name.len..][0..protocol_name.len], protocol_name);

        // Initialize hash with protocol name
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&hash_input);
        var hash: [HASHLEN]u8 = undefined;
        ctx.final(&hash);

        return .{
            .name = name,
            .hash = hash,
            .enc = CipherState.init(hash),
            .dec = CipherState.init(hash),
            .ck = hash,
        };
    }

    /// MixHash updates the hash (for handshake messages)
    pub fn mixHash(self: *Self, data: []const u8) void {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&self.hash);
        ctx.update(data);
        ctx.final(&self.hash);
    }

    /// MixKey derives a new key using HKDF-SHA256 construction
    /// Per RFC 5869 and Noise spec:
    ///   1. ck = HMAC-SHA256(ck, dh_output)
    ///   2. temp_key = HMAC-SHA256(ck, 0x01)
    ///   3. ck = temp_key (but we keep separate ck for chaining)
    pub fn mixKey(self: *Self, data: []const u8) void {
        // Extract: prk = HMAC-SHA256(ck, data)
        var prk: [32]u8 = undefined;
        hmacSha256(&self.ck, data, &prk);

        // Expand: output = HMAC-SHA256(prk, 0x01)
        const info_byte = [_]u8{0x01};
        var temp_key: [32]u8 = undefined;
        hmacSha256(&prk, &info_byte, &temp_key);

        // Update chaining key
        @memcpy(&self.ck, &prk);

        // Set encryption key
        @memcpy(&self.enc.k, &temp_key);
        @memcpy(&self.dec.k, &temp_key);

        // Reinitialize cipher states with new keys
        self.enc = CipherState.init(self.enc.k);
        self.dec = CipherState.init(self.dec.k);
    }

    /// Encrypt and mix hash
    pub fn encryptAndHash(self: *Self, plaintext: []const u8, dest: []u8) !void {
        try self.enc.encrypt(plaintext, dest);
        self.mixHash(dest[0..plaintext.len]);
    }

    /// Decrypt and mix hash
    pub fn decryptAndHash(self: *Self, ciphertext: []const u8, dest: []u8) !void {
        const plaintext_len = ciphertext.len - 16;
        try self.dec.decrypt(ciphertext, dest);
        self.mixHash(dest[0..plaintext_len]);
    }

    /// Split cipher states for symmetric communication
    pub fn split(self: *Self, enc: *CipherState, dec: *CipherState) void {
        enc.* = self.enc;
        dec.* = self.dec;
    }
};

/// Noise XX pattern handshake state
pub const HandshakeState = struct {
    const Self = @This();
    const Role = enum { initiator, responder };

    role: Role,
    s: ?*const NoiseKeypair,
    e: ?NoiseSecretKey,
    rs: ?NoisePublicKey,
    re: ?NoisePublicKey,

    symmetric: SymmetricState,

    /// X25519 Diffie-Hellman key exchange
    /// Performs scalar multiplication: local_secret * remote_public
    fn dh(local_secret: *const NoiseSecretKey, remote_public: *const NoisePublicKey) [32]u8 {
        return std.crypto.dh.X25519.scalarMult(remote_public.bytes, local_secret.bytes);
    }

    pub fn init(role: Role, keypair: ?*const NoiseKeypair, protocol_name: []const u8) !Self {
        const name = if (role == .initiator) "Noise_XX" else "Noise_XX";
        const sym = try SymmetricState.init(name, protocol_name);
        return .{
            .role = role,
            .s = keypair,
            .e = null,
            .rs = null,
            .re = null,
            .symmetric = sym,
        };
    }

    pub fn initiatorStep1(self: *Self) ![]u8 {
        // Generate ephemeral key pair
        self.e = NoiseSecretKey.generate();

        // Message payload: e (ephemeral public key)
        var msg = std.ArrayList(u8).init(std.heap.general_allocator);
        try msg.appendSlice(&self.e.?.toPublic().bytes);

        return msg.toOwnedSlice();
    }

    pub fn responderStep1(self: *Self, msg: []const u8) !void {
        // Read e from message
        if (msg.len < POINT_SIZE) return error.MessageTooShort;
        self.re = .{ .bytes = msg[0..POINT_SIZE].* };

        // Generate ephemeral key
        self.e = NoiseSecretKey.generate();

        // MixHash(e)
        self.symmetric.mixHash(msg[0..POINT_SIZE]);
    }

    pub fn responderStep2(self: *Self) ![]u8 {
        // Message payload: e, ee, s, es
        var msg = std.ArrayList(u8).init(std.heap.general_allocator);

        // e (our ephemeral public key)
        try msg.appendSlice(&self.e.?.toPublic().bytes);

        // DH(e, re) - compute shared secret
        if (self.e) |ephemeral| {
            if (self.re) |remote_ephemeral| {
                const dh_ee = dh(&ephemeral, &remote_ephemeral);
                self.symmetric.mixKey(&dh_ee);
            }
        }

        // s (our static key if we have one)
        if (self.s) |static_key| {
            try msg.appendSlice(&static_key.public.bytes);

            // DH(s, re) - static key exchange
            const dh_se = dh(&static_key.secret, self.re.?);
            self.symmetric.mixKey(&dh_se);
        }

        // MixHash(payload)
        self.symmetric.mixHash(msg.items);

        // Encrypt static key payload
        if (self.s) |_| {
            const encrypted = try std.heap.general_allocator.alloc(u8, msg.items.len + 16);
            errdefer std.heap.general_allocator.free(encrypted);

            try self.symmetric.encryptAndHash(msg.items, encrypted);

            std.heap.general_allocator.free(msg.items);
            return encrypted;
        }

        return msg.toOwnedSlice();
    }

    pub fn initiatorStep2(self: *Self, msg: []const u8) !void {
        // Decrypt and process responder's message
        self.symmetric.mixHash(msg);

        if (self.re == null and msg.len >= POINT_SIZE) {
            self.re = .{ .bytes = msg[0..POINT_SIZE].* };

            if (self.e) |ephemeral| {
                const dh_ee = dh(&ephemeral, &self.re.?);
                self.symmetric.mixKey(&dh_ee);
            }
        }
    }

    pub fn initiatorStep3(self: *Self) ![]u8 {
        var msg = std.ArrayList(u8).init(std.heap.general_allocator);

        // s (our static key)
        if (self.s) |static_key| {
            try msg.appendSlice(&static_key.public.bytes);

            const dh_se = dh(&static_key.secret, self.re orelse return error.MissingRemoteKey);
            self.symmetric.mixKey(&dh_se);
        }

        // MixHash(payload)
        self.symmetric.mixHash(msg.items);

        // Encrypt and return
        if (self.s) |_| {
            const encrypted = try std.heap.general_allocator.alloc(u8, msg.items.len + 16);
            errdefer std.heap.general_allocator.free(encrypted);

            try self.symmetric.encryptAndHash(msg.items, encrypted);
            std.heap.general_allocator.free(msg.items);
            return encrypted;
        }

        return msg.toOwnedSlice();
    }

    pub fn responderStep3(self: *Self, msg: []const u8) !void {
        // Process initiator's final message
        self.symmetric.mixHash(msg);
        // At this point, if we have their static key, we can authenticate
    }

    /// Get the resulting cipher states for symmetric communication
    pub fn getCipherStates(self: *Self, enc: *CipherState, dec: *CipherState) void {
        self.symmetric.split(enc, dec);
    }
};

pub const NoiseSession = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    handshake: ?*HandshakeState,
    enc: CipherState,
    dec: CipherState,
    is_handshake_complete: bool,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .handshake = null,
            .enc = undefined,
            .dec = undefined,
            .is_handshake_complete = false,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.handshake) |h| {
            h.*.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Initiate a new handshake as the initiator
    pub fn initiate(self: *Self, keypair: ?*const NoiseKeypair, protocol_name: []const u8) !void {
        self.handshake = try std.heap.general_allocator.create(HandshakeState);
        self.handshake.?.* = try HandshakeState.init(.initiator, keypair, protocol_name);
    }

    /// Respond to a handshake as the responder
    pub fn respond(self: *Self, keypair: ?*const NoiseKeypair, protocol_name: []const u8) !void {
        self.handshake = try std.heap.general_allocator.create(HandshakeState);
        self.handshake.?.* = try HandshakeState.init(.responder, keypair, protocol_name);
    }

    /// Get the next handshake message to send
    pub fn getHandshakeMessage(self: *Self) ![]u8 {
        if (self.handshake) |h| {
            if (h.role == .initiator) {
                return try h.initiatorStep1();
            }
        }
        return error.HandshakeNotStarted;
    }

    /// Process a received handshake message
    pub fn processHandshakeMessage(self: *Self, msg: []const u8) ![]u8 {
        if (self.handshake) |h| {
            if (h.role == .responder) {
                try h.responderStep1(msg);
                return try h.responderStep2();
            } else {
                try h.initiatorStep2(msg);
                return try h.initiatorStep3();
            }
        }
        return error.HandshakeNotStarted;
    }

    /// Finalize the handshake
    pub fn finalize(self: *Self) !void {
        if (self.handshake) |h| {
            h.getCipherStates(&self.enc, &self.dec);
            self.is_handshake_complete = true;
        }
    }

    /// Encrypt data
    pub fn encrypt(self: *Self, plaintext: []const u8, dest: []u8) !void {
        if (!self.is_handshake_complete) return error.HandshakeIncomplete;
        try self.enc.encrypt(plaintext, dest);
    }

    /// Decrypt data
    pub fn decrypt(self: *Self, ciphertext: []const u8, dest: []u8) !void {
        if (!self.is_handshake_complete) return error.HandshakeIncomplete;
        try self.dec.decrypt(ciphertext, dest);
    }
};

test "NoiseKeypair generation" {
    const keypair = try NoiseKeypair.generate();
    defer keypair.deinit();

    // Public key should be derived from secret via X25519
    const pubkey = keypair.secret.toPublic();
    try std.testing.expect(!std.mem.eql(u8, &keypair.secret.bytes, &pubkey.bytes));
}

test "CipherState encrypt/decrypt" {
    var key: [32]u8 = undefined;
    @import("io_instance").io.random(&key);

    var cipher = CipherState.init(key);

    const plaintext = "hello world";
    var ciphertext: [100]u8 = undefined;
    try cipher.encrypt(plaintext, &ciphertext);

    var decrypted: [100]u8 = undefined;
    try cipher.decrypt(&ciphertext, &decrypted);

    try std.testing.expect(std.mem.eql(u8, plaintext, &decrypted[0..plaintext.len]));
}

test "SymmetricState mixHash" {
    const sym = try SymmetricState.init("test", "protocol");

    var data: [16]u8 = undefined;
    @import("io_instance").io.random(&data);

    const hash_before = sym.hash;
    _ = sym.mixHash(&data);

    // Hash should change after mixHash
    try std.testing.expect(!std.mem.eql(u8, &hash_before, &sym.hash));
}

test "NoiseSession initiate/respond" {
    const allocator = std.testing.allocator;

    const initiator = try NoiseSession.init(allocator);
    defer initiator.deinit();

    const responder = try NoiseSession.init(allocator);
    defer responder.deinit();

    const keypair = try NoiseKeypair.generate();
    defer keypair.deinit();

    try initiator.initiate(keypair, "test-protocol");
    try responder.respond(keypair, "test-protocol");

    // Get first message from initiator
    const msg1 = try initiator.getHandshakeMessage();
    defer allocator.free(msg1);

    // Process as responder and get response
    const msg2 = try responder.processHandshakeMessage(msg1);
    defer allocator.free(msg2);

    // Process as initiator
    const msg3 = try initiator.processHandshakeMessage(msg2);
    defer allocator.free(msg3);

    // Finalize both
    try initiator.finalize();
    try responder.finalize();

    try std.testing.expect(initiator.is_handshake_complete);
    try std.testing.expect(responder.is_handshake_complete);
}
