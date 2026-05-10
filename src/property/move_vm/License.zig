//! Creator³ License Model
//!
//! Auto-attached license metadata for digital creations.
//! Supports: CC0, CC-BY, CC-BY-SA, MIT, AllRightsReserved, Custom.
//! Royalty enforcement via PTB SplitCoins on transfer/sale.

const std = @import("std");

/// License type enum for on-chain creations.
pub const LicenseType = enum(u8) {
    CC0 = 0,              // Public domain, no restrictions
    CC_BY = 1,            // Attribution required
    CC_BY_SA = 2,         // Attribution + ShareAlike
    MIT = 3,              // Permissive, attribution optional
    AllRightsReserved = 4, // Full copyright, no reuse without permission
    Custom = 5,           // Custom terms

    pub fn name(self: LicenseType) []const u8 {
        return switch (self) {
            .CC0 => "CC0",
            .CC_BY => "CC-BY",
            .CC_BY_SA => "CC-BY-SA",
            .MIT => "MIT",
            .AllRightsReserved => "All Rights Reserved",
            .Custom => "Custom",
        };
    }
};

/// License metadata attached to every creation.
pub const License = struct {
    license_type: LicenseType = .AllRightsReserved,
    /// Human-readable license terms (e.g. "May use commercially with attribution")
    terms: []const u8 = &.{},
    /// Royalty in basis points (1% = 100 bps, 5% = 500 bps). 0 = no royalty.
    royalty_bps: u16 = 0,
    /// License expiration timestamp (0 = perpetual)
    expiration_secs: i64 = 0,
    /// License issuer (creator or rights holder)
    issuer: ?[32]u8 = null,

    pub fn deinit(self: *License, allocator: std.mem.Allocator) void {
        if (self.terms.len > 0) allocator.free(self.terms);
    }

    /// Create a CC0 (public domain) license.
    pub fn cc0() License {
        return .{ .license_type = .CC0, .royalty_bps = 0 };
    }

    /// Create a CC-BY license with optional royalty.
    pub fn cc_by(royalty_bps: u16) License {
        return .{ .license_type = .CC_BY, .royalty_bps = royalty_bps };
    }

    /// Create an MIT license.
    pub fn mit() License {
        return .{ .license_type = .MIT, .royalty_bps = 0 };
    }

    /// Create a custom license.
    pub fn custom(terms: []const u8, royalty_bps: u16) License {
        return .{ .license_type = .Custom, .terms = terms, .royalty_bps = royalty_bps };
    }

    /// Serialize license to bytes for ObjectStore storage.
    pub fn serialize(self: License, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.append(allocator,@intFromEnum(self.license_type));
        var royalty_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &royalty_bytes, self.royalty_bps, .big);
        try buf.appendSlice(allocator,&royalty_bytes);
        var exp_bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &exp_bytes, self.expiration_secs, .big);
        try buf.appendSlice(allocator,&exp_bytes);
        const terms_len: u16 = @intCast(self.terms.len);
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, terms_len, .big);
        try buf.appendSlice(allocator,&len_bytes);
        if (self.terms.len > 0) try buf.appendSlice(allocator,self.terms);
        return buf.toOwnedSlice(allocator);
    }

    /// Deserialize license from bytes.
    pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !License {
        if (bytes.len < 1 + 2 + 8 + 2) return error.InvalidLicense;
        const license_type: LicenseType = @enumFromInt(bytes[0]);
        const royalty_bps = std.mem.readInt(u16, bytes[1..3], .big);
        const expiration_secs = std.mem.readInt(i64, bytes[3..11], .big);
        const terms_len = std.mem.readInt(u16, bytes[11..13], .big);
        var terms: []const u8 = &.{};
        if (terms_len > 0 and bytes.len >= 13 + terms_len) {
            terms = try allocator.dupe(u8, bytes[13 .. 13 + terms_len]);
        }
        return License{
            .license_type = license_type,
            .royalty_bps = royalty_bps,
            .expiration_secs = expiration_secs,
            .terms = terms,
        };
    }

    /// Calculate royalty amount for a given sale price.
    pub fn royaltyAmount(self: License, sale_price: u64) u64 {
        if (self.royalty_bps == 0) return 0;
        return (sale_price * self.royalty_bps) / 10000;
    }

    /// Returns true if this license permits commercial use (CC0, CC-BY, MIT).
    pub fn permitsCommercialUse(self: License) bool {
        return switch (self.license_type) {
            .CC0, .CC_BY, .MIT, .Custom => true,
            else => false,
        };
    }

    /// Returns true if derivative works are permitted.
    pub fn permitsDerivatives(self: License) bool {
        return switch (self.license_type) {
            .CC0, .CC_BY, .CC_BY_SA, .MIT, .Custom => true,
            .AllRightsReserved => false,
        };
    }
};

test "License serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    const lic = License.cc_by(500);
    const ser = try lic.serialize(allocator);
    defer allocator.free(ser);
    var deser = try License.deserialize(allocator, ser);
    defer deser.deinit(allocator);
    try std.testing.expectEqual(lic.license_type, deser.license_type);
    try std.testing.expectEqual(lic.royalty_bps, deser.royalty_bps);
}

test "License royalty calculation" {
    const lic = License.cc_by(500); // 5%
    try std.testing.expectEqual(@as(u64, 50), lic.royaltyAmount(1000));
    try std.testing.expectEqual(@as(u64, 0), License.cc0().royaltyAmount(1000));
}

test "License permissions" {
    try std.testing.expect(License.cc0().permitsCommercialUse());
    try std.testing.expect(License.cc_by(0).permitsDerivatives());
    const all_rights = License{ .license_type = .AllRightsReserved };
    try std.testing.expect(!all_rights.permitsDerivatives());
}
