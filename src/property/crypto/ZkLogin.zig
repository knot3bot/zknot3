//! zkLogin — OAuth/OIDC to On-Chain Identity Bridge
//!
//! Enables AI agents and human creators to authenticate via Web2 identity
//! providers (Google, Apple, GitHub) and derive an on-chain zknot3 address.
//!
//! Flow:
//! 1. User authenticates with OAuth provider → receives JWT
//! 2. Client generates ephemeral keypair
//! 3. deriveAddress(issuer, subject, ephemeral_pubkey) → on-chain address
//! 4. Transaction signed with ephemeral key → verified on-chain via JWT claim

const std = @import("std");

/// OAuth issuer type — maps to JWT `iss` claim.
pub const OAuthIssuer = enum {
    Google,
    Apple,
    GitHub,
    Custom,

    pub fn fromJwtIss(iss: []const u8) ?OAuthIssuer {
        if (std.mem.indexOf(u8, iss, "google") != null) return .Google;
        if (std.mem.indexOf(u8, iss, "apple") != null) return .Apple;
        if (std.mem.indexOf(u8, iss, "github") != null) return .GitHub;
        return .Custom;
    }
};

/// Derived on-chain identity from OAuth credentials.
pub const ZkLoginIdentity = struct {
    /// Derived on-chain address (32 bytes)
    address: [32]u8,
    /// OAuth issuer (Google, Apple, GitHub, etc.)
    issuer: []const u8,
    /// OAuth subject (unique user ID from provider)
    subject: []const u8,
    /// Ephemeral public key used for transaction signing
    ephemeral_pubkey: [32]u8,

    pub fn deinit(self: *ZkLoginIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.issuer);
        allocator.free(self.subject);
    }
};

/// Derive an on-chain address from OAuth credentials + ephemeral key.
/// address = Blake3(issuer || ":" || subject || ":" || ephemeral_pubkey)[0..32]
pub fn deriveAddress(issuer: []const u8, subject: []const u8, ephemeral_pubkey: [32]u8) [32]u8 {
    var ctx = std.crypto.hash.Blake3.init(.{});
    ctx.update(issuer);
    ctx.update(":");
    ctx.update(subject);
    ctx.update(":");
    ctx.update(&ephemeral_pubkey);
    var out: [32]u8 = undefined;
    ctx.final(&out);
    return out;
}

/// Generate an ephemeral keypair for transaction signing.
/// The public key is used in address derivation; the secret key signs transactions.
pub fn generateEphemeralKeypair() !struct { public: [32]u8, secret: [32]u8 } {
    var seed: [32]u8 = undefined;
    @import("io_instance").io.random(&seed);
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.KeyGenerationFailed;
    return .{ .public = kp.public_key.toBytes(), .secret = seed };
}

/// Verify that a JWT payload matches expected claims.
/// In production, this would verify the JWT signature against the provider's JWKS.
pub fn verifyJwtPayload(payload: []const u8, expected_issuer: []const u8, expected_subject: []const u8) bool {
    // Parse minimal JWT claims — production would use full JWT verification
    const iss_ok = std.mem.indexOf(u8, payload, expected_issuer) != null;
    const sub_ok = std.mem.indexOf(u8, payload, expected_subject) != null;
    return iss_ok and sub_ok;
}

/// AI Agent identity derivation convenience.
/// Agent authenticates via OAuth → gets ephemeral key → derives zknot3 address.
pub fn agentIdentity(provider: OAuthIssuer, subject: []const u8, allocator: std.mem.Allocator) !ZkLoginIdentity {
    const issuer_str = switch (provider) {
        .Google => "https://accounts.google.com",
        .Apple => "https://appleid.apple.com",
        .GitHub => "https://github.com/login/oauth",
        .Custom => "https://custom.idp",
    };

    const kp = try generateEphemeralKeypair();
    const addr = deriveAddress(issuer_str, subject, kp.public);

    return ZkLoginIdentity{
        .address = addr,
        .issuer = try allocator.dupe(u8, issuer_str),
        .subject = try allocator.dupe(u8, subject),
        .ephemeral_pubkey = kp.public,
    };
}

test "deriveAddress deterministic" {
    const pk = [_]u8{1} ** 32;
    const a1 = deriveAddress("https://accounts.google.com", "user123", pk);
    const a2 = deriveAddress("https://accounts.google.com", "user123", pk);
    try std.testing.expect(std.mem.eql(u8, &a1, &a2));
    // Different subject → different address
    const a3 = deriveAddress("https://accounts.google.com", "user456", pk);
    try std.testing.expect(!std.mem.eql(u8, &a1, &a3));
}

test "generateEphemeralKeypair produces valid keys" {
    const kp = try generateEphemeralKeypair();
    try std.testing.expect(kp.public.len == 32);
    try std.testing.expect(kp.secret.len == 32);
    try std.testing.expect(!std.mem.eql(u8, &kp.public, &kp.secret));
}

test "agentIdentity for Google" {
    const allocator = std.testing.allocator;
    var id = try agentIdentity(.Google, "agent-42", allocator);
    defer id.deinit(allocator);
    try std.testing.expect(id.address.len == 32);
    try std.testing.expect(std.mem.eql(u8, id.issuer, "https://accounts.google.com"));
    try std.testing.expect(std.mem.eql(u8, id.subject, "agent-42"));
}

test "verifyJwtPayload basic check" {
    const payload = "{\"iss\":\"https://accounts.google.com\",\"sub\":\"user123\"}";
    try std.testing.expect(verifyJwtPayload(payload, "accounts.google.com", "user123"));
    try std.testing.expect(!verifyJwtPayload(payload, "apple.com", "user123"));
}
