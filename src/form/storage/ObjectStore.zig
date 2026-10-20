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
const StateSnapshot = @import("StateSnapshot.zig");
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
        if (self.data.len > std.math.maxInt(u32)) return error.ObjectTooLarge;

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        // Write ID (32 bytes)
        try buf.appendSlice(allocator, self.id.asBytes());
        // Write version (24 bytes)
        try buf.appendSlice(allocator, &self.version.encode());
        // Write ownership tag
        try buf.append(allocator, @backingInt(self.ownership.tag));
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

        // Read ownership tag. An unknown tag or a truncated owner/context is a
        // format error, not a panic.
        const tag_byte = bytes[offset];
        offset += 1;
        const tag: core.OwnershipTag = switch (tag_byte) {
            0 => .Owned,
            1 => .Shared,
            2 => .Immutable,
            else => return error.InvalidFormat,
        };

        var ownership: core.Ownership = undefined;
        switch (tag) {
            .Owned => {
                if (bytes.len - offset < 32) return error.InvalidFormat;
                const owner = bytes[offset..][0..32].*;
                offset += 32;
                ownership = core.Ownership.ownedBy(owner);
            },
            .Shared => {
                if (bytes.len - offset < 8) return error.InvalidFormat;
                const ctx = std.mem.readInt(u64, bytes[offset..][0..8], .big);
                offset += 8;
                ownership = core.Ownership.shared(ctx);
            },
            .Immutable => {
                ownership = core.Ownership.immutable();
            },
        }

        if (bytes.len - offset < 1 + 4) return error.InvalidFormat;
        const type_tag = bytes[offset];
        offset += 1;

        const data_len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        if (data_len > bytes.len - offset) return error.InvalidFormat;
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
    /// Set when flush hits ArithmeticOverflow (e.g. LSM sequence exhausted).
    /// deinit skips a loud retry; buffered entries are still freed.
    write_buffer_failed: bool = false,

    /// Initialize object store
    pub fn init(allocator: std.mem.Allocator, config: ObjectStoreConfig, sst_dir: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
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
        if (!self.write_buffer_failed) {
            self.flushWriteBuffer() catch |err| {
                Log.err("[ObjectStore] flushWriteBuffer failed during deinit: {s}", .{@errorName(err)});
            };
        }
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

    /// Get object by ID. The write buffer is the newest overlay, so the last
    /// buffered value for an id wins over older buffered copies and the LSM.
    pub fn get(self: *Self, id: core.ObjectID) !?Object {
        const key = id.asBytes();
        var i = self.write_buffer.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.write_buffer.items[i];
            if (std.mem.eql(u8, entry.key, key)) {
                return try Object.deserialize(self.allocator, entry.value);
            }
        }
        const value = (try self.lsm.get(key)) orelse return null;
        defer self.allocator.free(value);
        return try Object.deserialize(self.allocator, value);
    }

    /// Put object into store — write-back buffered for throughput.
    /// The buffer owns `key` and `value` once the append succeeds. A later
    /// flush error must leave that entry in place for `deinit`.
    pub fn put(self: *Self, object: Object) !void {
        const key = try self.allocator.dupe(u8, object.id.asBytes());
        const value = try object.serialize(self.allocator);
        self.write_buffer.append(self.allocator, .{ .key = key, .value = value }) catch |err| {
            self.allocator.free(key);
            self.allocator.free(value);
            return err;
        };
        self.noteMutation();
        // Flush buffer when threshold reached
        if (self.write_buffer.items.len >= self.write_buffer_threshold) {
            try self.flushWriteBuffer();
        }
        if (self.mutation_count % 1000 == 0) try self.lsm.maybeCompact();
    }

    /// Flush all buffered writes to LSM-tree in one batch.
    /// An entry stays in the buffer until its LSM put succeeds, so a later
    /// failure cannot free the same bytes again from `deinit`.
    pub fn flushWriteBuffer(self: *Self) !void {
        if (self.write_buffer_failed) return error.ArithmeticOverflow;
        while (self.write_buffer.items.len > 0) {
            const entry = self.write_buffer.items[0];
            self.lsm.put(entry.key, entry.value) catch |err| {
                if (err == error.ArithmeticOverflow) self.write_buffer_failed = true;
                return err;
            };
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            _ = self.write_buffer.orderedRemove(0);
        }
    }

    /// Delete object from store. Buffered copies are dropped only after the
    /// LSM tombstone is in place, so a later flush cannot write them back.
    pub fn delete(self: *Self, id: core.ObjectID) !void {
        const key = id.asBytes();
        try self.lsm.delete(key);
        var i: usize = 0;
        while (i < self.write_buffer.items.len) {
            if (std.mem.eql(u8, self.write_buffer.items[i].key, key)) {
                const removed = self.write_buffer.orderedRemove(i);
                self.allocator.free(removed.key);
                self.allocator.free(removed.value);
            } else {
                i += 1;
            }
        }
        self.noteMutation();
        if (self.mutation_count % 1000 == 0) try self.lsm.maybeCompact();
    }

    fn noteMutation(self: *Self) void {
        self.mutation_count = std.math.add(u64, self.mutation_count, 1) catch std.math.maxInt(u64);
    }

    /// Fast Path helper: returns owner if object is single-owner, null otherwise.
    pub fn getOwner(self: *Self, id: core.ObjectID) ?[32]u8 {
        const obj = self.get(id) catch return null orelse return null;
        defer obj.deinit(self.allocator);
        return obj.ownership.getOwner();
    }

    /// Bulk-read multiple objects in one call. More efficient than per-object get()
    /// for batch operations like parallel execution where many inputs are loaded at once.
    /// On error, objects already placed in `results` are released.
    pub fn getBatch(self: *Self, ids: []const core.ObjectID, results: []?Object) !void {
        if (results.len < ids.len) return error.BufferTooSmall;
        var filled: usize = 0;
        errdefer {
            for (results[0..filled]) |*slot| {
                if (slot.*) |*obj| obj.deinit(self.allocator);
                slot.* = null;
            }
        }
        for (ids, 0..) |id, i| {
            results[i] = try self.get(id);
            filled = i + 1;
        }
    }

    fn fieldKey(self: *Self, parent_id: core.ObjectID, name: []const u8) ![]u8 {
        if (name.len > std.math.maxInt(u8)) return error.FieldNameTooLong;
        const key = try self.allocator.alloc(u8, 33 + name.len);
        @memcpy(key[0..32], parent_id.asBytes());
        key[32] = @intCast(name.len);
        @memcpy(key[33..], name);
        return key;
    }

    /// Dynamic Fields: store a key-value pair under a parent object.
    pub fn addField(self: *Self, parent_id: core.ObjectID, name: []const u8, value: []const u8) !void {
        const key = try self.fieldKey(parent_id, name);
        defer self.allocator.free(key);
        try self.lsm.put(key, value);
    }

    // ========================================================================
    // Creation Reference Graph — parent/child relationship tracking.
    // Enables "derived from" / "forked by" queries for digital creations.
    // ========================================================================

    fn referenceKey(self: *Self, left: core.ObjectID, tag: u8, right: core.ObjectID) ![]u8 {
        const key = try self.allocator.alloc(u8, 65);
        @memcpy(key[0..32], left.asBytes());
        key[32] = tag;
        @memcpy(key[33..65], right.asBytes());
        return key;
    }

    /// Link a child creation to its parent(s). Each direction is its own key:
    /// child id, tag, parent id, and the reverse.
    pub fn addParentReference(self: *Self, child_id: core.ObjectID, parent_ids: []const core.ObjectID) !void {
        for (parent_ids) |pid| {
            const child_key = try self.referenceKey(child_id, 'p', pid);
            defer self.allocator.free(child_key);
            try self.lsm.put(child_key, pid.asBytes());

            const parent_key = self.referenceKey(pid, 'c', child_id) catch |err| {
                self.lsm.delete(child_key) catch {};
                return err;
            };
            defer self.allocator.free(parent_key);
            self.lsm.put(parent_key, child_id.asBytes()) catch |err| {
                self.lsm.delete(child_key) catch {};
                return err;
            };
        }
    }

    fn linksWithTag(self: *Self, id: core.ObjectID, tag: u8) ![]core.ObjectID {
        const live = try self.lsm.collectLive(self.allocator);
        defer {
            for (live) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
            self.allocator.free(live);
        }

        var results: std.ArrayList(core.ObjectID) = .empty;
        errdefer results.deinit(self.allocator);
        for (live) |entry| {
            if (entry.key.len != 65) continue;
            if (entry.key[32] != tag) continue;
            if (!std.mem.eql(u8, entry.key[0..32], id.asBytes())) continue;
            try results.append(self.allocator, try core.ObjectID.fromBytes(entry.key[33..65]));
        }
        return results.toOwnedSlice(self.allocator);
    }

    /// Get the parent creations that this creation was derived from.
    pub fn getParents(self: *Self, child_id: core.ObjectID) ![]core.ObjectID {
        return self.linksWithTag(child_id, 'p');
    }

    /// Get the child creations derived from this creation.
    pub fn getChildren(self: *Self, parent_id: core.ObjectID) ![]core.ObjectID {
        return self.linksWithTag(parent_id, 'c');
    }

    /// Count how many times this creation has been forked/derived.
    pub fn forkCount(self: *Self, parent_id: core.ObjectID) usize {
        const children = self.getChildren(parent_id) catch return 0;
        defer self.allocator.free(children);
        return children.len;
    }

    /// Dynamic Fields: retrieve a value by parent and field name.
    pub fn getField(self: *Self, parent_id: core.ObjectID, name: []const u8) !?[]u8 {
        const key = try self.fieldKey(parent_id, name);
        defer self.allocator.free(key);
        return try self.lsm.get(key);
    }

    /// Dump every live LSM record, bound to the checkpoint the snapshot
    /// replaces. The digest covers the payload; import refuses a mismatch.
    pub fn exportStateSnapshot(self: *Self, sequence: u64, checkpoint_digest: [32]u8) ![]u8 {
        try self.flushWriteBuffer();
        const live = try self.lsm.collectLive(self.allocator);
        defer {
            for (live) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
            self.allocator.free(live);
        }
        const records = try self.allocator.alloc(StateSnapshot.Record, live.len);
        defer self.allocator.free(records);
        for (live, 0..) |entry, i| {
            records[i] = .{ .key = entry.key, .value = entry.value };
        }
        return StateSnapshot.encode(self.allocator, sequence, checkpoint_digest, records);
    }

    /// Replace the store with the records in a verified snapshot.
    pub fn importStateSnapshot(self: *Self, bytes: []const u8) !StateSnapshot.Header {
        const decoded = try StateSnapshot.decode(self.allocator, bytes);
        defer StateSnapshot.freeRecords(self.allocator, decoded.records);
        try self.flushWriteBuffer();
        const existing = try self.lsm.collectLive(self.allocator);
        defer {
            for (existing) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
            self.allocator.free(existing);
        }
        for (existing) |entry| {
            try self.lsm.delete(entry.key);
        }
        for (decoded.records) |rec| {
            try self.lsm.put(rec.key, rec.value);
        }
        return decoded.header;
    }
};

