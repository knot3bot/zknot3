//! ModuleRegistry — on-chain module publish/upgrade lifecycle.
//!
//! Modules are published as self-describing containers (see
//! `encodePublishPayload`). The registry enforces per-module upgrade
//! policies:
//!   - immutable:  the module can never be replaced
//!   - compatible: upgrades must preserve the export set exactly
//!   - free:       upgrades may change anything
//!
//! A module's on-chain identity is `id = Blake3("zknot3-module" || package_id
//! || name)`; upgrades under the same id bump `version`. The canonical
//! bytecode digest commits to the full container payload.

const std = @import("std");

pub const UpgradePolicy = enum(u8) {
    immutable = 0,
    compatible = 1,
    free = 2,

    pub fn fromByte(b: u8) ?UpgradePolicy {
        return switch (b) {
            0 => .immutable,
            1 => .compatible,
            2 => .free,
            else => null,
        };
    }
};

pub const max_module_name = 128;
pub const max_exports = 64;
pub const max_module_bytes = 1 << 20;
pub const publish_gas_base: u64 = 1000;
pub const publish_gas_per_byte: u64 = 1;

pub const PublishPayload = struct {
    name: []const u8,
    policy: UpgradePolicy,
    exports: []const []const u8,
    bytecode: []const u8,

    pub fn deinit(self: PublishPayload, allocator: std.mem.Allocator) void {
        for (self.exports) |exp| allocator.free(exp);
        allocator.free(self.exports);
        allocator.free(self.name);
        allocator.free(self.bytecode);
    }
};

pub const PublishedModule = struct {
    id: [32]u8,
    package_id: [32]u8,
    name: []u8,
    version: u32,
    bytecode: []u8,
    exports: [][]u8,
    publisher: [32]u8,
    policy: UpgradePolicy,
    digest: [32]u8,
    published_at_round: u64,
};

pub const PublishOutcome = struct {
    id: [32]u8,
    version: u32,
    upgraded: bool,
    gas_charge: u64,
};

pub const PublishError = error{
    InvalidPayload,
    NameTooLong,
    TooManyExports,
    ModuleTooLarge,
    ModuleImmutable,
    IncompatibleUpgrade,
    SameBytecode,
    OutOfMemory,
};

pub const ModuleRegistry = struct {
    const Self = @This();
    const magic = "zknot3-module-container-v1";

    allocator: std.mem.Allocator,
    modules: std.AutoArrayHashMapUnmanaged([32]u8, PublishedModule) = .empty,
    /// Total successful publish/upgrade operations (monitoring).
    publish_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            const m = entry.value_ptr;
            self.allocator.free(m.name);
            self.allocator.free(m.bytecode);
            for (m.exports) |exp| self.allocator.free(exp);
            self.allocator.free(m.exports);
        }
        self.modules.deinit(self.allocator);
    }

    /// Deterministic on-chain module identity.
    pub fn moduleId(package_id: [32]u8, name: []const u8) [32]u8 {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(magic);
        ctx.update(&package_id);
        ctx.update(name);
        var id: [32]u8 = undefined;
        ctx.final(&id);
        return id;
    }

    /// Canonical container digest over the payload bytes.
    pub fn payloadDigest(blob: []const u8) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(blob, &digest, .{});
        return digest;
    }

    /// Publish (or upgrade) a module from an encoded container blob.
    /// `publisher` must match the original publisher for upgrades.
    pub fn publish(
        self: *Self,
        package_id: [32]u8,
        publisher: [32]u8,
        blob: []const u8,
        round: u64,
    ) PublishError!PublishOutcome {
        var payload = try decodePublishPayload(self.allocator, blob);
        defer payload.deinit(self.allocator);

        if (payload.name.len == 0 or payload.name.len > max_module_name) return error.NameTooLong;
        if (payload.exports.len > max_exports) return error.TooManyExports;
        if (payload.bytecode.len == 0 or payload.bytecode.len > max_module_bytes) return error.ModuleTooLarge;

        const id = moduleId(package_id, payload.name);
        const digest = payloadDigest(blob);
        const gas_charge = publish_gas_base + payload.bytecode.len * publish_gas_per_byte;

        const gop = self.modules.getOrPut(self.allocator, id) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .id = id,
                .package_id = package_id,
                .name = self.allocator.dupe(u8, payload.name) catch return error.OutOfMemory,
                .version = 1,
                .bytecode = self.allocator.dupe(u8, payload.bytecode) catch return error.OutOfMemory,
                .exports = dupeExports(self.allocator, payload.exports) catch return error.OutOfMemory,
                .publisher = publisher,
                .policy = payload.policy,
                .digest = digest,
                .published_at_round = round,
            };
            self.publish_count += 1;
            return .{ .id = id, .version = 1, .upgraded = false, .gas_charge = gas_charge };
        }

        // Upgrade path: enforce policy and publisher continuity.
        const existing = gop.value_ptr;
        if (existing.policy == .immutable) return error.ModuleImmutable;
        if (!std.mem.eql(u8, &existing.publisher, &publisher)) return error.IncompatibleUpgrade;
        if (std.mem.eql(u8, &existing.digest, &digest)) return error.SameBytecode;
        if (existing.policy == .compatible) {
            if (!exportSetsEqual(existing.exports, payload.exports)) return error.IncompatibleUpgrade;
        }

        self.allocator.free(existing.bytecode);
        existing.bytecode = self.allocator.dupe(u8, payload.bytecode) catch return error.OutOfMemory;
        for (existing.exports) |exp| self.allocator.free(exp);
        self.allocator.free(existing.exports);
        existing.exports = dupeExports(self.allocator, payload.exports) catch return error.OutOfMemory;
        existing.version += 1;
        existing.digest = digest;
        existing.published_at_round = round;
        self.publish_count += 1;
        return .{ .id = id, .version = existing.version, .upgraded = true, .gas_charge = gas_charge };
    }

    pub fn get(self: *const Self, id: [32]u8) ?*const PublishedModule {
        return self.modules.getPtr(id);
    }

    pub fn findByName(self: *const Self, package_id: [32]u8, name: []const u8) ?*const PublishedModule {
        return self.modules.getPtr(moduleId(package_id, name));
    }

    pub fn count(self: *const Self) usize {
        return self.modules.count();
    }

    fn dupeExports(allocator: std.mem.Allocator, exports: []const []const u8) ![][]u8 {
        const out = try allocator.alloc([]u8, exports.len);
        errdefer allocator.free(out);
        for (exports, 0..) |exp, i| {
            out[i] = try allocator.dupe(u8, exp);
        }
        return out;
    }

    fn exportSetsEqual(a: []const []u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        outer: for (a) |name_a| {
            for (b) |name_b| {
                if (std.mem.eql(u8, name_a, name_b)) continue :outer;
            }
            return false;
        }
        return true;
    }
};

