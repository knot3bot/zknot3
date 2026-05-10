//! Noise Protocol Framework for encrypted connections.
//!
//! Implements the Noise XX handshake pattern (3-message, mutual auth).
//! Key derivation via HMAC-SHA256, symmetric encryption via ChaCha20-Poly1305.
//!
//! Supported:
//! - Authenticated key exchange (X25519 DH)
//! - Forward secrecy (ephemeral keys per session)
//! - CipherState split with independent directional keys
//! - Nonce tracking with documented wrap-around safety limit (2^64 messages)
//!
//! Not implemented:
//! - 0-RTT / PSK patterns (fallback, IK, KK)
//! - Identity hiding (static keys are transmitted as public keys)
//! - Protocol name negotiation (hardcoded to Noise_XX)

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
    /// Nonce counter. Uses wrapping addition — after 2^64 encryptions the nonce
    /// wraps to 0 which BREAKS ChaCha20-Poly1305 security. Production deployments
    /// MUST re-key (via a new Noise handshake) well before this limit (~1.8e19 messages).
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
        // Hash protocol name components incrementally — avoids stack buffer overflow
        // on long protocol names that would exceed the fixed 64-byte buffer.
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(name);
        ctx.update(protocol_name);
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

    /// Encrypt and mix hash — per Noise spec, mixes full ciphertext including auth tag
    pub fn encryptAndHash(self: *Self, plaintext: []const u8, dest: []u8) !void {
        try self.enc.encrypt(plaintext, dest);
        // dest contains: ciphertext[0..plaintext.len] + auth_tag[plaintext.len..plaintext.len+16]
        self.mixHash(dest[0 .. plaintext.len + 16]);
    }

    /// Decrypt and mix hash — per Noise spec, mixes the ciphertext (not plaintext)
    pub fn decryptAndHash(self: *Self, ciphertext: []const u8, dest: []u8) !void {
        try self.dec.decrypt(ciphertext, dest);
        // Mix the full ciphertext including auth tag, per Noise spec section 5
        self.mixHash(ciphertext);
    }

    /// Split cipher states for symmetric communication.
    /// Per Noise spec section 5: derives two independent CipherState keys
    /// from the chaining key via HKDF, ensuring forward secrecy in both directions.
    pub fn split(self: *Self, enc: *CipherState, dec: *CipherState) void {
        // HKDF-expand: derive two 32-byte keys from the chaining key
        var enc_key: [32]u8 = undefined;
        var dec_key: [32]u8 = undefined;

        // Derive enc key: HMAC-SHA256(ck, [0x01])
        var ctx = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.ck);
        ctx.update(&[_]u8{1});
        ctx.final(&enc_key);

        // Derive dec key: HMAC-SHA256(ck, enc_key || [0x02])
        ctx = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.ck);
        ctx.update(&enc_key);
        ctx.update(&[_]u8{2});
        ctx.final(&dec_key);

        enc.* = CipherState.init(enc_key);
        dec.* = CipherState.init(dec_key);
    }
};

