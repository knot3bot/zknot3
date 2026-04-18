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

/// WAL recovery options
pub const RecoveryOptions = struct {
    /// Whether to continue on corrupted records
    skip_corrupted: bool = false,
    /// Whether to validate record types
    validate_types: bool = true,
    /// Maximum record size to allow (prevents OOM)
    max_record_size: usize = 10 * 1024 * 1024, // 10 MB
};

/// WAL recovery result
pub const RecoveryResult = struct {
    records_replayed: usize,
    corrupted_records: usize,
    errors: usize,
};

/// Compatibility wrapper for std.Io.File providing old std.fs.File-like API
const CompatFile = struct {
    file: std.Io.File,

    pub fn close(self: CompatFile) void {
        self.file.close(@import("io_instance").io);
    }

    pub fn stat(self: CompatFile) !std.Io.File.Stat {
        return self.file.stat(@import("io_instance").io);
    }

    pub fn seekTo(self: CompatFile, offset: u64) !void {
        var reader = self.file.reader(@import("io_instance").io, &.{});
        try reader.seekTo(offset);
    }

    pub fn writeAll(self: CompatFile, bytes: []const u8) !void {
        try self.file.writeStreamingAll(@import("io_instance").io, bytes);
    }

    pub fn sync(self: CompatFile) !void {
        try self.file.sync(@import("io_instance").io);
    }

    pub fn setEndPos(self: CompatFile, length: u64) !void {
        try self.file.setLength(@import("io_instance").io, length);
    }

    pub fn readAll(self: CompatFile, buf: []u8) !usize {
        var reader = self.file.reader(@import("io_instance").io, &.{});
        return reader.interface.readSliceShort(buf) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
    }
};
/// Write-Ahead Log for durability
// Async WAL write buffer
const AsyncWriteBuffer = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    buffer: []u8,
    write_offset: usize,
    flush_threshold: usize,
    flush_in_progress: bool = false,

    pub fn init(allocator: std.mem.Allocator, threshold: usize) !Self {
        return Self{
            .allocator = allocator,
            .buffer = try allocator.alloc(u8, threshold * 2), // Double the threshold for safety
            .write_offset = 0,
            .flush_threshold = threshold,
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.buffer);
    }

    pub fn append(self: *Self, data: []const u8) !bool {
        if (self.write_offset + data.len > self.buffer.len) {
            return false; // Buffer full
        }

        @memcpy(self.buffer[self.write_offset..][0..data.len], data);
        self.write_offset += data.len;

        return self.write_offset >= self.flush_threshold;
    }

    pub fn getAndReset(self: *Self) []const u8 {
        const data = self.buffer[0..self.write_offset];
        self.write_offset = 0;
        return data;
    }
};

