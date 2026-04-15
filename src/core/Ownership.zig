//! Ownership - Object ownership model with quotient set semantics
//!
//! Implements the ownership categories: Owned, Shared, Immutable
//! as a quotient set partition for access control and transaction semantics.

const std = @import("std");

/// Ownership category - quotient set partition of object states
pub const OwnershipTag = enum(u8) {
    /// Object is owned by a single address
    Owned = 0,
    /// Object is shared and can be accessed by multiple parties
    Shared = 1,
    /// Object is immutable and cannot be modified
    Immutable = 2,

    const Self = @This();

    /// Check if this ownership allows writes
    pub fn isMutable(self: Self) bool {
        return self != .Immutable;
    }

    /// Check if this ownership allows reads
    pub fn isReadable(self: Self) bool {
        _ = self;
        return true; // All types are readable
    }

    /// Check if ownership transfer is allowed
    pub fn isTransferable(self: Self) bool {
        return self == .Owned;
    }
};

/// Ownership state with additional metadata
pub const Ownership = struct {
    tag: OwnershipTag,
    owner: ?[32]u8, // None for Immutable, Some(address) for Owned/Shared
    context: u64, // Shared object context ID

    const Self = @This();

    /// Owned by specific address
    pub fn ownedBy(address: [32]u8) Self {
        return .{
            .tag = .Owned,
            .owner = address,
            .context = 0,
        };
    }

    /// Shared with context ID for dynamic resolution
    pub fn shared(context: u64) Self {
        return .{
            .tag = .Shared,
            .owner = null,
            .context = context,
        };
    }

    /// Immutable - cannot be modified
    pub fn immutable() Self {
        return .{
            .tag = .Immutable,
            .owner = null,
            .context = 0,
        };
    }

    /// Check if object is mutable
    pub fn isMutable(self: Self) bool {
        return self.tag.isMutable();
    }

    /// Check if object is transferable
    pub fn isTransferable(self: Self) bool {
        return self.tag.isTransferable() and self.owner != null;
    }

    /// Get owner address (only valid for Owned)
    pub fn getOwner(self: Self) ?[32]u8 {
        return self.owner;
    }

    /// Get shared context ID (only valid for Shared)
    pub fn getContext(self: Self) ?u64 {
        return if (self.tag == .Shared) self.context else null;
    }

    /// Encode to bytes for storage
    pub fn encode(self: Self) []u8 {
        var buf: [64]u8 = undefined; // tag(1) + owner(32) + context(8) + padding(23)
        buf[0] = @intFromEnum(self.tag);
        if (self.owner) |addr| {
            @memcpy(buf[1..33], &addr);
        }
        std.mem.writeInt(u64, buf[33..41], self.context, .big);
        return &buf;
    }

    /// Check ownership transfer compatibility
    pub fn canTransferTo(self: Self, newOwner: [32]u8) bool {
        _ = newOwner;
        return self.isTransferable();
    }
};

test "Ownership owned" {
    const addr = [_]u8{0xAB} ** 32;
    const own = Ownership.ownedBy(addr);

    try std.testing.expect(own.tag == .Owned);
    try std.testing.expect(own.isMutable());
    try std.testing.expect(own.isTransferable());
    try std.testing.expect(own.getOwner() != null);
}

test "Ownership shared" {
    const shared = Ownership.shared(123);

    try std.testing.expect(shared.tag == .Shared);
    try std.testing.expect(shared.isMutable());
    try std.testing.expect(!shared.isTransferable());
    try std.testing.expect(shared.getContext() == 123);
}

test "Ownership immutable" {
    const imm = Ownership.immutable();

    try std.testing.expect(imm.tag == .Immutable);
    try std.testing.expect(!imm.isMutable());
    try std.testing.expect(!imm.isTransferable());
    try std.testing.expect(imm.getOwner() == null);
}