test "Object serialization" {
    const allocator = std.testing.allocator;

    const id = core.ObjectID.hash("test object");
    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const ownership = core.Ownership.ownedBy(@as([32]u8, @splat(0x42)));

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

test "Object deserialize rejects a bad ownership tag and a short owner" {
    const allocator = std.testing.allocator;

    const id = core.ObjectID.hash("bad object");
    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const ownership = core.Ownership.ownedBy(@as([32]u8, @splat(0x42)));
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

    var bad_tag = try allocator.dupe(u8, serialized);
    defer allocator.free(bad_tag);
    bad_tag[56] = 9;
    try std.testing.expectError(error.InvalidFormat, Object.deserialize(allocator, bad_tag));

    try std.testing.expectError(error.InvalidFormat, Object.deserialize(allocator, serialized[0..61]));
}

test "Object serialize rejects data that does not fit in its length field" {
    const allocator = std.testing.allocator;
    const data: []u8 = @as([*]u8, @ptrFromInt(0x1000))[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    const object = Object{
        .id = core.ObjectID.hash("huge"),
        .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
        .ownership = core.Ownership.immutable(),
        .data = data,
        .type_tag = 1,
    };
    try std.testing.expectError(error.ObjectTooLarge, object.serialize(allocator));
}

test "ObjectStore init" {
    const allocator = std.testing.allocator;
    var store = try ObjectStore.init(allocator, .{}, "/tmp/test_sst");
    defer store.deinit();
}

test "ObjectStore flush keeps the entry that did not reach the LSM" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/objstore_flush_partial";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var store = try ObjectStore.init(allocator, .{}, dir);
    defer store.deinit();

    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const owner = core.Ownership.ownedBy(@as([32]u8, @splat(1)));
    const data_a = try allocator.dupe(u8, "alpha");
    defer allocator.free(data_a);
    const data_b = try allocator.dupe(u8, "beta");
    defer allocator.free(data_b);
    try store.put(.{ .id = core.ObjectID.hash("flush-a"), .version = version, .ownership = owner, .data = data_a, .type_tag = 1 });
    try store.put(.{ .id = core.ObjectID.hash("flush-b"), .version = version, .ownership = owner, .data = data_b, .type_tag = 1 });

    store.lsm.sequence = std.math.maxInt(u64) - 1;
    try std.testing.expectError(error.ArithmeticOverflow, store.flushWriteBuffer());
    try std.testing.expectEqual(@as(usize, 1), store.write_buffer.items.len);

    const got_a = (try store.get(core.ObjectID.hash("flush-a"))).?;
    defer {
        var copy = got_a;
        copy.deinit(allocator);
    }
    try std.testing.expectEqualStrings("alpha", got_a.data);
    const got_b = (try store.get(core.ObjectID.hash("flush-b"))).?;
    defer {
        var copy_b = got_b;
        copy_b.deinit(allocator);
    }
    try std.testing.expectEqualStrings("beta", got_b.data);
}

test "ObjectStore put keeps buffer ownership when the flush fails" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/objstore_put_flush_fail";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var store = try ObjectStore.init(allocator, .{}, dir);
    defer store.deinit();
    store.write_buffer_threshold = 1;
    store.lsm.sequence = std.math.maxInt(u64);

    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const owner = core.Ownership.ownedBy(@as([32]u8, @splat(1)));
    const data = try allocator.dupe(u8, "kept");
    defer allocator.free(data);
    const id = core.ObjectID.hash("flush-fail");
    try std.testing.expectError(error.ArithmeticOverflow, store.put(.{
        .id = id,
        .version = version,
        .ownership = owner,
        .data = data,
        .type_tag = 1,
    }));
    try std.testing.expectEqual(@as(usize, 1), store.write_buffer.items.len);

    const got = (try store.get(id)).?;
    defer {
        var copy = got;
        copy.deinit(allocator);
    }
    try std.testing.expectEqualStrings("kept", got.data);
}