/// Container format (all integers big-endian):
///   magic (24 bytes) | policy u8 | name_len u16 | name
///   export_count u16 | (name_len u16 | name)*
///   bytecode_len u32 | bytecode
pub fn encodePublishPayload(
    allocator: std.mem.Allocator,
    name: []const u8,
    policy: UpgradePolicy,
    exports: []const []const u8,
    bytecode: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, ModuleRegistry.magic);
    try buf.append(allocator, @backingInt(policy));
    var nb: [2]u8 = undefined;
    std.mem.writeInt(u16, &nb, @intCast(name.len), .big);
    try buf.appendSlice(allocator, &nb);
    try buf.appendSlice(allocator, name);
    var eb: [2]u8 = undefined;
    std.mem.writeInt(u16, &eb, @intCast(exports.len), .big);
    try buf.appendSlice(allocator, &eb);
    for (exports) |exp| {
        std.mem.writeInt(u16, &nb, @intCast(exp.len), .big);
        try buf.appendSlice(allocator, &nb);
        try buf.appendSlice(allocator, exp);
    }
    var bb: [4]u8 = undefined;
    std.mem.writeInt(u32, &bb, @intCast(bytecode.len), .big);
    try buf.appendSlice(allocator, &bb);
    try buf.appendSlice(allocator, bytecode);
    return buf.toOwnedSlice(allocator);
}

pub fn decodePublishPayload(allocator: std.mem.Allocator, blob: []const u8) PublishError!PublishPayload {
    const magic_len = ModuleRegistry.magic.len;
    if (blob.len < magic_len + 1 + 2) return error.InvalidPayload;
    if (!std.mem.eql(u8, blob[0..magic_len], ModuleRegistry.magic)) return error.InvalidPayload;
    var offset: usize = magic_len;
    const policy = UpgradePolicy.fromByte(blob[offset]) orelse return error.InvalidPayload;
    offset += 1;

    const name_len = std.mem.readInt(u16, blob[offset..][0..2], .big);
    offset += 2;
    if (blob.len - offset < name_len) return error.InvalidPayload;
    const name = allocator.dupe(u8, blob[offset .. offset + name_len]) catch return error.OutOfMemory;
    errdefer allocator.free(name);
    offset += name_len;

    if (blob.len - offset < 2) return error.InvalidPayload;
    const export_count = std.mem.readInt(u16, blob[offset..][0..2], .big);
    offset += 2;
    if (export_count > max_exports) return error.TooManyExports;
    const exports = allocator.alloc([]const u8, export_count) catch return error.OutOfMemory;
    errdefer allocator.free(exports);
    var filled: usize = 0;
    errdefer for (exports[0..filled]) |e| allocator.free(e);
    for (0..export_count) |i| {
        if (blob.len - offset < 2) return error.InvalidPayload;
        const elen = std.mem.readInt(u16, blob[offset..][0..2], .big);
        offset += 2;
        if (blob.len - offset < elen) return error.InvalidPayload;
        exports[i] = allocator.dupe(u8, blob[offset .. offset + elen]) catch return error.OutOfMemory;
        filled += 1;
        offset += elen;
    }

    if (blob.len - offset < 4) return error.InvalidPayload;
    const bytecode_len = std.mem.readInt(u32, blob[offset..][0..4], .big);
    offset += 4;
    if (blob.len - offset != bytecode_len) return error.InvalidPayload;
    const bytecode = allocator.dupe(u8, blob[offset..]) catch return error.OutOfMemory;

    return .{ .name = name, .policy = policy, .exports = exports, .bytecode = bytecode };
}