/// Noise XX pattern handshake state
pub const HandshakeState = struct {
    const Self = @This();
    const Role = enum { initiator, responder };
    const Step = enum(u8) { step1, step2, step3, done };

    role: Role,
    handshake_step: Step,
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
            .handshake_step = .step1,
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

        // Noise spec: output e, then MixHash(e.public_key)
        const e_bytes = self.e.?.toPublic().bytes;
        self.symmetric.mixHash(&e_bytes);

        // Return e in plaintext
        var result: [32]u8 = undefined;
        @memcpy(&result, &e_bytes);
        return try std.heap.general_allocator.dupe(u8, &result);
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
        // Noise XX responder step 2: send e (plaintext) || ee || s (encrypted) || es
        // Per Noise spec: e must be plaintext so initiator can compute DH(e, re).
        // Only the static key s is encrypted.

        // e (our ephemeral public key) — always plaintext
        const e_bytes = self.e.?.toPublic().bytes;

        // DH(e, re) - compute shared secret
        if (self.e) |ephemeral| {
            if (self.re) |remote_ephemeral| {
                const dh_ee = dh(&ephemeral, &remote_ephemeral);
                self.symmetric.mixKey(&dh_ee);
            }
        }

        // MixHash of the plaintext ephemeral key before encryption
        self.symmetric.mixHash(&e_bytes);

        // s (our static key) — encrypted
        if (self.s) |static_key| {
            // DH(s, re)
            const dh_se = dh(&static_key.secret, self.re.?);
            self.symmetric.mixKey(&dh_se);

            // Encrypt the static key
            const s_bytes = static_key.public.bytes;
            var encrypted_s: [32 + 16]u8 = undefined;
            try self.symmetric.encryptAndHash(&s_bytes, &encrypted_s);

            // Output: e (32 bytes) || encrypted(s) (48 bytes)
            var result = try std.heap.general_allocator.alloc(u8, 32 + 48);
            @memcpy(result[0..32], &e_bytes);
            @memcpy(result[32..80], &encrypted_s);
            return result;
        }

        // No static key: just send e in plaintext
        var result = try std.heap.general_allocator.alloc(u8, 32);
        @memcpy(result[0..32], &e_bytes);
        return result;
    }

    pub fn initiatorStep2(self: *Self, msg: []const u8) !void {
        // Noise XX initiator msg2 processing: e (plain) || ee || s (encrypted) || es
        // 1. Extract responder's ephemeral key e
        if (msg.len < 32) return error.MessageTooShort;
        self.re = .{ .bytes = msg[0..32].* };
        self.symmetric.mixHash(msg[0..32]); // MixHash(e)

        // 2. DH(e, re) → MixKey
        const dh_ee = dh(&self.e.?, &self.re.?);
        self.symmetric.mixKey(&dh_ee);

        // 3. Decrypt responder's static key s (remaining 48 bytes = 32 + 16 tag)
        if (msg.len < 80) return error.MessageTooShort;
        var decrypted_s: [32]u8 = undefined;
        self.symmetric.decryptAndHash(msg[32..80], &decrypted_s);
        self.rs = .{ .bytes = decrypted_s };

        // 4. DH(s, re) = es → MixKey
        if (self.s) |static_key| {
            const dh_se = dh(&static_key.secret, self.rs.?);
            self.symmetric.mixKey(&dh_se);
        }
    }

    pub fn initiatorStep3(self: *Self) ![]u8 {
        // Noise XX initiator msg3: s (encrypted) || se
        // 1. EncryptAndHash our static public key
        if (self.s) |static_key| {
            const s_bytes = static_key.public.bytes;
            var encrypted_s: [32 + 16]u8 = undefined;
            try self.symmetric.encryptAndHash(&s_bytes, &encrypted_s);

            // 2. DH(s, re) = se → MixKey
            const dh_se = dh(&static_key.secret, self.re orelse return error.MissingRemoteKey);
            self.symmetric.mixKey(&dh_se);

            return try std.heap.general_allocator.dupe(u8, &encrypted_s);
        }

        // No static key: send empty message
        return &.{};
    }

    pub fn responderStep3(self: *Self, msg: []const u8) !void {
        // Noise XX responder msg3: decrypt initiator's static key s || se
        // 1. DecryptAndHash initiator's static public key
        if (msg.len < 48) return error.MessageTooShort;
        var decrypted_s: [32]u8 = undefined;
        self.symmetric.decryptAndHash(msg[0..48], &decrypted_s);
        self.rs = .{ .bytes = decrypted_s };

        // 2. DH(e, rs) = se → MixKey
        if (self.e) |ephemeral| {
            const dh_se = dh(&ephemeral, &self.rs.?);
            self.symmetric.mixKey(&dh_se);
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
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
            h.deinit();
            self.allocator.destroy(h);
        }
        self.allocator.destroy(self);
    }

    /// Initiate a new handshake as the initiator
    pub fn initiate(self: *Self, keypair: ?*const NoiseKeypair, protocol_name: []const u8) !void {
        self.handshake = try self.allocator.create(HandshakeState);
        self.handshake.?.* = try HandshakeState.init(.initiator, keypair, protocol_name);
    }

    /// Respond to a handshake as the responder
    pub fn respond(self: *Self, keypair: ?*const NoiseKeypair, protocol_name: []const u8) !void {
        self.handshake = try self.allocator.create(HandshakeState);
        self.handshake.?.* = try HandshakeState.init(.responder, keypair, protocol_name);
    }

    /// Get the next handshake message to send
    pub fn getHandshakeMessage(self: *Self) ![]u8 {
        if (self.handshake) |h| {
            if (h.role == .initiator and h.handshake_step == .step1) {
                const msg = try h.initiatorStep1();
                h.handshake_step = .step2;
                return msg;
            }
        }
        return error.HandshakeNotStarted;
    }

    /// Process a received handshake message. Returns the next message to send
    /// (or empty slice if handshake is complete).
    pub fn processHandshakeMessage(self: *Self, msg: []const u8) ![]u8 {
        if (self.handshake) |h| {
            switch (h.role) {
                .responder => switch (h.handshake_step) {
                    .step1 => {
                        try h.responderStep1(msg);
                        h.handshake_step = .step2;
                        return try h.responderStep2();
                    },
                    .step2 => {
                        try h.responderStep3(msg);
                        h.handshake_step = .done;
                        self.is_handshake_complete = true;
                        return &.{};
                    },
                    else => return error.HandshakeNotStarted,
                },
                .initiator => switch (h.handshake_step) {
                    .step1 => {
                        // initiatorStep1 is called via getHandshakeMessage, not here
                        return error.HandshakeNotStarted;
                    },
                    .step2 => {
                        try h.initiatorStep2(msg);
                        h.handshake_step = .step3;
                        return try h.initiatorStep3();
                    },
                    else => return error.HandshakeNotStarted,
                },
            }
        }
        return error.HandshakeNotStarted;
    }

    /// Finalize the handshake — derives cipher states if not already done.
    pub fn finalize(self: *Self) !void {
        if (self.is_handshake_complete) return;
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

test "NoiseSession full handshake with encrypt/decrypt round-trip" {
    const allocator = std.testing.allocator;

    const initiator = try NoiseSession.init(allocator);
    defer initiator.deinit();
    const responder = try NoiseSession.init(allocator);
    defer responder.deinit();

    const keypair = try NoiseKeypair.generate();
    defer keypair.deinit();

    try initiator.initiate(keypair, "test-protocol");
    try responder.respond(keypair, "test-protocol");

    const msg1 = try initiator.getHandshakeMessage();
    defer allocator.free(msg1);
    const msg2 = try responder.processHandshakeMessage(msg1);
    defer allocator.free(msg2);
    const msg3 = try initiator.processHandshakeMessage(msg2);
    defer allocator.free(msg3);
    // Responder processes initiator's final message
    _ = try responder.processHandshakeMessage(msg3);

    try initiator.finalize();
    try responder.finalize();

    // Verify encrypt/decrypt round-trip (initiator → responder)
    const plaintext = "hello zknot3 noise";
    var ciphertext: [32 + 16]u8 = undefined; // plaintext + auth tag
    try initiator.encrypt(plaintext, &ciphertext);

    var decrypted: [32 + 16]u8 = undefined;
    try responder.decrypt(&ciphertext, decrypted[0..plaintext.len]);
    try std.testing.expect(std.mem.eql(u8, plaintext, decrypted[0..plaintext.len]));

    // Verify reverse direction (responder → initiator)
    const reply = "zknot3 ack";
    var reply_ct: [16 + 16]u8 = undefined;
    try responder.encrypt(reply, &reply_ct);

    var reply_decrypted: [16 + 16]u8 = undefined;
    try initiator.decrypt(&reply_ct, reply_decrypted[0..reply.len]);
    try std.testing.expect(std.mem.eql(u8, reply, reply_decrypted[0..reply.len]));
}
