const std = @import("std");
const crypto = std.crypto;

/// Signature scheme discriminator
pub const SignatureScheme = enum {
    ed25519,
};

/// Public key wrapper
pub const PublicKey = struct {
    bytes: [32]u8,

    pub fn verify(self: PublicKey, message: []const u8, signature: Signature) bool {
        const pk = crypto.sign.Ed25519.PublicKey.fromBytes(self.bytes) catch return false;
        const sig = crypto.sign.Ed25519.Signature.fromBytes(signature.bytes);
        sig.verify(message, pk) catch return false;
        return true;
    }
};

/// Signature wrapper
pub const Signature = struct {
    bytes: [64]u8,
    scheme: SignatureScheme,

    pub fn verify(self: Signature, public_key: PublicKey, message: []const u8) bool {
        return public_key.verify(message, self);
    }
};

/// Key pair wrapper (stores 32-byte seed for compatibility with existing code)
pub const KeyPair = struct {
    secret_key: [32]u8,
    public_key: PublicKey,

    pub fn generate() !KeyPair {
        var seed: [32]u8 = undefined;
        @import("io_instance").io.random(&seed);
        const kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.KeyGenerationFailed;
        return .{
            .secret_key = seed,
            .public_key = .{ .bytes = kp.public_key.toBytes() },
        };
    }

    pub fn sign(self: KeyPair, message: []const u8) !Signature {
        const kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(self.secret_key) catch return error.SigningFailed;
        const sig = crypto.sign.Ed25519.KeyPair.sign(kp, message, null) catch return error.SigningFailed;
        return .{
            .bytes = sig.toBytes(),
            .scheme = .ed25519,
        };
    }

    pub fn deinit(self: *KeyPair) void {
        @memset(&self.secret_key, 0);
    }
};

/// Legacy compatibility: sign with raw 32-byte seed
pub fn sign(message: []const u8, secret_key: [32]u8, scheme: SignatureScheme) !Signature {
    _ = scheme;
    const kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(secret_key) catch return error.SigningFailed;
    const sig = crypto.sign.Ed25519.KeyPair.sign(kp, message, null) catch return error.SigningFailed;
    return .{
        .bytes = sig.toBytes(),
        .scheme = .ed25519,
    };
}

/// Legacy compatibility: verify with raw bytes
pub fn verify(public_key: [32]u8, message: []const u8, signature_bytes: [64]u8) bool {
    const pk = crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch return false;
    const sig = crypto.sign.Ed25519.Signature.fromBytes(signature_bytes);
    sig.verify(message, pk) catch return false;
    return true;
}

/// Expose real Ed25519 for Mysticeti.zig compatibility
pub const Ed25519 = struct {
    pub fn sign(private_key: [32]u8, message: []const u8) ![64]u8 {
        const kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(private_key) catch return error.SigningFailed;
        const sig = crypto.sign.Ed25519.KeyPair.sign(kp, message, null) catch return error.SigningFailed;
        return sig.toBytes();
    }

    pub fn verify(public_key: [32]u8, message: []const u8, signature: [64]u8) bool {
        const pk = crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch return false;
        const sig = crypto.sign.Ed25519.Signature.fromBytes(signature);
        sig.verify(message, pk) catch return false;
        return true;
    }
};

test "Real Ed25519 sign and verify" {
    const seed = [_]u8{1} ** 32;
    const message = "test message";
    const sig_bytes = try Ed25519.sign(seed, message);

    const real_kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.SigningFailed;
    const real_pk_bytes = real_kp.public_key.toBytes();

    try std.testing.expect(Ed25519.verify(real_pk_bytes, message, sig_bytes));
    try std.testing.expect(!Ed25519.verify(real_pk_bytes, "wrong message", sig_bytes));
}

test "KeyPair generation and wrapper verify" {
    const kp = try KeyPair.generate();
    const message = "hello world";
    const sig = try kp.sign(message);
    try std.testing.expect(sig.verify(kp.public_key, message));
    try std.testing.expect(!sig.verify(kp.public_key, "wrong message"));
}
