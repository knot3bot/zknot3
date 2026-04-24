//! ObjectID - BLAKE3(256-bit) cryptographic identifier
//!
//! Represents the fundamental identity primitive in the Knot3/Zig object model.
//! Modeled as a commutative group element for algebraic verification.

const std = @import("std");

/// ObjectID - 256-bit BLAKE3 hash-based identifier
/// Forms a commutative group under XOR operations
pub const ObjectID = struct {
    bytes: [32]u8,

    const Self = @This();

    /// Zero element (identity for XOR group)
    pub const zero: Self = .{ .bytes = [_]u8{0} ** 32 };

    /// Compute BLAKE3-256 hash and create ObjectID
    pub fn hash(data: []const u8) Self {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(data);
        var id: Self = undefined;
        ctx.final(&id.bytes);
        return id;
    }

    /// Compute BLAKE3-256 hash with key (for domain separation)
    pub fn hashWithKey(data: []const u8, key: []const u8) Self {
        var ctx = std.crypto.hash.Blake3.init(.{
            .key = std.mem.bytesToValue(u256, key[0..32]),
        });
        ctx.update(data);
        var id: Self = undefined;
        ctx.final(&id.bytes);
        return id;
    }

    /// XOR group operation (commutative group)
    pub fn add(self: Self, other: Self) Self {
        var result: Self = undefined;
        for (0..32) |i| {
            result.bytes[i] = self.bytes[i] ^ other.bytes[i];
        }
        return result;
    }

    /// Group negation (XOR with all-ones)
    pub fn negate(self: Self) Self {
        var result: Self = undefined;
        for (0..32) |i| {
            result.bytes[i] = ~self.bytes[i];
        }
        return result;
    }

    /// Check if this is the zero element
    pub fn isZero(self: Self) bool {
        return std.mem.eql(u8, &self.bytes, &Self.zero.bytes);
    }

    /// Equality comparison
    pub fn eql(self: Self, other: Self) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Get bytes as slice
    pub fn asBytes(self: *const Self) []const u8 {
        return &self.bytes;
    }

    /// Create from bytes (panics if not exactly 32 bytes)
    pub fn fromBytes(bytes: []const u8) !Self {
        if (bytes.len != 32) return error.InvalidLength;
        var id: Self = undefined;
        @memcpy(&id.bytes, bytes[0..32]);
        return id;
    }
};

test "ObjectID hash and equality" {
    const id1 = ObjectID.hash("hello");
    const id2 = ObjectID.hash("hello");
    const id3 = ObjectID.hash("world");

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
}

test "ObjectID group operations" {
    const a = ObjectID.hash("a");
    const b = ObjectID.hash("b");

    // Commutative
    try std.testing.expect(a.add(b).eql(b.add(a)));

    // Identity
    try std.testing.expect(a.add(.zero).eql(a));

    // Self-inverse (a ^ a = 0)
    try std.testing.expect(a.add(a).eql(.zero));
}