test "ObjectStore delete drops buffered copies" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/objstore_delete_buffer";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var store = try ObjectStore.init(allocator, .{}, dir);
    defer store.deinit();

    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const owner = core.Ownership.ownedBy(@as([32]u8, @splat(1)));
    const id = core.ObjectID.hash("buffered-delete");
    const first = try allocator.dupe(u8, "one");
    defer allocator.free(first);
    const second = try allocator.dupe(u8, "two");
    defer allocator.free(second);
    try store.put(.{ .id = id, .version = version, .ownership = owner, .data = first, .type_tag = 1 });
    try store.put(.{ .id = id, .version = version, .ownership = owner, .data = second, .type_tag = 1 });

    const latest = (try store.get(id)).?;
    defer {
        var copy = latest;
        copy.deinit(allocator);
    }
    try std.testing.expectEqualStrings("two", latest.data);

    try store.delete(id);
    try std.testing.expect((try store.get(id)) == null);
    try store.flushWriteBuffer();
    try std.testing.expect((try store.get(id)) == null);
}

test "ObjectStore getBatch releases objects loaded before a later failure" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/objstore_get_batch";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var store = try ObjectStore.init(allocator, .{}, dir);
    defer store.deinit();

    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const owner = core.Ownership.ownedBy(@as([32]u8, @splat(1)));
    const id_a = core.ObjectID.hash("batch-a");
    const id_b = core.ObjectID.hash("batch-b");
    const data = try allocator.dupe(u8, "alpha");
    defer allocator.free(data);
    try store.put(.{ .id = id_a, .version = version, .ownership = owner, .data = data, .type_tag = 1 });

    const bad_key = try allocator.dupe(u8, id_b.asBytes());
    const bad_val = try allocator.dupe(u8, "x");
    try store.write_buffer.append(allocator, .{ .key = bad_key, .value = bad_val });

    var results = [_]?Object{ null, null };
    try std.testing.expectError(error.InvalidFormat, store.getBatch(&.{ id_a, id_b }, &results));
    try std.testing.expect(results[0] == null);
    try std.testing.expect(results[1] == null);
}

