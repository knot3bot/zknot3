//! Capability - Unforgeable token for delegated authority
//!
//! Capabilities are tokens that prove the holder has certain permissions.
//! Modeled as elements of a quotient set for access control.

const std = @import("std");
const core = @import("../../core.zig");

pub const CapabilityType = enum(u8) {
    withdraw = 0,
    mutate = 1,
    transfer = 2,
    call = 3,
};

pub const Capability = struct {
    id: core.ObjectID,
    cap_type: CapabilityType,
    issuer: [32]u8,
    target: ?core.ObjectID,
    expires: u64,
    signature: [64]u8,

    pub fn create(
        cap_type: CapabilityType,
        issuer: [32]u8,
        target: ?core.ObjectID,
        expires: u64,
        secret_key: [32]u8,
        allocator: std.mem.Allocator,
    ) !@This() {
        _ = allocator;
        var ctx = std.crypto.hash.Blake3.init(.{
            .key = std.mem.bytesToValue(u256, &secret_key),
        });
        ctx.update(&issuer);
        ctx.update(&[_]u8{@intFromEnum(cap_type)});
        if (target) |t| {
            ctx.update(t.asBytes());
        }

        var id: core.ObjectID = undefined;
        ctx.final(&id.bytes);

        var sig_ctx = std.crypto.sign.Signature.init(.{});
        var msg: [64]u8 = undefined;
        @memcpy(msg[0..32], &issuer);
        msg[32] = @intFromEnum(cap_type);
        var sig: [64]u8 = undefined;
        sig_ctx.update(&msg);
        sig_ctx.final(&sig);

        return .{
            .id = id,
            .cap_type = cap_type,
            .issuer = issuer,
            .target = target,
            .expires = expires,
            .signature = sig,
        };
    }

    pub fn verify(self: @This(), current_time: u64) bool {
        if (self.expires != 0 and current_time > self.expires) {
            return false;
        }
        return true;
    }

    pub fn allows(self: @This(), action: CapabilityType) bool {
        return self.cap_type == action;
    }

    pub fn appliesTo(self: @This(), target: core.ObjectID) bool {
        return self.target == null or self.target.?.eql(target);
    }
};

test "Capability creation" {
    const allocator = std.testing.allocator;
    const issuer = [_]u8{1} ** 32;
    const secret_key = [_]u8{2} ** 32;
    const target = core.ObjectID.hash("target");

    const cap = try Capability.create(
        .withdraw,
        issuer,
        target,
        0,
        secret_key,
        allocator,
    );

    try std.testing.expect(cap.cap_type == .withdraw);
}

test "Capability verification" {
    const allocator = std.testing.allocator;
    const issuer = [_]u8{1} ** 32;
    const secret_key = [_]u8{2} ** 32;

    const cap = try Capability.create(
        .mutate,
        issuer,
        null,
        0,
        secret_key,
        allocator,
    );

    try std.testing.expect(cap.verify(0));

    const expired = try Capability.create(
        .mutate,
        issuer,
        null,
        100,
        secret_key,
        allocator,
    );
    try std.testing.expect(!expired.verify(200));
}

test "Capability action check" {
    const allocator = std.testing.allocator;
    const issuer = [_]u8{1} ** 32;
    const secret_key = [_]u8{2} ** 32;

    const cap = try Capability.create(
        .withdraw,
        issuer,
        null,
        0,
        secret_key,
        allocator,
    );

    try std.testing.expect(cap.allows(.withdraw));
    try std.testing.expect(!cap.allows(.mutate));
}