test "module publish lifecycle: publish, lookup, upgrade policies" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    const package = @as([32]u8, @splat(0x50));
    const publisher = @as([32]u8, @splat(0x99));

    const v1 = try encodePublishPayload(allocator, "life", .compatible, &[_][]const u8{ "grow", "decay" }, &[_]u8{ 0x00, 0x01, 0x02 });
    defer allocator.free(v1);

    const out1 = try registry.publish(package, publisher, v1, 7);
    try std.testing.expect(!out1.upgraded);
    try std.testing.expectEqual(@as(u32, 1), out1.version);

    const mod = registry.findByName(package, "life") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("life", mod.name);
    try std.testing.expectEqual(@as(u32, 1), mod.version);
    try std.testing.expectEqual(@as(u64, 7), mod.published_at_round);
    try std.testing.expectEqual(@as(usize, 2), mod.exports.len);

    // Identical bytecode is rejected without bumping the version.
    try std.testing.expectError(error.SameBytecode, registry.publish(package, publisher, v1, 8));

    // Compatible upgrade preserving the export set succeeds and bumps version.
    const v2 = try encodePublishPayload(allocator, "life", .compatible, &[_][]const u8{ "decay", "grow" }, &[_]u8{ 0x00, 0x01, 0x03 });
    defer allocator.free(v2);
    const out2 = try registry.publish(package, publisher, v2, 9);
    try std.testing.expect(out2.upgraded);
    try std.testing.expectEqual(@as(u32, 2), out2.version);

    // Compatible upgrade dropping an export is rejected.
    const v3 = try encodePublishPayload(allocator, "life", .compatible, &[_][]const u8{"grow"}, &[_]u8{ 0x00, 0x01, 0x04 });
    defer allocator.free(v3);
    try std.testing.expectError(error.IncompatibleUpgrade, registry.publish(package, publisher, v3, 10));

    // A different publisher cannot upgrade.
    try std.testing.expectError(error.IncompatibleUpgrade, registry.publish(package, @as([32]u8, @splat(0xAA)), v2, 11));

    // Immutable modules never upgrade.
    const frozen = try encodePublishPayload(allocator, "genesis", .immutable, &[_][]const u8{"init"}, &[_]u8{0x00});
    defer allocator.free(frozen);
    _ = try registry.publish(package, publisher, frozen, 1);
    const frozen2 = try encodePublishPayload(allocator, "genesis", .immutable, &[_][]const u8{"init"}, &[_]u8{0x01});
    defer allocator.free(frozen2);
    try std.testing.expectError(error.ModuleImmutable, registry.publish(package, publisher, frozen2, 2));
}

test "module payload codec roundtrip and rejection of corrupt input" {
    const allocator = std.testing.allocator;

    const blob = try encodePublishPayload(allocator, "token", .free, &[_][]const u8{ "mint", "burn" }, &[_]u8{ 0xB0, 0xB1, 0xB2, 0xB3 });
    defer allocator.free(blob);

    var decoded = try decodePublishPayload(allocator, blob);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualStrings("token", decoded.name);
    try std.testing.expect(decoded.policy == .free);
    try std.testing.expectEqual(@as(usize, 2), decoded.exports.len);
    try std.testing.expectEqualStrings("mint", decoded.exports[0]);
    try std.testing.expectEqual(@as(usize, 4), decoded.bytecode.len);

    // Truncated and magic-mangled inputs are rejected.
    try std.testing.expectError(error.InvalidPayload, decodePublishPayload(allocator, blob[0 .. blob.len - 1]));
    var bad = try allocator.dupe(u8, blob);
    defer allocator.free(bad);
    bad[0] ^= 0xFF;
    try std.testing.expectError(error.InvalidPayload, decodePublishPayload(allocator, bad));

    // Module identity is deterministic and name-sensitive.
    const id_a = ModuleRegistry.moduleId(@as([32]u8, @splat(1)), "token");
    const id_b = ModuleRegistry.moduleId(@as([32]u8, @splat(1)), "token");
    const id_c = ModuleRegistry.moduleId(@as([32]u8, @splat(1)), "other");
    try std.testing.expectEqual(id_a, id_b);
    try std.testing.expect(!std.mem.eql(u8, &id_a, &id_c));
}