test "ObjectStore rejects a field name that does not fit in one byte" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/objstore_field_name";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var store = try ObjectStore.init(allocator, .{}, dir);
    defer store.deinit();

    const id = core.ObjectID.hash("field-parent");
    var long_name: [256]u8 = @splat('a');
    try std.testing.expectError(error.FieldNameTooLong, store.addField(id, &long_name, "v"));
    try std.testing.expectError(error.FieldNameTooLong, store.getField(id, &long_name));

    try store.addField(id, "balance", "\x01");
    const got = (try store.getField(id, "balance")).?;
    defer allocator.free(got);
    try std.testing.expectEqualStrings("\x01", got);
}

test "ObjectStore parent links stay distinct and readable" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/objstore_parent_ref";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var store = try ObjectStore.init(allocator, .{}, dir);
    defer store.deinit();

    const child = core.ObjectID.hash("child");
    const parent_a = core.ObjectID.hash("parent-a");
    const parent_b = core.ObjectID.hash("parent-b");
    try store.addParentReference(child, &.{ parent_a, parent_b });

    const parents = try store.getParents(child);
    defer allocator.free(parents);
    try std.testing.expectEqual(@as(usize, 2), parents.len);
    var saw_a = false;
    var saw_b = false;
    for (parents) |parent| {
        if (parent.eql(parent_a)) saw_a = true;
        if (parent.eql(parent_b)) saw_b = true;
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);

    const children = try store.getChildren(parent_a);
    defer allocator.free(children);
    try std.testing.expectEqual(@as(usize, 1), children.len);
    try std.testing.expect(children[0].eql(child));
    try std.testing.expectEqual(@as(usize, 1), store.forkCount(parent_a));
    try std.testing.expectEqual(@as(usize, 0), store.forkCount(child));
}