pub const WAL = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    file: CompatFile,
    file_path: []const u8,
    current_offset: u64,
    async_write: ?AsyncWriteBuffer = null,
    use_async_writes: bool = true,

    /// Initialize WAL with async options
    pub fn initWithOptions(allocator: std.mem.Allocator, db_path: []const u8, use_async: ?bool) !Self {
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{db_path});
        errdefer allocator.free(wal_path);

        // Open or create WAL file
        const inner_file = std.Io.Dir.cwd().createFile(@import("io_instance").io, wal_path, .{
            .read = true,
            .truncate = false,
        }) catch |err| {
            allocator.free(wal_path);
            return err;
        };
        const file = CompatFile{ .file = inner_file };
        errdefer file.close();

        // Get current file size for append offset
        const stat = try file.stat();

        // Initialize async buffer if requested
        const async_write = if (use_async orelse true) try AsyncWriteBuffer.init(allocator, 64 * 1024) else null;

        return .{
            .allocator = allocator,
            .file = file,
            .file_path = wal_path,
            .current_offset = stat.size,
            .async_write = async_write,
            .use_async_writes = use_async orelse true,
        };
    }
    
    /// Initialize WAL with default sync mode


    /// Initialize WAL (sync mode)
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Self {
        return try initWithOptions(allocator, db_path, null);
    }
    pub fn deinit(self: *Self) void {
        // Flush any pending async writes first
        if (self.async_write) |*async_w| {
            if (async_w.write_offset > 0) {
                const data = async_w.getAndReset();
                self.file.seekTo(self.current_offset) catch {};
                self.file.writeAll(data) catch {};
                self.file.sync() catch {};
            }
            async_w.deinit();
        }
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

    /// Append record to WAL with async support
    fn appendRecord(self: *Self, record_type: WalRecordType, key: []const u8, value: ?[]const u8) !void {
        const value_len: u32 = if (value) |v| @intCast(v.len) else 0;
        const key_len: u32 = @intCast(key.len);

        // Build header
        var header = WalRecordHeader{
            .checksum = 0, // Computed below after preparing header body
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
        try checksum_data.appendSlice(self.allocator, header_bytes[4..]);
        try checksum_data.appendSlice(self.allocator, key);
        if (value) |v| {
            try checksum_data.appendSlice(self.allocator, v);
        }

        header.checksum = std.hash.Crc32.hash(checksum_data.items);

        // Create a complete buffer for this record
        var record_buffer: std.ArrayList(u8) = .empty;
        defer record_buffer.deinit(self.allocator);
        
        try record_buffer.appendSlice(self.allocator, std.mem.asBytes(&header));
        try record_buffer.appendSlice(self.allocator, key);
        if (value) |v| {
            try record_buffer.appendSlice(self.allocator, v);
        }

        const record_data = record_buffer.items;
        
        if (self.use_async_writes and self.async_write != null) {
            const async_w = &self.async_write.?;
            // Try async write first
            const should_flush = try async_w.append(record_data);
            
            if (should_flush) {
                // Flush the buffer
                try self.flushAsync();
            }
        } else {
            // Sync write for backward compatibility
            try self.file.seekTo(self.current_offset);
            try self.file.writeAll(record_data);
            try self.file.sync();
        }

        // Update offset in all cases
        self.current_offset += @sizeOf(WalRecordHeader) + key_len + value_len;
    }
    
    /// Flush async write buffer to disk
    pub fn flushAsync(self: *Self) !void {
        if (!self.use_async_writes or self.async_write == null) return;
        
        const async_w = &self.async_write.?;
        
        if (async_w.write_offset > 0) {
            const data = async_w.getAndReset();
            try self.file.seekTo(self.current_offset - async_w.write_offset);
            try self.file.writeAll(data);
            try self.file.sync();
        }
    }
    
    /// Force sync both async buffer and file
    pub fn syncAll(self: *Self) !void {
        try self.flushAsync();
        try self.file.sync();
    }

    /// Clear WAL after commit
    pub fn clear(self: *Self) !void {
        try self.file.setEndPos(0);
        try self.file.sync();
        self.current_offset = 0;
    }

    /// Recovery: replay WAL records
    pub const ReplayCallback = *const fn (op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void;
    pub fn replay(self: *Self, callback: ReplayCallback, ctx: *anyopaque) !RecoveryResult {
        return try self.replayWithOptions(callback, ctx, .{});
    }

    /// Recovery with options
    pub fn replayWithOptions(self: *Self, callback: ReplayCallback, ctx: *anyopaque, options: RecoveryOptions) !RecoveryResult {
        try self.file.seekTo(0);

        var buf: [@sizeOf(WalRecordHeader)]u8 = undefined;
        var offset: u64 = 0;
        var records_replayed: usize = 0;
        var corrupted_records: usize = 0;
        var errors: usize = 0;

        while (offset < self.current_offset) {
            // Read header
            const bytes_read = try self.file.readAll(&buf);
            if (bytes_read < @sizeOf(WalRecordHeader)) {
                if (bytes_read == 0) break; // EOF
                errors += 1;
                break;
            }

            const header = @as(*const WalRecordHeader, @alignCast(@ptrCast(&buf))).*;

            // Validate record fields before using them
            if (header.record_type < 1 or header.record_type > 4) {
                if (options.skip_corrupted) {
                    corrupted_records += 1;
                    offset += @sizeOf(WalRecordHeader);
                    continue;
                } else {
                    errors += 1;
                    break;
                }
            }
            const max_record_size = options.max_record_size;
            if (header.key_len > max_record_size or header.value_len > max_record_size) {
                if (options.skip_corrupted) {
                    corrupted_records += 1;
                    offset += @sizeOf(WalRecordHeader) + header.key_len + header.value_len;
                    continue;
                } else {
                    errors += 1;
                    break;
                }
            }

            // Verify checksum
            const computed = std.hash.Crc32.hash(buf[4..]);
            if (computed != header.checksum) {
                if (options.skip_corrupted) {
                    corrupted_records += 1;
                    offset += @sizeOf(WalRecordHeader) + header.key_len + header.value_len;
                    continue;
                } else {
                    errors += 1;
                    break;
                }
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
                defer if (value_buf) |v| self.allocator.free(v);
                _ = try self.file.readAll(value_buf.?);
            }

            // Apply record
            const record_type = @as(WalRecordType, @enumFromInt(header.record_type));
            callback(record_type, key_buf, value_buf, ctx) catch {
                errors += 1;
                if (!options.skip_corrupted) {
                    break;
                }
            };

            records_replayed += 1;
            offset += @sizeOf(WalRecordHeader) + header.key_len + header.value_len;
        }

        return .{
            .records_replayed = records_replayed,
            .corrupted_records = corrupted_records,
            .errors = errors,
        };
    }
};

test "WAL basic operations" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_path = "/tmp/wal_test.db";

    // Clean up any existing WAL
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path ++ ".wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

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
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path ++ ".wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
}

test "WAL replay recovers inserted records" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_path = "/tmp/wal_replay_test.db";

    // Clean up
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path ++ ".wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

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
        _ = try wal.replay(&callback, &counters);

    try std.testing.expectEqual(@as(u32, 2), counters.inserts);
    try std.testing.expectEqual(@as(u32, 1), counters.deletes);
    try std.testing.expectEqual(@as(u32, 1), counters.commits);

    // Clean up
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path ++ ".wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
}
test "WAL replay after crash simulation" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_path = "/tmp/wal_crash_test.db";

    // Clean up
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path ++ ".wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

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

        _ = try wal.replay(&callback, &counters);

        // Uncommitted data should still be replayed (recovery replays all)
        try std.testing.expectEqual(@as(u32, 2), counters.inserts);
        try std.testing.expectEqual(@as(u32, 0), counters.commits); // No commit was logged
    }

    // Clean up
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path ++ ".wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
}

test "WAL clear resets state" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_path = "/tmp/wal_clear_test.db";

    // Clean up
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path ++ ".wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

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

        _ = try wal.replay(&callback, &counters);
    try std.testing.expectEqual(@as(u32, 0), counters.count);

    // Clean up
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path ++ ".wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
}

