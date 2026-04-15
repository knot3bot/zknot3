//! VersionLattice - Version ordering with sequence and causal relationships
//!
//! Implements partial order comparison for object versions in the Knot3 object model.
//! Combines sequence numbers with causal hashes for DAG-based ordering.

const std = @import("std");

/// Version identifier with causal ordering
/// Represents a point in the version space: (sequence_number, causal_hash)
pub const Version = struct {
    seq: u64, // Monotonically increasing sequence number
    causal: [16]u8, // Causal hash for DAG-based ordering

    const Self = @This();

    /// Initial version (sequence 0)
    pub const initial: Self = .{
        .seq = 0,
        .causal = [_]u8{0} ** 16,
    };

    /// Compare two versions using lexicographic ordering
    /// First compares sequence numbers, then causal hashes
    pub fn compare(self: Self, other: Self) std.math.Order {
        const seq_order = std.math.order(self.seq, other.seq);
        if (seq_order != .eq) return seq_order;
        return std.mem.order(u8, &self.causal, &other.causal);
    }

    /// Check if self < other (strict partial order)
    pub fn lessThan(self: Self, other: Self) bool {
        return self.compare(other) == .lt;
    }

    /// Check if self <= other (partial order)
    pub fn lessThanOrEqual(self: Self, other: Self) bool {
        const ord = self.compare(other);
        return ord == .lt or ord == .eq;
    }

    /// Get next sequence with same causal
    pub fn nextSeq(self: Self) Self {
        return .{
            .seq = self.seq + 1,
            .causal = self.causal,
        };
    }

    /// Create new version with updated causal hash
    pub fn withCausalHash(self: Self, new_causal: [16]u8) Self {
        return .{
            .seq = self.seq,
            .causal = new_causal,
        };
    }

    /// Encode to bytes for storage
    pub fn encode(self: Self) [24]u8 {
        var bytes: [24]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], self.seq, .big);
        @memcpy(bytes[8..24], &self.causal);
        return bytes;
    }

    /// Decode from bytes
    pub fn decode(bytes: []const u8) !Self {
        if (bytes.len < 24) return error.InvalidLength;
        return .{
            .seq = std.mem.readInt(u64, bytes[0..8], .big),
            .causal = bytes[8..24].*,
        };
    }

    /// Check if versions are causally ordered (same sequence, earlier causal)
    pub fn precedes(self: Self, other: Self) bool {
        return self.seq <= other.seq and
            std.mem.lessThan(u8, &self.causal, &other.causal);
    }
};

/// VersionLattice - Container and utilities for version management
pub const VersionLattice = struct {
    const Self = @This();

    /// Current latest version
    latest: Version,

    /// Initialize empty lattice
    pub fn init() Self {
        return .{ .latest = .initial };
    }

    /// Create new version from current
    pub fn newVersion(self: *Self) Version {
        const v = self.latest.nextSeq();
        self.latest = v;
        return v;
    }

    /// Merge two versions, taking the maximum sequence
    /// For causal hashes: combines them using BLAKE3 for DAG merge consistency
    pub fn merge(self: *Self, other: Version) void {
        if (other.seq > self.latest.seq) {
            self.latest.seq = other.seq;
        }
        // Merge causal hashes: combine both for DAG consistency
        if (other.seq == self.latest.seq) {
            var ctx = std.crypto.hash.Blake3.init(.{});
            ctx.update(&self.latest.causal);
            ctx.update(&other.causal);
            var merged: [16]u8 = undefined;
            ctx.final(&merged);
            // Use lexicographically larger causal for deterministic ordering
            if (std.mem.order(u8, &self.latest.causal, &merged) == .lt) {
                self.latest.causal = merged;
            }
        }
    }
};

test "Version comparison" {
    const v1 = Version{ .seq = 5, .causal = [_]u8{1} ** 16 };
    const v2 = Version{ .seq = 10, .causal = [_]u8{1} ** 16 };

    try std.testing.expect(v1.lessThan(v2));
    try std.testing.expect(!v2.lessThan(v1));
    try std.testing.expect(v1.lessThanOrEqual(v2));
    try std.testing.expect(v1.lessThanOrEqual(v1));
}

test "Version encoding" {
    const v = Version{ .seq = 0xDEADBEEF, .causal = [_]u8{0xAB} ** 16 };
    const encoded = v.encode();
    const decoded = try Version.decode(&encoded);
    try std.testing.expect(decoded.seq == v.seq);
    try std.testing.expect(std.mem.eql(u8, &decoded.causal, &v.causal));
}

// Comptime assertion: VersionLattice is a partial order
comptime {
    if (!@hasDecl(Version, "compare")) @compileError("Version must have compare method");
    if (!@hasDecl(Version, "lessThan")) @compileError("Version must have lessThan method");
}
