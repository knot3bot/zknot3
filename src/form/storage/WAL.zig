//! WAL - Write-Ahead Log for crash recovery
//!
//! Provides durability through pre-logging modifications before applying
//! to the main database. On crash, WAL can replay uncommitted transactions.
//!
//! Reference: kvdb WAL implementation with CRC32 checksums

const std = @import("std");

/// WAL record types
pub const WalRecordType = enum(u8) {
    insert = 1,
    delete = 2,
    commit = 3,
    abort = 4,
};

/// WAL record header (16 bytes)
pub const WalRecordHeader = extern struct {
    checksum: u32, // CRC32 of record content
    record_type: u8, // WalRecordType
    key_len: u32, // Key length
    value_len: u32, // Value length (0 for deletes)
    _pad: u32 = 0, // Alignment padding
};

/// WAL error types
pub const WalError = error{
    InvalidChecksum,
    CorruptedRecord,
    WriteFailed,
    ReadFailed,
    InvalidRecordType,
};

/// Write-Ahead Log for durability
pub const WAL = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    file: std.fs.File,
    file_path: []const u8,
    current_offset: u64,

    /// Initialize WAL
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Self {
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{db_path});
        errdefer allocator.free(wal_path);

        // Open or create WAL file
        const file = std.fs.cwd().createFile(wal_path, .{
            .read = true,
            .truncate = false,
        }) catch |err| {
            allocator.free(wal_path);
            return err;
        };
        errdefer file.close();

        // Get current file size for append offset
        const stat = try file.stat();

        return .{
            .allocator = allocator,
            .file = file,
            .file_path = wal_path,
            .current_offset = stat.size,
        };
    }

    /// Close WAL and free resources
    pub fn deinit(self: *Self) void {
        self.file.close();
        self.allocator.free(self.file_path);
    }

    /// Compute CRC32 checksum
    fn computeChecksum(header_no_checksum: *[12]u8, key: []const u8, value: ?[]const u8) u32 {
        var crc: u32 = 0xFFFFFFFF;

        // Hash header (excluding checksum field at offset 0)
        crc ^= std.hash.Crc32.hash(header_no_checksum[4..]);
        crc = (crc >> 1) ^ (0xEDB88320 * (crc & 1));

        // Hash key
        crc ^= std.hash.Crc32.hash(key);
        crc = (crc >> 1) ^ (0xEDB88320 * (crc & 1));

        // Hash value if present
        if (value) |v| {
            crc ^= std.hash.Crc32.hash(v);
            crc = (crc >> 1) ^ (0xEDB88320 * (crc & 1));
        }

        return crc ^ 0xFFFFFFFF;
    }

    /// Log an insert operation
    pub fn logInsert(self: *Self, key: []const u8, value: []const u8) !void {
        return self.appendRecord(.insert, key, value);
    }

    /// Log a delete operation
    pub fn logDelete(self: *Self, key: []const u8) !void {
        return self.appendRecord(.delete, key, null);
    }

    /// Log transaction commit
    pub fn logCommit(self: *Self) !void {
        // Commit records have empty key/value
        return self.appendRecord(.commit, &.{}, null);
    }

    /// Log transaction abort
    pub fn logAbort(self: *Self) !void {
        return self.appendRecord(.abort, &.{}, null);
    }

    /// Append record to WAL
    fn appendRecord(self: *Self, record_type: WalRecordType, key: []const u8, value: ?[]const u8) !void {
        const value_len: u32 = if (value) |v| @intCast(v.len) else 0;
        const key_len: u32 = @intCast(key.len);

        // Build header
        var header = WalRecordHeader{
            .checksum = 0, // Placeholder
            .record_type = @intFromEnum(record_type),
            .key_len = key_len,
            .value_len = value_len,
            ._pad = 0,
        };

        // Compute checksum over header (excluding checksum field) + key + value
        var header_bytes = std.mem.asBytes(&header);
        var checksum_data: std.ArrayList(u8) = .empty;
        defer checksum_data.deinit(self.allocator);

        // Skip checksum field (first 4 bytes) for checksum calculation
        try checksum_data.appendSlice(header_bytes[4..]);
        try checksum_data.appendSlice(key);
        if (value) |v| {
            try checksum_data.appendSlice(v);
        }

        header.checksum = std.hash.Crc32.hash(checksum_data.items);

        // Write to file
        try self.file.seekTo(self.current_offset);
        try self.file.writeAll(std.mem.asBytes(&header));
        try self.file.writeAll(key);
        if (value) |v| {
            try self.file.writeAll(v);
        }

        // Force sync for durability
        try self.file.sync();

        // Update offset
        self.current_offset += @sizeOf(WalRecordHeader) + key_len + value_len;
    }

    /// Clear WAL after commit
    pub fn clear(self: *Self) !void {
        try self.file.setEndPos(0);
        try self.file.sync();
        self.current_offset = 0;
    }

    /// Recovery: replay WAL records
    pub const ReplayCallback = *const fn (op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void;
    pub fn replay(self: *Self, callback: ReplayCallback, ctx: *anyopaque) !void {
        try self.file.seekTo(0);

        var buf: [@sizeOf(WalRecordHeader)]u8 = undefined;
        var offset: u64 = 0;

        while (offset < self.current_offset) {
            // Read header
            const bytes_read = try self.file.readAll(&buf);
            if (bytes_read < @sizeOf(WalRecordHeader)) break;

            const header = @as(*const WalRecordHeader, @alignCast(@ptrCast(&buf))).*;

            // Validate record fields before using them
            if (header.record_type < 1 or header.record_type > 4) {
                return WalError.CorruptedRecord;
            }
            const max_record_size = 10 * 1024 * 1024; // 10 MB
            if (header.key_len > max_record_size or header.value_len > max_record_size) {
                return WalError.CorruptedRecord;
            }

            // Verify checksum
            const computed = std.hash.Crc32.hash(buf[4..]);
            if (computed != header.checksum) {
                return WalError.InvalidChecksum;
            }

            // Read key
            const key_buf: []u8 = try self.allocator.alloc(u8, header.key_len);
            defer self.allocator.free(key_buf);

            if (header.key_len > 0) {
                _ = try self.file.readAll(key_buf);
            }
            // Read value
            var value_buf: ?[]u8 = null;
            if (header.value_len > 0) {
                value_buf = try self.allocator.alloc(u8, header.value_len);
                _ = try self.file.readAll(value_buf.?);
            }

            // Apply record
            const record_type = @as(WalRecordType, @enumFromInt(header.record_type));
            try callback(record_type, key_buf, value_buf, ctx);

            if (value_buf) |v| {
                self.allocator.free(v);
            }

            offset += @sizeOf(WalRecordHeader) + header.key_len + header.value_len;
        }
    }
};