test "ObjectStore drops a parent link when the reverse link cannot be stored" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/objstore_parent_partial";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    // One live reference is 65 + 32 + 24 bytes. The reverse link needs the same
    // amount, so a 210-byte memtable accepts the first put and the tombstone
    // (65 + 24) but refuses the second live record.
    var store = try ObjectStore.init(allocator, .{ .cache_size = 210 }, dir);
    defer store.deinit();

    const child = core.ObjectID.hash("child");
    const parent = core.ObjectID.hash("parent");
    try std.testing.expectError(error.MemTableFull, store.addParentReference(child, &.{parent}));

    const parents = try store.getParents(child);
    defer allocator.free(parents);
    try std.testing.expectEqual(@as(usize, 0), parents.len);

    const children = try store.getChildren(parent);
    defer allocator.free(children);
    try std.testing.expectEqual(@as(usize, 0), children.len);
}

test "ObjectStore mutation count saturates at the u64 limit" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/objstore_mutation_sat";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var store = try ObjectStore.init(allocator, .{}, dir);
    defer store.deinit();
    store.mutation_count = std.math.maxInt(u64);

    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const owner = core.Ownership.ownedBy(@as([32]u8, @splat(1)));
    const id = core.ObjectID.hash("sat-count");
    const data = try allocator.dupe(u8, "v");
    defer allocator.free(data);
    try store.put(.{ .id = id, .version = version, .ownership = owner, .data = data, .type_tag = 1 });
    try store.delete(id);
    try std.testing.expectEqual(std.math.maxInt(u64), store.mutation_count);
}

test "state snapshot replaces a store and preserves records" {
    const allocator = std.testing.allocator;
    const dir_a = "/tmp/zknot3-snap-a";
    const dir_b = "/tmp/zknot3-snap-b";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir_a) catch {};
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir_b) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir_a) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir_b) catch {};

    const id_a = core.ObjectID.hash("snap-a");
    const id_b = core.ObjectID.hash("snap-b");
    const id_c = core.ObjectID.hash("snap-c");
    const version = core.Version{ .seq = 1, .causal = @as([16]u8, @splat(0)) };
    const owner = core.Ownership.ownedBy(@as([32]u8, @splat(1)));

    var source = try ObjectStore.init(allocator, .{}, dir_a);
    defer source.deinit();
    const data_a = try allocator.dupe(u8, "alpha");
    defer allocator.free(data_a);
    const data_b = try allocator.dupe(u8, "beta");
    defer allocator.free(data_b);
    try source.put(.{ .id = id_a, .version = version, .ownership = owner, .data = data_a, .type_tag = 1 });
    try source.put(.{ .id = id_b, .version = version, .ownership = owner, .data = data_b, .type_tag = 1 });

    const checkpoint = @as([32]u8, @splat(0x5A));
    const blob = try source.exportStateSnapshot(4, checkpoint);
    defer allocator.free(blob);

    var dest = try ObjectStore.init(allocator, .{}, dir_b);
    defer dest.deinit();
    const data_c = try allocator.dupe(u8, "stale");
    defer allocator.free(data_c);
    try dest.put(.{ .id = id_c, .version = version, .ownership = owner, .data = data_c, .type_tag = 9 });

    const hdr = try dest.importStateSnapshot(blob);
    try std.testing.expectEqual(@as(u64, 4), hdr.checkpoint_sequence);
    try std.testing.expect(std.mem.eql(u8, &hdr.checkpoint_digest, &checkpoint));

    const got_a = (try dest.get(id_a)).?;
    defer {
        var copy = got_a;
        copy.deinit(allocator);
    }
    try std.testing.expectEqualStrings("alpha", got_a.data);
    const got_b = (try dest.get(id_b)).?;
    defer {
        var copy_b = got_b;
        copy_b.deinit(allocator);
    }
    try std.testing.expectEqualStrings("beta", got_b.data);
    try std.testing.expect((try dest.get(id_c)) == null);
}
