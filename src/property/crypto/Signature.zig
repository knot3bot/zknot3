//! Signature - Ed25519 signature scheme using std.crypto.sign
//!
//! This module re-exports the canonical implementation from ../Signature.zig
//! for backward compatibility with code importing property/crypto/Signature.

const parent = @import("../Signature.zig");

pub const SignatureScheme = parent.SignatureScheme;
pub const PublicKey = parent.PublicKey;
pub const Signature = parent.Signature;
pub const KeyPair = parent.KeyPair;
pub const Ed25519 = parent.Ed25519;
pub const sign = parent.sign;
pub const verify = parent.verify;