test "WAL basic operations" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/wal_test.db";

    // Clean up any existing WAL
    std.fs.cwd().deleteFile(test_path ++ ".wal") catch {};
    std.fs.cwd().deleteFile(test_path) catch {};

    // Initialize WAL
    var wal = try WAL.init(allocator, test_path);
    defer wal.deinit();

    // Log some operations
    try wal.logInsert("key1", "value1");
    try wal.logInsert("key2", "value2");
    try wal.logDelete("key1");
    try wal.logCommit();

    // Verify WAL has content
    try std.testing.expect(wal.current_offset > 0);

    // Clean up
    std.fs.cwd().deleteFile(test_path ++ ".wal") catch {};
    std.fs.cwd().deleteFile(test_path) catch {};
}

test "WAL replay recovers inserted records" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/wal_replay_test.db";

    // Clean up
    std.fs.cwd().deleteFile(test_path ++ ".wal") catch {};
    std.fs.cwd().deleteFile(test_path) catch {};

    // Create WAL and log operations
    var wal = try WAL.init(allocator, test_path);
    defer wal.deinit();

    // Track replayed records using state struct with context
    const State = struct {
        inserts: u32 = 0,
        deletes: u32 = 0,
        commits: u32 = 0,
    };

    var counters: State = .{ };
    const callback = struct {
        fn cb(op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void {
            _ = key; _ = value;
            const s = @as(*State, @ptrCast(@alignCast(ctx)));
            switch (op) {
                .insert => s.inserts += 1,
                .delete => s.deletes += 1,
                .commit => s.commits += 1,
                else => {},
            }
        }
    }.cb;

    try wal.logInsert("key1", "value1");
    try wal.logInsert("key2", "value2");
    try wal.logDelete("key1");
    try wal.logCommit();

    // Replay and verify
    try wal.replay(&callback, &counters);

    try std.testing.expectEqual(@as(u32, 2), counters.inserts);
    try std.testing.expectEqual(@as(u32, 1), counters.deletes);
    try std.testing.expectEqual(@as(u32, 1), counters.commits);

    // Clean up
    std.fs.cwd().deleteFile(test_path ++ ".wal") catch {};
    std.fs.cwd().deleteFile(test_path) catch {};
}
test "WAL replay after crash simulation" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/wal_crash_test.db";

    // Clean up
    std.fs.cwd().deleteFile(test_path ++ ".wal") catch {};
    std.fs.cwd().deleteFile(test_path) catch {};

    // Phase 1: Write some data (simulate crash before commit)
    {
        var wal = try WAL.init(allocator, test_path);
        try wal.logInsert("txn1_key", "txn1_value");
        try wal.logInsert("txn2_key", "txn2_value");
        // Intentionally NOT committing - simulates crash
        wal.deinit();
    }

    // Phase 2: Re-open WAL and replay (recovery)
    {
        var wal = try WAL.init(allocator, test_path);
        defer wal.deinit();

        const State = struct {
            inserts: u32 = 0,
            commits: u32 = 0,
        };

        var counters: State = .{ };
        const callback = struct {
            fn cb(op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void {
                _ = key; _ = value;
                const s = @as(*State, @ptrCast(@alignCast(ctx)));
                switch (op) {
                    .insert => s.inserts += 1,
                    .commit => s.commits += 1,
                    else => {},
                }
            }
        }.cb;

        try wal.replay(&callback, &counters);

        // Uncommitted data should still be replayed (recovery replays all)
        try std.testing.expectEqual(@as(u32, 2), counters.inserts);
        try std.testing.expectEqual(@as(u32, 0), counters.commits); // No commit was logged
    }

    // Clean up
    std.fs.cwd().deleteFile(test_path ++ ".wal") catch {};
    std.fs.cwd().deleteFile(test_path) catch {};
}

test "WAL clear resets state" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/wal_clear_test.db";

    // Clean up
    std.fs.cwd().deleteFile(test_path ++ ".wal") catch {};
    std.fs.cwd().deleteFile(test_path) catch {};

    var wal = try WAL.init(allocator, test_path);
    defer wal.deinit();

    // Log and commit
    try wal.logInsert("key", "value");
    try wal.logCommit();
    try std.testing.expect(wal.current_offset > 0);

    // Clear WAL
    try wal.clear();
    try std.testing.expectEqual(@as(u64, 0), wal.current_offset);

    // Replay should find nothing
    const State = struct {
        count: u32 = 0,
    };

    var counters: State = .{ };
    const callback = struct {
        fn cb(op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void {
            _ = op; _ = key; _ = value;
            const s = @as(*State, @ptrCast(@alignCast(ctx)));
            s.count += 1;
        }
    }.cb;

    try wal.replay(&callback, &counters);
    try std.testing.expectEqual(@as(u32, 0), counters.count);

    // Clean up
    std.fs.cwd().deleteFile(test_path ++ ".wal") catch {};
    std.fs.cwd().deleteFile(test_path) catch {};
}

