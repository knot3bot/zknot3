//! WAL - Write-Ahead Log for crash recovery
//!
//! Provides durability through pre-logging modifications before applying
//! to the main database. On crash, WAL can replay uncommitted transactions.
//!
//! Reference: kvdb WAL implementation with CRC32 checksums

const std = @import("std");
const IOUring = @import("IOUring.zig");

/// WAL record types
pub const WalRecordType = enum(u8) {
    insert = 1,
    delete = 2,
    commit = 3,
    abort = 4,
    /// M4 mainnet extension (separate WAL file from LSM; never mixed into LSM WAL).
    m4_stake_operation = 10,
    m4_governance_proposal = 11,
    m4_governance_status = 12,
    m4_equivocation_evidence = 13,
    m4_state_snapshot = 14,
    m4_epoch_advance = 15,
    m4_validator_set_rotate = 16,
    m4_governance_vote = 17,
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
    /// Inclusive upper bound for `record_type` (LSM uses 1–4; M4 extension uses 10–14).
    max_record_type: u8 = 4,
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
    read_pos: u64 = 0,

    pub fn close(self: CompatFile) void {
        self.file.close(@import("io_instance").io);
    }

    pub fn stat(self: CompatFile) !std.Io.File.Stat {
        return self.file.stat(@import("io_instance").io);
    }

    pub fn seekTo(self: *CompatFile, offset: u64) !void {
        self.read_pos = offset;
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

    pub fn readAll(self: *CompatFile, buf: []u8) !usize {
        const n = try self.file.readPositionalAll(@import("io_instance").io, buf, self.read_pos);
        self.read_pos += n;
        return n;
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
    durability_io: ?*IOUring.AsyncIO = null,

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
        const durability_io = IOUring.AsyncIO.init(allocator, IOUring.getRecommendedConfig()) catch null;

        return .{
            .allocator = allocator,
            .file = file,
            .file_path = wal_path,
            .current_offset = stat.size,
            .async_write = async_write,
            .use_async_writes = use_async orelse true,
            .durability_io = durability_io,
        };
    }
    
    /// Initialize WAL with default sync mode


    /// Initialize WAL (sync mode)
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Self {
        return try initWithOptions(allocator, db_path, null);
    }
    pub fn deinit(self: *Self) void {
        // Flush any pending async writes first.
        if (self.async_write) |*async_w| {
            if (async_w.write_offset > 0) {
                const write_offset = async_w.write_offset;
                const data = async_w.getAndReset();
                self.file.file.writePositionalAll(@import("io_instance").io, data, self.current_offset - write_offset) catch {};
                self.syncBarrier() catch {};
            }
            async_w.deinit();
        }
        if (self.durability_io) |dio| {
            dio.deinit();
            self.durability_io = null;
        }
        self.file.close();
        self.allocator.free(self.file_path);
    }

    fn syncBarrier(self: *Self) !void {
        if (self.durability_io) |dio| {
            return dio.fsync(self.file.file.handle);
        }
        return self.file.sync();
    }

    /// Durable write at `offset`. When the io_uring durability ring is attached
    /// this submits write+fsync as a linked chain (one submit_and_wait instead
    /// of two), preserving the same ordering guarantees as the legacy
    /// `writeAll` + `syncBarrier` pair on non-Linux / fallback backends.
    fn writeDurable(self: *Self, data: []const u8, offset: u64) !void {
        if (self.durability_io) |dio| {
            const n = try dio.writeAndFsync(self.file.file.handle, data, offset);
            if (n != data.len) return error.ShortWrite;
            return;
        }
        try self.file.file.writePositionalAll(@import("io_instance").io, data, offset);
        try self.file.sync();
    }

    /// Gathered durable write at `offset`. Submits a single `pwritev + fsync`
    /// chain on the io_uring path (one `submit_and_wait(2)`), eliminating the
    /// caller-side "concat header + key + value into one contiguous buffer"
    /// memcpy that `appendRecord` used to perform. Falls back to sequential
    /// per-segment `writeAll` + `sync` on non-Linux / missing durability ring,
    /// preserving the same ordering and atomicity contract from the caller's
    /// point of view.
    fn writevDurable(self: *Self, iovecs: []const std.posix.iovec_const, offset: u64) !void {
        var expected: usize = 0;
        for (iovecs) |iov| expected += iov.len;
        if (self.durability_io) |dio| {
            const n = try dio.writevAndFsync(self.file.file.handle, iovecs, offset);
            if (n != expected) return error.ShortWrite;
            return;
        }
        // Fallback path: no gather syscall available, write each segment at
        // incrementing offsets, then one fsync.
        var cur = offset;
        for (iovecs) |iov| {
            const bytes = @as([*]const u8, @ptrCast(iov.base))[0..iov.len];
            try self.file.file.writePositionalAll(@import("io_instance").io, bytes, cur);
            cur += iov.len;
        }
        try self.file.sync();
    }

    /// Compute CRC32 checksum over record body:
    /// header_without_checksum + key + value
    fn computeRecordChecksum(
        allocator: std.mem.Allocator,
        header_without_checksum: []const u8,
        key: []const u8,
        value: []const u8,
    ) !u32 {
        var checksum_data: std.ArrayList(u8) = .empty;
        defer checksum_data.deinit(allocator);

        try checksum_data.appendSlice(allocator, header_without_checksum);
        try checksum_data.appendSlice(allocator, key);
        try checksum_data.appendSlice(allocator, value);
        return std.hash.Crc32.hash(checksum_data.items);
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

    /// Append an extension record (empty key, arbitrary payload). Used for M4 durability WAL.
    pub fn logExtensionRecord(self: *Self, record_type: WalRecordType, payload: []const u8) !void {
        return self.appendRecord(record_type, &.{}, payload);
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

        // Compute checksum over header (without checksum) + key + value.
        var header_bytes = std.mem.asBytes(&header);
        const value_slice = value orelse &.{};
        header.checksum = try computeRecordChecksum(self.allocator, header_bytes[4..], key, value_slice);

        // Build scatter iovecs for header / key / value (no memcpy concat).
        // `writevDurable` fan-outs these through a single pwritev + fsync on
        // io_uring, or falls back to per-segment writeAll on other backends.
        const header_slice = std.mem.asBytes(&header);
        var iovec_buf: [3]std.posix.iovec_const = undefined;
        var iovec_len: usize = 0;
        iovec_buf[iovec_len] = .{ .base = header_slice.ptr, .len = header_slice.len };
        iovec_len += 1;
        if (key.len > 0) {
            iovec_buf[iovec_len] = .{ .base = key.ptr, .len = key.len };
            iovec_len += 1;
        }
        if (value) |v| {
            if (v.len > 0) {
                iovec_buf[iovec_len] = .{ .base = v.ptr, .len = v.len };
                iovec_len += 1;
            }
        }

        if (self.use_async_writes and self.async_write != null) {
            // Buffered async path still needs a contiguous copy to accumulate
            // multiple records into one flush, but the number of memcpys here
            // is unchanged vs the legacy concat buffer.
            const async_w = &self.async_write.?;
            const total_len = @sizeOf(WalRecordHeader) + key.len + value_slice.len;
            // If the record alone exceeds the buffered capacity, flush and
            // write it directly via writevDurable.
            if (total_len > async_w.buffer.len) {
                if (async_w.write_offset > 0) try self.flushAsync();
                try self.writevDurable(iovec_buf[0..iovec_len], self.current_offset);
            } else {
                // Ensure room: flush first if this record wouldn't fit.
                if (async_w.write_offset + total_len > async_w.buffer.len) {
                    try self.flushAsync();
                }
                var wrote: usize = 0;
                for (iovec_buf[0..iovec_len]) |iov| {
                    const bytes = @as([*]const u8, @ptrCast(iov.base))[0..iov.len];
                    const fits = try async_w.append(bytes);
                    wrote += iov.len;
                    _ = fits; // threshold check handled below after whole record lands
                }
                if (async_w.write_offset >= async_w.flush_threshold) {
                    try self.flushAsync();
                }
            }
        } else {
            // Sync path: gather header/key/value via pwritev + linked fsync.
            try self.writevDurable(iovec_buf[0..iovec_len], self.current_offset);
        }

        // Update offset in all cases
        self.current_offset += @sizeOf(WalRecordHeader) + key_len + value_len;
    }
    
    /// Flush async write buffer to disk
    pub fn flushAsync(self: *Self) !void {
        if (!self.use_async_writes or self.async_write == null) return;

        const async_w = &self.async_write.?;

        if (async_w.write_offset > 0) {
            const write_offset = async_w.write_offset;
            const data = async_w.getAndReset();
            // Buffered bytes were accounted in current_offset at append time,
            // so compute the start offset before getAndReset zeroes write_offset.
            try self.writeDurable(data, self.current_offset - write_offset);
        }
    }
    
    /// Force sync both async buffer and file
    pub fn syncAll(self: *Self) !void {
        try self.flushAsync();
        try self.syncBarrier();
    }

    /// Clear WAL after commit
    pub fn clear(self: *Self) !void {
        try self.flushAsync();
        try self.file.setEndPos(0);
        try self.syncBarrier();
        self.current_offset = 0;
    }

    /// Recovery: replay WAL records
    pub const ReplayCallback = *const fn (op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void;
    pub fn replay(self: *Self, callback: ReplayCallback, ctx: *anyopaque) !RecoveryResult {
        return try self.replayWithOptions(callback, ctx, .{});
    }

    /// Recovery with options
    pub fn replayWithOptions(self: *Self, callback: ReplayCallback, ctx: *anyopaque, options: RecoveryOptions) !RecoveryResult {
        try self.flushAsync();
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
            if (header.record_type < 1 or header.record_type > options.max_record_type) {
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

            // Read key
            const key_buf: []u8 = try self.allocator.alloc(u8, header.key_len);
            defer self.allocator.free(key_buf);
            if (header.key_len > 0) {
                _ = try self.file.readAll(key_buf);
            }

            // Read value
            var value_buf: ?[]u8 = null;
            defer if (value_buf) |v| self.allocator.free(v);
            if (header.value_len > 0) {
                value_buf = try self.allocator.alloc(u8, header.value_len);
                _ = try self.file.readAll(value_buf.?);
            }

            // Verify checksum using the exact same algorithm as write path.
            const computed = try computeRecordChecksum(self.allocator, buf[4..], key_buf, value_buf orelse &.{});
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

test "WAL detects tampered record checksum" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_path = "/tmp/wal_tamper_test.db";
    const wal_path = test_path ++ ".wal";

    std.Io.Dir.cwd().deleteFile(std.testing.io, wal_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

    // Write a normal WAL first.
    {
        var wal = try WAL.init(allocator, test_path);
        try wal.logInsert("tamper_key", "tamper_value");
        try wal.logCommit();
        wal.deinit();
    }

    // Read, tamper one byte, and write back.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, wal_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);

    var tampered = try allocator.dupe(u8, bytes);
    defer allocator.free(tampered);
    const idx = tampered.len / 2;
    tampered[idx] ^=
        0x5a;

    const f = try std.Io.Dir.cwd().createFile(std.testing.io, wal_path, .{ .truncate = true, .read = true });
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, tampered);
    try f.sync(std.testing.io);

    var wal = try WAL.init(allocator, test_path);
    defer wal.deinit();

    const State = struct { replayed: usize = 0 };
    var state: State = .{};
    const callback = struct {
        fn cb(op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void {
            _ = op;
            _ = key;
            _ = value;
            const s = @as(*State, @ptrCast(@alignCast(ctx)));
            s.replayed += 1;
        }
    }.cb;

    const result = try wal.replay(&callback, &state);
    try std.testing.expect(result.errors > 0 or result.corrupted_records > 0);

    std.Io.Dir.cwd().deleteFile(std.testing.io, wal_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
}

test "WAL skip_corrupted continues replay" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_path = "/tmp/wal_skip_corrupted_test.db";
    const wal_path = test_path ++ ".wal";

    std.Io.Dir.cwd().deleteFile(std.testing.io, wal_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

    {
        var wal = try WAL.init(allocator, test_path);
        try wal.logInsert("k1", "v1");
        try wal.logInsert("k2", "v2");
        try wal.logCommit();
        wal.deinit();
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, wal_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 4);

    var tampered = try allocator.dupe(u8, bytes);
    defer allocator.free(tampered);
    tampered[3] ^=
        0xff;

    const f = try std.Io.Dir.cwd().createFile(std.testing.io, wal_path, .{ .truncate = true, .read = true });
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, tampered);
    try f.sync(std.testing.io);

    var wal = try WAL.init(allocator, test_path);
    defer wal.deinit();

    const State = struct { replayed: usize = 0 };
    var state: State = .{};
    const callback = struct {
        fn cb(op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void {
            _ = op;
            _ = key;
            _ = value;
            const s = @as(*State, @ptrCast(@alignCast(ctx)));
            s.replayed += 1;
        }
    }.cb;

    const result = try wal.replayWithOptions(&callback, &state, .{ .skip_corrupted = true });
    try std.testing.expect(result.corrupted_records > 0);

    std.Io.Dir.cwd().deleteFile(std.testing.io, wal_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
}

test "WAL truncated tail during crash is detected" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_path = "/tmp/wal_truncated_tail_test.db";
    const wal_path = test_path ++ ".wal";

    std.Io.Dir.cwd().deleteFile(std.testing.io, wal_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

    {
        var wal = try WAL.init(allocator, test_path);
        try wal.logInsert("tail_k1", "tail_v1");
        try wal.logInsert("tail_k2", "tail_v2");
        try wal.logCommit();
        wal.deinit();
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        wal_path,
        allocator,
        std.Io.Limit.limited(1024 * 1024),
    );
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 8);

    const truncated_len = bytes.len - 7;
    const f = try std.Io.Dir.cwd().createFile(std.testing.io, wal_path, .{ .truncate = true, .read = true });
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, bytes[0..truncated_len]);
    try f.sync(std.testing.io);

    var wal = try WAL.init(allocator, test_path);
    defer wal.deinit();

    const State = struct { replayed: usize = 0 };
    var state: State = .{};
    const callback = struct {
        fn cb(op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void {
            _ = op;
            _ = key;
            _ = value;
            const s = @as(*State, @ptrCast(@alignCast(ctx)));
            s.replayed += 1;
        }
    }.cb;

    const strict_result = try wal.replay(&callback, &state);
    try std.testing.expect(strict_result.errors > 0 or strict_result.corrupted_records > 0);

    const tolerant_result = try wal.replayWithOptions(&callback, &state, .{ .skip_corrupted = true });
    try std.testing.expect(tolerant_result.corrupted_records > 0 or tolerant_result.errors > 0);

    std.Io.Dir.cwd().deleteFile(std.testing.io, wal_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
}

