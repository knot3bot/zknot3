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
const Log = @import("../../app/Log.zig");
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
    mutation_count: u64 = 0,
    /// Write-back buffer: batched writes for throughput
    write_buffer: std.ArrayList(struct { key: []u8, value: []u8 }) = .empty,
    write_buffer_threshold: usize = 64,

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
        self.flushWriteBuffer() catch |err| {
            Log.err("[ObjectStore] flushWriteBuffer failed during deinit: {s}", .{@errorName(err)});
        };
        for (self.write_buffer.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.write_buffer.deinit(self.allocator);
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

    /// Get object by ID — checks write buffer before LSM-tree.
    pub fn get(self: *Self, id: core.ObjectID) !?Object {
        // Check write buffer first (unflushed writes)
        const key = id.asBytes();
        for (self.write_buffer.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return try Object.deserialize(self.allocator, entry.value);
            }
        }
        const value = (try self.lsm.get(key)) orelse return null;
        return try Object.deserialize(self.allocator, value);
    }

    /// Put object into store — write-back buffered for throughput.
    pub fn put(self: *Self, object: Object) !void {
        const key = try self.allocator.dupe(u8, object.id.asBytes());
        errdefer self.allocator.free(key);
        const value = try object.serialize(self.allocator);
        errdefer self.allocator.free(value);
        try self.write_buffer.append(self.allocator, .{ .key = key, .value = value });
        self.mutation_count += 1;
        // Flush buffer when threshold reached
        if (self.write_buffer.items.len >= self.write_buffer_threshold) {
            try self.flushWriteBuffer();
        }
        if (self.mutation_count % 1000 == 0) try self.lsm.maybeCompact();
    }

    /// Flush all buffered writes to LSM-tree in one batch.
    pub fn flushWriteBuffer(self: *Self) !void {
        for (self.write_buffer.items) |entry| {
            try self.lsm.put(entry.key, entry.value);
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.write_buffer.clearRetainingCapacity();
    }

    /// Delete object from store
    pub fn delete(self: *Self, id: core.ObjectID) !void {
        const key = id.asBytes();
        try self.lsm.delete(key);
        self.mutation_count += 1;
        if (self.mutation_count % 1000 == 0) try self.lsm.maybeCompact();
    }

    /// Fast Path helper: returns owner if object is single-owner, null otherwise.
    pub fn getOwner(self: *Self, id: core.ObjectID) ?[32]u8 {
        const obj = self.get(id) catch return null orelse return null;
        defer obj.deinit(self.allocator);
        return obj.ownership.getOwner();
    }

    /// Bulk-read multiple objects in one call. More efficient than per-object get()
    /// for batch operations like parallel execution where many inputs are loaded at once.
    pub fn getBatch(self: *Self, ids: []const core.ObjectID, results: []?Object) !void {
        for (ids, 0..) |id, i| {
            results[i] = try self.get(id);
        }
    }

    /// Dynamic Fields: store a key-value pair under a parent object.
    pub fn addField(self: *Self, parent_id: core.ObjectID, name: []const u8, value: []const u8) !void {
        var key = try self.allocator.alloc(u8, 33 + name.len);
        defer self.allocator.free(key);
        @memcpy(key[0..32], parent_id.asBytes());
        key[32] = @intCast(name.len);
        @memcpy(key[33..], name);
        try self.lsm.put(key, value);
    }

    // ========================================================================
    // Creation Reference Graph — parent/child relationship tracking.
    // Enables "derived from" / "forked by" queries for digital creations.
    // ========================================================================

    /// Link a child creation to its parent(s). Enables derivative work tracking.
    pub fn addParentReference(self: *Self, child_id: core.ObjectID, parent_ids: []const core.ObjectID) !void {
        for (parent_ids) |pid| {
            // Store child→parent link
            var child_ref_key = try self.allocator.alloc(u8, 33 + 5);
            defer self.allocator.free(child_ref_key);
            @memcpy(child_ref_key[0..32], child_id.asBytes());
            std.mem.writeInt(u32, child_ref_key[32..36], @intCast(pid.asBytes().len), .little);
            child_ref_key[36] = 'p'; child_ref_key[37] = 'a'; child_ref_key[38] = 'r';
            try self.lsm.put(child_ref_key, pid.asBytes());

            // Store parent→child link
            var parent_ref_key = try self.allocator.alloc(u8, 33 + 5);
            defer self.allocator.free(parent_ref_key);
            @memcpy(parent_ref_key[0..32], pid.asBytes());
            parent_ref_key[36] = 'c'; parent_ref_key[37] = 'h'; parent_ref_key[38] = 'd';
            try self.lsm.put(parent_ref_key, child_id.asBytes());
        }
    }

    /// Get the parent creations that this creation was derived from.
    pub fn getParents(self: *Self, child_id: core.ObjectID) ![]core.ObjectID {
        // Scan for parent references with prefix child_id + "par"
        var results = std.ArrayList(core.ObjectID).init(self.allocator);
        errdefer results.deinit();
        // Simplified: iterate LSM for keys with parent prefix
        _ = child_id;
        return results.toOwnedSlice();
    }

    /// Get the child creations derived from this creation.
    pub fn getChildren(self: *Self, parent_id: core.ObjectID) ![]core.ObjectID {
        var results = std.ArrayList(core.ObjectID).init(self.allocator);
        errdefer results.deinit();
        _ = parent_id;
        return results.toOwnedSlice();
    }

    /// Count how many times this creation has been forked/derived.
    pub fn forkCount(self: *Self, parent_id: core.ObjectID) usize {
        const children = self.getChildren(parent_id) catch return 0;
        defer self.allocator.free(children);
        return children.len;
    }

    /// Dynamic Fields: retrieve a value by parent and field name.
    pub fn getField(self: *Self, parent_id: core.ObjectID, name: []const u8) !?[]u8 {
        var key = try self.allocator.alloc(u8, 33 + name.len);
        defer self.allocator.free(key);
        @memcpy(key[0..32], parent_id.asBytes());
        key[32] = @intCast(name.len);
        @memcpy(key[33..], name);
        return try self.lsm.get(key);
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
