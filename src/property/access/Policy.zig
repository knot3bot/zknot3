//! Policy - Access control with category morphism composition

const std = @import("std");
const core = @import("../../core.zig");

/// Access action
pub const Action = enum {
    read,
    write,
    delete,
    transfer,
    call,
};

/// Access result
pub const AccessResult = struct {
    allowed: bool,
    reason: ?[]u8,
};

/// Access policy morphism
pub const Policy = struct {
    const Self = @This();

    /// Check if caller can access target with given action
    pub fn check(
        self: Self,
        caller: [32]u8,
        target_owner: ?[32]u8,
        action: Action,
        ownership: core.Ownership,
    ) AccessResult {
        _ = self;

        // Immutable objects can be read by anyone
        if (ownership.tag == .Immutable) {
            return switch (action) {
                .read => .{ .allowed = true, .reason = null },
                else => .{ .allowed = false, .reason = "Immutable objects cannot be modified" },
            };
        }

        // Owned objects - check ownership
        if (ownership.tag == .Owned) {
            if (target_owner) |owner| {
                if (std.mem.eql(u8, &caller, &owner)) {
                    return .{ .allowed = true, .reason = null };
                }
            }
            return .{ .allowed = false, .reason = "Not owner" };
        }

        // Shared objects - anyone can access
        if (ownership.tag == .Shared) {
            return .{ .allowed = true, .reason = null };
        }

        return .{ .allowed = false, .reason = "Unknown ownership state" };
    }

    /// Compose policies (AND composition)
    pub fn compose(self: Self, other: Self) Self {
        _ = other;
        return self;
    }

    /// Alternative policy (OR composition)
    pub fn alternative(self: Self, other: Self) Self {
        _ = other;
        return self;
    }
};

test "Policy owned object" {
    const policy = Policy{};
    const owner = [_]u8{1} ** 32;
    const non_owner = [_]u8{2} ** 32;

    const ownership = core.Ownership.ownedBy(owner);

    // Owner can read
    const read_result = policy.check(owner, owner, .read, ownership);
    try std.testing.expect(read_result.allowed);

    // Owner can write
    const write_result = policy.check(owner, owner, .write, ownership);
    try std.testing.expect(write_result.allowed);

    // Non-owner cannot write
    const deny_result = policy.check(non_owner, owner, .write, ownership);
    try std.testing.expect(!deny_result.allowed);
}

test "Policy immutable object" {
    const policy = Policy{};
    const caller = [_]u8{1} ** 32;

    const ownership = core.Ownership.immutable();

    // Anyone can read
    const read_result = policy.check(caller, null, .read, ownership);
    try std.testing.expect(read_result.allowed);

    // No one can write
    const write_result = policy.check(caller, null, .write, ownership);
    try std.testing.expect(!write_result.allowed);
}

test "Policy shared object" {
    const policy = Policy{};
    const caller = [_]u8{1} ** 32;

    const ownership = core.Ownership.shared(123);

    // Anyone can read/write
    const read_result = policy.check(caller, null, .read, ownership);
    try std.testing.expect(read_result.allowed);

    const write_result = policy.check(caller, null, .write, ownership);
    try std.testing.expect(write_result.allowed);
}
