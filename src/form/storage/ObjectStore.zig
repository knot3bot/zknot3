//! ObjectStore - Object storage with causal consistency
//!
//! Implements object storage with:
//! - O(log n) lookup via LSM-Tree
//! - Causal version tracking
//! - Ownership-based access control
//! - Async I/O compatibility wrapper (currently sync on Linux, thread-pool fallback elsewhere)
//!
const std = @import("std");
const core = @import("../../core.zig");
const LSMTree = @import("LSMTree.zig");
const IOUring = @import("IOUring.zig");
const WAL_module = @import("WAL.zig");
/// Object stored in the object store
pub const Object = struct {
    id: core.ObjectID,
    version: core.Version,
    ownership: core.Ownership,
    data: []u8,
    type_tag: u8,

    const Self = @This();

    /// Serialize object to bytes
    pub fn serialize(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        // Write ID (32 bytes)
        try buf.appendSlice(allocator, self.id.asBytes());
        // Write version (24 bytes)
        try buf.appendSlice(allocator, &self.version.encode());
        // Write ownership tag
        try buf.append(allocator, @intFromEnum(self.ownership.tag));
        // Write context if shared
        if (self.ownership.getContext()) |ctx| {
            var ctx_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &ctx_buf, ctx, .big);
            try buf.appendSlice(allocator, &ctx_buf);
        } else if (self.ownership.getOwner()) |owner| {
            try buf.appendSlice(allocator, &owner);
        }
        // Write type tag
        try buf.append(allocator, self.type_tag);
        // Write data length and data
        const len: u32 = @intCast(self.data.len);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, len, .big);
        try buf.appendSlice(allocator, &len_buf);
        try buf.appendSlice(allocator, self.data);

        return buf.toOwnedSlice(allocator);
    }

    /// Deserialize object from bytes
    pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Self {
        if (bytes.len < 32 + 24 + 1 + 4) return error.InvalidFormat;

        var offset: usize = 0;

        // Read ID
        const id = try core.ObjectID.fromBytes(bytes[offset..][0..32]);
        offset += 32;

        // Read version
        const version = try core.Version.decode(bytes[offset..][0..24]);
        offset += 24;

        // Read ownership tag
        const tag: core.OwnershipTag = @enumFromInt(bytes[offset]);
        offset += 1;

        var ownership: core.Ownership = undefined;
        switch (tag) {
            .Owned => {
                const owner = bytes[offset..][0..32].*;
                offset += 32;
                ownership = core.Ownership.ownedBy(owner);
            },
            .Shared => {
                const ctx = std.mem.readInt(u64, bytes[offset..][0..8], .big);
                offset += 8;
                ownership = core.Ownership.shared(ctx);
            },
            .Immutable => {
                ownership = core.Ownership.immutable();
            },
        }

        // Read type tag
        const type_tag = bytes[offset];
        offset += 1;

        // Read data
        const data_len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        // Bounds check: ensure remaining bytes are sufficient
        if (offset + data_len > bytes.len) return error.InvalidFormat;
        const data = try allocator.dupe(u8, bytes[offset..][0..data_len]);

        return .{
            .id = id,
            .version = version,
            .ownership = ownership,
            .type_tag = type_tag,
            .data = data,
        };
    }

    /// Free deserialized object's owned memory
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// ObjectStore configuration
pub const ObjectStoreConfig = struct {
    /// Cache size for frequently accessed objects
    cache_size: usize = 128 * 1024 * 1024, // 128MB
    /// Enable causal versioning
    causal_ordering: bool = true,
    /// Enable async I/O
    async_io: bool = true,
};

/// ObjectStore - main object storage interface
pub const ObjectStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    lsm: *LSMTree.LSMTree,
    config: ObjectStoreConfig,

    /// Initialize object store
    pub fn init(allocator: std.mem.Allocator, config: ObjectStoreConfig, sst_dir: []const u8) !*Self {
        const self = try allocator.create(Self);
        const lsm_config = LSMTree.LSMTreeConfig{
            .sst_dir = sst_dir,
            .memtable_size = config.cache_size,
        };
        self.* = .{
            .allocator = allocator,
            .lsm = try LSMTree.LSMTree.init(allocator, lsm_config),
            .config = config,
        };
        return self;
    }

    /// Deinitialize object store
    pub fn deinit(self: *Self) void {
        self.lsm.deinit();
        self.allocator.destroy(self);
    }

    /// Recover object store from WAL with recovery options
    pub fn recoverWithOptions(self: *Self, options: WAL_module.RecoveryOptions) !WAL_module.RecoveryResult {
        return try self.lsm.recoverWithOptions(options);
    }

    /// Recover object store from WAL with default options
    pub fn recover(self: *Self) !WAL_module.RecoveryResult {
        return self.recoverWithOptions(.{});
    }

    /// Get object by ID
    pub fn get(self: *Self, id: core.ObjectID) !?Object {
        const key = id.asBytes();
        const value = (try self.lsm.get(key)) orelse return null;
        return try Object.deserialize(self.allocator, value);
    }

    /// Put object into store
    pub fn put(self: *Self, object: Object) !void {
        const key = object.id.asBytes();
        const value = try object.serialize(self.allocator);
        defer self.allocator.free(value);
        try self.lsm.put(key, value);
    }

    /// Delete object from store
    pub fn delete(self: *Self, id: core.ObjectID) !void {
        const key = id.asBytes();
        try self.lsm.delete(key);
    }
};

test "Object serialization" {
    const allocator = std.testing.allocator;

    const id = core.ObjectID.hash("test object");
    const version = core.Version{ .seq = 1, .causal = [_]u8{0} ** 16 };
    const ownership = core.Ownership.ownedBy([_]u8{0x42} ** 32);

    var object = Object{
        .id = id,
        .version = version,
        .ownership = ownership,
        .data = try allocator.dupe(u8, "test data"),
        .type_tag = 1,
    };
    defer object.deinit(allocator);

    const serialized = try object.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, object.data, deserialized.data));
}

test "ObjectStore init" {
    const allocator = std.testing.allocator;
    var store = try ObjectStore.init(allocator, .{}, "/tmp/test_sst");
    defer store.deinit();
}
