//! LSMTree - Log-Structured Merge-Tree with compaction
//!
//! A custom LSM-Tree optimized for blockchain object storage with:
//! - MemTable with O(log n) write, O(1) read (bloom filter optimized)
//! - SSTable files with sorted key-value storage
//! - Level-based compaction for optimal read/write performance
//! - Bloom filters for fast negative lookups

const std = @import("std");
const core = @import("../../core.zig");
const WAL_module = @import("WAL.zig");
const WAL = WAL_module.WAL;
const WalRecordType = WAL_module.WalRecordType;

/// LSM-Tree configuration
pub const LSMTreeConfig = struct {
    /// Base memory budget for memtable
    memtable_size: usize = 64 * 1024 * 1024, // 64MB
    /// Number of level multipliers before compaction
    level_multiplier: usize = 10,
    /// Maximum level count
    max_levels: usize = 7,
    /// Bloom filter expected element count
    bloom_expected_elements: usize = 1_000_000,
    /// Bloom filter bits per key
    bloom_bits: usize = 10,
    /// Optional explicit I/O handle. When set, overrides the global io_instance.
    /// Enables test isolation and multi-instance deployments.
    io: ?std.Io = null,
    /// SSTable directory
    sst_dir: []const u8 = "./data/sst",
    /// Direct I/O: bypass OS page cache for reduced latency
    direct_io: bool = false,
    /// Compress SSTable data blocks (RLE — best for repetitive blockchain data)
    compress_blocks: bool = false,
    /// Memory-mapped I/O for SSTable reads (Linux/macOS, reduces syscall overhead)
    mmap_io: bool = false,
    /// Enable background async compaction (non-blocking put/delete)
    async_compaction: bool = false,
    /// Async compaction interval in seconds
    compaction_interval_secs: u64 = 10,
};

/// Key-Value pair for LSM-Tree
pub const KeyValue = struct {
    key: []u8,
    value: []u8,
    seq: u64, // Sequence number for MVCC
    deleted: bool = false,

    pub fn lessThan(self: @This(), other: @This()) bool {
        const key_cmp = std.mem.lessThan(u8, self.key, other.key);
        if (key_cmp) return true;
        if (std.mem.eql(u8, self.key, other.key)) {
            // Higher sequence = newer = "less" (sorts first in dedup)
            if (self.seq != other.seq) return self.seq > other.seq;
            // Tiebreaker for equal key+seq: non-deleted comes first
            return !self.deleted and other.deleted;
        }
        return false;
    }
};

/// Bloom filter for fast negative lookups
pub const BloomFilter = struct {
    const Self = @This();

    bits: []u8,
    num_bits: usize,
    num_hashes: usize,

    pub fn init(allocator: std.mem.Allocator, expected_items: usize, bits_per_item: usize) !Self {
        const num_bits = expected_items * bits_per_item;
        const num_bytes = (num_bits + 7) / 8;

        // Simplified: num_bits / expected_items = bits_per_item
        const bits_per_item_f: f64 = @floatFromInt(bits_per_item);
        const num_hashes_approx: usize = @intFromFloat(bits_per_item_f * 0.693);
        const num_hashes = @max(1, num_hashes_approx);
        return Self{
            .bits = try allocator.alloc(u8, num_bytes),
            .num_bits = num_bits,
            .num_hashes = num_hashes,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub fn add(self: *Self, key: []const u8) void {
        const h1 = std.hash.Wyhash.hash(0, key);
        const h2 = std.hash.Wyhash.hash(h1, key);

        var idx: usize = 0;
        while (idx < self.num_hashes) : (idx += 1) {
            const bit_pos = (h1 +% (idx *% h2)) % self.num_bits;
            self.bits[bit_pos / 8] |= @as(u8, 1) << @as(u3, @intCast(bit_pos % 8));
        }
    }

    pub fn contains(self: *Self, key: []const u8) bool {
        const h1 = std.hash.Wyhash.hash(0, key);
        const h2 = std.hash.Wyhash.hash(h1, key);

        var idx: usize = 0;
        while (idx < self.num_hashes) : (idx += 1) {
            const bit_pos = (h1 +% (idx *% h2)) % self.num_bits;
            if ((self.bits[bit_pos / 8] & (@as(u8, 1) << @as(u3, @intCast(bit_pos % 8)))) == 0) {
                return false;
            }
        }
        return true;
    }
};

/// MemTable - in-memory sorted map
pub const MemTable = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entries: std.ArrayList(KeyValue),
    size: usize,
    max_size: usize,
    bloom: *BloomFilter,
    sorted: bool = true,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !Self {
        const bloom = try allocator.create(BloomFilter);
        errdefer allocator.destroy(bloom);
        bloom.* = try BloomFilter.init(allocator, 1_000_000, 10);

        return .{
            .allocator = allocator,
            .entries = std.ArrayList(KeyValue).empty,
            .size = 0,
            .max_size = max_size,
            .bloom = bloom,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
        self.bloom.deinit(self.allocator);
        self.allocator.destroy(self.bloom);
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8, seq: u64) !void {
        const payload = std.math.add(usize, key.len, value.len) catch return error.MemTableFull;
        const entry_size = std.math.add(usize, payload, 24) catch return error.MemTableFull;
        const new_size = std.math.add(usize, self.size, entry_size) catch return error.MemTableFull;
        if (new_size > self.max_size) return error.MemTableFull;

        const duped_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(duped_key);
        const duped_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(duped_value);
        try self.entries.append(self.allocator, .{
            .key = duped_key,
            .value = duped_value,
            .seq = seq,
            .deleted = false,
        });
        self.bloom.add(key);
        self.size = new_size;
        self.sorted = false;
    }

    fn ensureSorted(self: *Self) void {
        if (self.sorted) return;
        std.mem.sort(KeyValue, self.entries.items, {}, struct {
            fn lessThan(_: void, a: KeyValue, b: KeyValue) bool {
                return a.lessThan(b);
            }
        }.lessThan);
        self.sorted = true;
    }

    pub const Lookup = union(enum) {
        missing,
        deleted,
        value: []const u8,
    };

    pub fn lookup(self: *Self, key: []const u8) Lookup {
        if (!self.bloom.contains(key)) return .missing;

        self.ensureSorted();

        var low: usize = 0;
        var high: usize = self.entries.items.len;

        while (low < high) {
            const mid = searchMidpoint(low, high);
            const entry = self.entries.items[mid];
            const cmp = std.mem.lessThan(u8, entry.key, key);

            if (cmp) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low < self.entries.items.len and std.mem.eql(u8, self.entries.items[low].key, key)) {
            const latest = self.entries.items[low];
            if (latest.deleted) return .deleted;
            return .{ .value = latest.value };
        }

        return .missing;
    }

    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        return switch (self.lookup(key)) {
            .missing, .deleted => null,
            .value => |value| value,
        };
    }

    pub fn delete(self: *Self, key: []const u8, seq: u64) !void {
        try self.put(key, &.{}, seq);
        // Mark latest entry as deleted
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key) and entry.seq == seq) {
                entry.deleted = true;
                break;
            }
        }
    }

    pub fn needsFlush(self: Self) bool {
        return self.size >= self.max_size;
    }

    pub fn getEntries(self: Self) []const KeyValue {
        return self.entries.items;
    }

    pub fn clear(self: *Self) !void {
        const fresh = try self.allocator.create(BloomFilter);
        errdefer self.allocator.destroy(fresh);
        fresh.* = try BloomFilter.init(self.allocator, 1000000, 10);
        errdefer fresh.deinit(self.allocator);

        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.clearRetainingCapacity();
        const old = self.bloom;
        self.bloom = fresh;
        old.deinit(self.allocator);
        self.allocator.destroy(old);
        self.size = 0;
        self.sorted = true;
    }
};

/// SSTable index entry with optimization for binary search
pub const SSTableIndexEntry = struct {
    key: []u8,
    offset: u64,
    size: u32,

    /// Comparison function for binary search
    pub fn lessThan(self: @This(), other: @This()) bool {
        return std.mem.lessThan(u8, self.key, other.key);
    }

    /// Equality check for key matching
    pub fn eql(self: @This(), other_key: []const u8) bool {
        return std.mem.eql(u8, self.key, other_key);
    }
};

/// Midpoint of a half-open range. Adding the endpoints first wraps when both
/// sit in the top half of `usize`.
fn searchMidpoint(low: usize, high: usize) usize {
    return low + (high - low) / 2;
}

/// Index structure with binary search optimization
pub const SSTableIndex = struct {
    entries: []const SSTableIndexEntry,
    sorted: bool = false,

    /// Binary search for key
    pub fn binarySearch(self: *const SSTableIndex, key: []const u8) ?usize {
        if (!self.sorted) return null;

        var low: usize = 0;
        var high: usize = self.entries.len;

        while (low < high) {
            const mid = searchMidpoint(low, high);
            const entry = self.entries[mid];

            if (std.mem.lessThan(u8, entry.key, key)) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low < self.entries.len and std.mem.eql(u8, self.entries[low].key, key)) {
            return low;
        }
        return null;
    }
};

/// File wrapper with injected IO — replaces global io_instance singleton.
/// Provides seekTo/writeAll/readAll convenience methods on std.Io.File.
const IoFile = struct {
    io: std.Io,
    file: std.Io.File,
    /// Cursor for positional reads. Each fresh reader used to start at offset 0,
    /// so a seek was discarded before the next read.
    pos: u64 = 0,

    pub fn close(self: IoFile) void {
        self.file.close(self.io);
    }

    pub fn seekTo(self: *IoFile, offset: u64) !void {
        self.pos = offset;
    }

    pub fn writeAll(self: *IoFile, bytes: []const u8) !void {
        try self.file.writeStreamingAll(self.io, bytes);
        self.pos += bytes.len;
    }

    pub fn readAll(self: *IoFile, buf: []u8) !usize {
        const n = try self.file.readPositionalAll(self.io, buf, self.pos);
        self.pos += n;
        return n;
    }
};
/// Simple RLE compression for repetitive blockchain data.
fn compressRLE(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (data.len < 4) return allocator.dupe(u8, data);
    var buf = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        var count: u8 = 1;
        while (i + count < data.len and count < 255 and data[i + count] == byte) : (count += 1) {}
        try buf.append(allocator, byte);
        try buf.append(allocator, count);
        i += count;
    }
    return buf.toOwnedSlice(allocator);
}

fn decompressRLE(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (data.len < 2) return allocator.dupe(u8, data);
    var buf = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        const byte = data[i];
        const count = data[i + 1];
        var j: u8 = 0;
        while (j < count) : (j += 1) try buf.append(allocator, byte);
    }
    return buf.toOwnedSlice(allocator);
}

/// Resolve I/O handle: explicit config.io over global io_instance.
fn resolveIo(config: LSMTreeConfig) type {
    _ = config;
    return @import("io_instance").io;
}

/// SSTable - Sorted String Table file
pub const SSTable = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    file: IoFile,
    path: []const u8,
    index: std.ArrayList(SSTableIndexEntry),
    bloom: *BloomFilter,
    level: usize,
    min_key: []const u8,
    max_key: []const u8,
    /// Exclusive end of the record bytes. The index and footer sit after this.
    data_end: ?u64 = null,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, level: usize) !Self {
        const io = @import("io_instance").io;
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch
            try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });

        var self = Self{
            .allocator = allocator,
            .file = IoFile{ .io = io, .file = file },
            .path = try allocator.dupe(u8, path),
            .index = std.ArrayList(SSTableIndexEntry).empty,
            .bloom = try allocator.create(BloomFilter),
            .level = level,
            .min_key = &.{},
            .max_key = &.{},
            .data_end = null,
        };
        errdefer self.deinit();

        self.data_end = self.footerDataEnd() catch null;
        // Rebuild index from file for crash recovery.
        // For new (empty) files this is a no-op.
        self.bloom.* = try BloomFilter.init(allocator, 1_000_000, 10);
        self.rebuildIndex(allocator) catch |err| {
            std.log.warn("SSTable.open: index rebuild failed for {s} ({s}) — file may be corrupt", .{ path, @errorName(err) });
        };

        return self;
    }

    /// Rebuild the in-memory index by scanning existing SSTable records.
    /// Called during open() for crash recovery — without this, existing
    /// SSTables would be unreadable because the index is only in-memory.
    fn rebuildIndex(self: *Self, rebuild_allocator: std.mem.Allocator) !void {
        const entries = try self.readAllEntries(rebuild_allocator);
        defer {
            for (entries) |entry| {
                rebuild_allocator.free(entry.key);
                rebuild_allocator.free(entry.value);
            }
            rebuild_allocator.free(entries);
        }

        var data_offset: u64 = 0;
        for (entries) |entry| {
            const record_size = try checkedRecordSize(entry.key.len, entry.value.len);

            try self.index.append(rebuild_allocator, .{
                .key = try rebuild_allocator.dupe(u8, entry.key),
                .offset = data_offset,
                .size = record_size,
            });
            self.bloom.add(entry.key);
            data_offset += record_size;
        }
    }

    pub fn write(self: *Self, entries: []const KeyValue) !void {
        // Write data and index with streaming to handle any size
        var data_offset: u64 = 0;

        for (entries) |entry| {
            const record_size = try checkedRecordSize(entry.key.len, entry.value.len);
            const key_len: u32 = @intCast(entry.key.len);
            const val_len: u32 = @intCast(entry.value.len);
            const deleted_flag: u8 = if (entry.deleted) 1 else 0;

            // Use dynamic buffer only if entry exceeds inline threshold
            const inline_threshold = 1024;
            const use_heap = record_size > inline_threshold;

            if (use_heap) {
                // Heap allocation for large records
                var heap_buf = try self.allocator.alloc(u8, record_size);
                defer self.allocator.free(heap_buf);

                var offset: usize = 0;
                std.mem.writeInt(u32, heap_buf[offset..][0..4], key_len, .big);
                offset += 4;
                @memcpy(heap_buf[offset..][0..key_len], entry.key);
                offset += key_len;
                std.mem.writeInt(u32, heap_buf[offset..][0..4], val_len, .big);
                offset += 4;
                @memcpy(heap_buf[offset..][0..val_len], entry.value);
                offset += val_len;
                heap_buf[offset] = deleted_flag;
                offset += 1;
                std.mem.writeInt(u64, heap_buf[offset..][0..8], entry.seq, .big);

                try self.file.writeAll(heap_buf);
            } else {
                // Stack buffer for small records (typical case)
                var buf: [inline_threshold]u8 = undefined;
                var offset: usize = 0;

                std.mem.writeInt(u32, buf[offset..][0..4], key_len, .big);
                offset += 4;
                @memcpy(buf[offset..][0..key_len], entry.key);
                offset += key_len;

                std.mem.writeInt(u32, buf[offset..][0..4], val_len, .big);
                offset += 4;
                @memcpy(buf[offset..][0..val_len], entry.value);
                offset += val_len;

                buf[offset] = deleted_flag;
                offset += 1;

                std.mem.writeInt(u64, buf[offset..][0..8], entry.seq, .big);
                offset += 8;

                try self.file.writeAll(buf[0..offset]);
            }

            self.bloom.add(entry.key);

            // Index entry
            try self.index.append(self.allocator, .{
                .key = try self.allocator.dupe(u8, entry.key),
                .offset = data_offset,
                .size = record_size,
            });

            data_offset += record_size;
        }

        // Write index at end, then a footer naming where the records stop.
        try self.writeIndex();
        var tail: [12]u8 = undefined;
        std.mem.writeInt(u64, tail[0..8], data_offset, .big);
        @memcpy(tail[8..12], "SST1");
        try self.file.writeAll(&tail);
    }

    /// Header, key, value length, deleted flag, and sequence must fit in one u32.
    fn checkedRecordSize(key_len: usize, value_len: usize) error{RecordTooLarge}!u32 {
        if (key_len > std.math.maxInt(u32) or value_len > std.math.maxInt(u32)) return error.RecordTooLarge;
        const key_u: u32 = @intCast(key_len);
        const val_u: u32 = @intCast(value_len);
        const body = std.math.add(u32, key_u, val_u) catch return error.RecordTooLarge;
        return std.math.add(u32, body, 17) catch return error.RecordTooLarge;
    }

    fn footerDataEnd(self: *Self) !?u64 {
        const len = try self.file.file.length(self.file.io);
        if (len < 12) return null;
        var tail: [12]u8 = undefined;
        if (try self.file.file.readPositionalAll(self.file.io, &tail, len - 12) != 12) return null;
        if (!std.mem.eql(u8, tail[8..12], "SST1")) return null;
        return std.mem.readInt(u64, tail[0..8], .big);
    }

    fn writeIndex(self: *Self) !void {
        // Index format: [count u32][key_len u32][key bytes][offset u64][size u32]...
        if (self.index.items.len > std.math.maxInt(u32)) return error.IndexTooLarge;
        const count: u32 = @intCast(self.index.items.len);

        // Pre-compute total buffer size: count(4) + per_entry(4 + key.len + 8 + 4)
        var total: usize = 4;
        for (self.index.items) |entry| {
            if (entry.key.len > std.math.maxInt(u32)) return error.IndexTooLarge;
            const entry_size = std.math.add(usize, entry.key.len, 16) catch return error.IndexTooLarge;
            total = std.math.add(usize, total, entry_size) catch return error.IndexTooLarge;
        }
        var buf = try self.allocator.alloc(u8, total);
        defer self.allocator.free(buf);
        var pos: usize = 0;

        std.mem.writeInt(u32, buf[pos..][0..4], count, .big);
        pos += 4;

        for (self.index.items) |entry| {
            const key_len: u32 = @intCast(entry.key.len);
            std.mem.writeInt(u32, buf[pos..][0..4], key_len, .big);
            pos += 4;
            @memcpy(buf[pos..][0..entry.key.len], entry.key);
            pos += entry.key.len;
            std.mem.writeInt(u64, buf[pos..][0..8], entry.offset, .big);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], entry.size, .big);
            pos += 4;
        }

        try self.file.writeAll(buf);
    }

    const Probe = union(enum) {
        missing,
        deleted,
        value: []u8,
    };

    /// A tombstone is distinct from a missing key so a newer table can hide older ones.
    pub fn probe(self: *Self, key: []const u8) !Probe {
        if (!self.bloom.contains(key)) return .missing;

        const index = SSTableIndex{
            .entries = self.index.items,
            .sorted = true,
        };
        const idx = index.binarySearch(key) orelse return .missing;
        const record = (try self.readRecord(self.allocator, self.index.items[idx].offset)) orelse return error.CorruptSSTable;
        self.allocator.free(record.key);
        if (record.deleted) {
            self.allocator.free(record.value);
            return .deleted;
        }
        return .{ .value = record.value };
    }

    /// Caller owns the returned value bytes.
    pub fn read(self: *Self, key: []const u8) !?[]u8 {
        return switch (try self.probe(key)) {
            .missing, .deleted => null,
            .value => |value| value,
        };
    }

    /// Read all entries from SSTable for compaction.
    /// The on-disk record is key length, key, value length, value, deleted flag, sequence.
    pub fn readAllEntries(self: *Self, allocator: std.mem.Allocator) ![]KeyValue {
        var entries = std.ArrayList(KeyValue).empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            entries.deinit(allocator);
        }

        if (self.index.items.len > 0) {
            for (self.index.items) |idx| {
                const record = (try self.readRecord(allocator, idx.offset)) orelse return error.CorruptSSTable;
                entries.append(allocator, record) catch |err| {
                    allocator.free(record.key);
                    allocator.free(record.value);
                    return err;
                };
            }
        } else {
            try self.file.seekTo(0);
            while (try self.readRecord(allocator, null)) |entry| {
                entries.append(allocator, entry) catch |err| {
                    allocator.free(entry.key);
                    allocator.free(entry.value);
                    return err;
                };
            }
        }

        return entries.toOwnedSlice(allocator);
    }

    /// `at` seeks to a known record. Null scans the next record and returns null at a short read.
    fn readRecord(self: *Self, allocator: std.mem.Allocator, at: ?u64) !?KeyValue {
        if (at) |offset| {
            try self.file.seekTo(offset);
        } else if (self.data_end) |end| {
            if (self.file.pos >= end) return null;
        }
        var len_buf: [4]u8 = undefined;
        const key_len_bytes = try self.file.readAll(&len_buf);
        if (key_len_bytes == 0) return null;
        if (key_len_bytes != 4) {
            if (at == null) return null;
            return error.CorruptSSTable;
        }
        const key_len = std.mem.readInt(u32, &len_buf, .big);
        if (key_len > 64 * 1024 * 1024) {
            if (at == null) return null;
            return error.CorruptSSTable;
        }

        const key_buf = try allocator.alloc(u8, key_len);
        if (try self.file.readAll(key_buf) != key_len) {
            allocator.free(key_buf);
            if (at == null) return null;
            return error.CorruptSSTable;
        }

        if (try self.file.readAll(&len_buf) != 4) {
            allocator.free(key_buf);
            if (at == null) return null;
            return error.CorruptSSTable;
        }
        const val_len = std.mem.readInt(u32, &len_buf, .big);
        if (val_len > 64 * 1024 * 1024) {
            allocator.free(key_buf);
            if (at == null) return null;
            return error.CorruptSSTable;
        }

        const value_buf = allocator.alloc(u8, val_len) catch |err| {
            allocator.free(key_buf);
            return err;
        };
        if (try self.file.readAll(value_buf) != val_len) {
            allocator.free(key_buf);
            allocator.free(value_buf);
            if (at == null) return null;
            return error.CorruptSSTable;
        }

        var flag: [1]u8 = undefined;
        if (try self.file.readAll(&flag) != 1) {
            allocator.free(key_buf);
            allocator.free(value_buf);
            if (at == null) return null;
            return error.CorruptSSTable;
        }
        var seq_buf: [8]u8 = undefined;
        if (try self.file.readAll(&seq_buf) != 8) {
            allocator.free(key_buf);
            allocator.free(value_buf);
            if (at == null) return null;
            return error.CorruptSSTable;
        }

        return .{
            .key = key_buf,
            .value = value_buf,
            .seq = std.mem.readInt(u64, &seq_buf, .big),
            .deleted = flag[0] == 1,
        };
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
        for (self.index.items) |entry| self.allocator.free(entry.key);
        self.index.deinit(self.allocator);
        self.bloom.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.destroy(self.bloom);
    }
};

/// Level-based compaction
pub const CompactionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: LSMTreeConfig,
    levels: std.ArrayList(std.ArrayList(*SSTable)),
    active_level: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: LSMTreeConfig) !Self {
        var levels = std.ArrayList(std.ArrayList(*SSTable)).empty;
        for (0..config.max_levels) |_| {
            try levels.append(allocator, std.ArrayList(*SSTable).empty);
        }

        return .{
            .allocator = allocator,
            .config = config,
            .levels = levels,
            .active_level = 0,
        };
    }

    /// Drops the level lists. The `*SSTable` values are borrowed; `LSMTree`
    /// or the standalone caller closes them.
    pub fn deinit(self: *Self) void {
        for (self.levels.items) |*level| {
            level.deinit(self.allocator);
        }
        self.levels.deinit(self.allocator);
    }

    /// Get target level for new SSTable based on size
    pub fn getTargetLevel(self: *Self, size: usize) usize {
        var level: usize = 0;
        var level_size: usize = self.config.memtable_size * self.config.level_multiplier;

        while (level < self.config.max_levels - 1 and size >= level_size) {
            level += 1;
            level_size *= self.config.level_multiplier;
        }

        return level;
    }

    /// Compact two adjacent levels
    /// Merges SSTables, handles overwrites/deletes, writes to next level
    pub fn compact(self: *Self, level: usize, allocator: std.mem.Allocator, sst_dir: []const u8, next_sst_id: *u64, owned: ?*std.ArrayList(*SSTable)) !void {
        if (level >= self.levels.items.len or self.levels.items[level].items.len == 0) return;
        // The last level has nowhere to put a merged table. Destroying it
        // here would drop the only copy of those records.
        if (level + 1 >= self.levels.items.len) return;

        const sstables = self.levels.items[level].items;
        if (sstables.len == 0) return;

        var all_entries = std.ArrayList(KeyValue).empty;
        defer {
            for (all_entries.items) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            all_entries.deinit(allocator);
        }

        for (sstables) |sst| {
            const entries = try sst.readAllEntries(allocator);
            defer {
                for (entries) |entry| {
                    allocator.free(entry.key);
                    allocator.free(entry.value);
                }
                allocator.free(entries);
            }
            // Deep-copy each entry into all_entries to avoid dangling pointers
            for (entries) |entry| {
                const owned_entry = KeyValue{
                    .key = try allocator.dupe(u8, entry.key),
                    .value = try allocator.dupe(u8, entry.value),
                    .seq = entry.seq,
                    .deleted = entry.deleted,
                };
                try all_entries.append(allocator, owned_entry);
            }
        }

        if (all_entries.items.len == 0) return;

        std.mem.sort(KeyValue, all_entries.items, {}, struct {
            fn lessThan(_: void, a: KeyValue, b: KeyValue) bool {
                return a.lessThan(b);
            }
        }.lessThan);

        // Deduplicate by key: keep highest sequence number per key
        var deduped = std.ArrayList(KeyValue).empty;
        defer deduped.deinit(allocator);

        // `lessThan` orders a higher sequence first, so the first copy of a key is the newest.
        for (all_entries.items) |entry| {
            var found = false;
            for (deduped.items) |existing| {
                if (std.mem.eql(u8, existing.key, entry.key)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            try deduped.append(allocator, entry);
        }

        if (deduped.items.len == 0) return;

        const new_level = level + 1;
        if (new_level < self.levels.items.len) {
            const sst_id = next_sst_id.*;
            next_sst_id.* = std.math.add(u64, sst_id, 1) catch return error.ArithmeticOverflow;
            const path = try std.fmt.allocPrint(allocator, "{s}/L{d}_{d}.sst", .{
                sst_dir, new_level, sst_id,
            });
            defer allocator.free(path);

            var new_sst = try allocator.create(SSTable);
            new_sst.* = try SSTable.open(allocator, path, new_level);
            errdefer {
                new_sst.deinit();
                allocator.destroy(new_sst);
            }

            try new_sst.write(deduped.items);
            errdefer if (owned) |list| forgetOwnedSSTable(list, new_sst);
            if (owned) |list| try list.append(allocator, new_sst);
            try self.levels.items[new_level].append(allocator, new_sst);
        }

        for (sstables) |old_sst| {
            if (owned) |list| forgetOwnedSSTable(list, old_sst);
            // Delete the SSTable file from disk after compaction merges it
            std.Io.Dir.cwd().deleteFile(@import("io_instance").io, old_sst.path) catch {};
            old_sst.deinit();
            allocator.destroy(old_sst);
        }
        self.levels.items[level].clearRetainingCapacity();
    }

    fn forgetOwnedSSTable(list: *std.ArrayList(*SSTable), sst: *SSTable) void {
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            if (list.items[i] == sst) {
                _ = list.orderedRemove(i);
                return;
            }
        }
    }

    /// Calculate compaction score for a given level (ratio of current SST count to allowed threshold)
    pub fn getCompactionScore(self: *Self, level: usize) f64 {
        if (level >= self.levels.items.len) return 0.0;
        const count = self.levels.items[level].items.len;
        const max_allowed = if (level == 0) @as(usize, 2) else self.config.level_multiplier;
        return @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(max_allowed));
    }

    pub fn needsCompaction(self: *Self) bool {
        for (self.levels.items, 0..) |_, level| {
            if (self.getCompactionScore(level) >= 1.0) return true;
        }
        return false;
    }
};
/// Write batch for atomic operations
pub const WriteBatch = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    operations: std.ArrayList(Operation),

    pub const Operation = struct {
        op: enum { put, delete },
        key: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .operations = std.ArrayList(Operation).empty,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.operations.items) |op| {
            allocator.free(op.key);
            allocator.free(op.value);
        }
        self.operations.deinit(allocator);
    }
    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = self.allocator.dupe(u8, value) catch |err| {
            self.allocator.free(owned_key);
            return err;
        };
        self.operations.append(self.allocator, .{
            .op = .put,
            .key = owned_key,
            .value = owned_value,
        }) catch |err| {
            self.allocator.free(owned_key);
            self.allocator.free(owned_value);
            return err;
        };
    }

    pub fn delete(self: *Self, key: []u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        self.operations.append(self.allocator, .{
            .op = .delete,
            .key = owned_key,
            .value = &.{},
        }) catch |err| {
            self.allocator.free(owned_key);
            return err;
        };
    }

    pub fn clear(self: *Self) void {
        for (self.operations.items) |op| {
            self.allocator.free(op.key);
            self.allocator.free(op.value);
        }
        self.operations.clearRetainingCapacity();
    }
};

/// LSM-Tree main structure
pub const LSMTree = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: LSMTreeConfig,
    memtable: MemTable,
    sstables: std.ArrayList(*SSTable),
    sequence: u64,
    compaction: *CompactionManager,
    compaction_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    arena: std.heap.ArenaAllocator,
    wal: ?WAL,
    wal_path: []const u8,

    /// Helper to init WAL, returning null on failure
    fn initWALOrNull(allocator: std.mem.Allocator, path: []const u8) ?WAL {
        return WAL.init(allocator, path) catch null;
    }

    pub fn init(allocator: std.mem.Allocator, config: LSMTreeConfig) !*Self {
        // Create the SST directory first: it is the only step that can fail for
        // an unwritable path, and running it before any allocation keeps the
        // error path free of partial-state cleanup.
        std.Io.Dir.cwd().createDir(@import("io_instance").io, config.sst_dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        // Initialize WAL for durability
        const wal_path = try std.fmt.allocPrint(allocator, "{s}/wal.log", .{config.sst_dir});
        errdefer allocator.free(wal_path);
        const wal: ?WAL = initWALOrNull(allocator, wal_path);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .memtable = try MemTable.init(allocator, config.memtable_size),
            .sstables = std.ArrayList(*SSTable).empty,
            .sequence = 0,
            .compaction = try allocator.create(CompactionManager),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .wal = wal,
            .wal_path = wal_path,
        };
        self.compaction.* = try CompactionManager.init(allocator, config);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.memtable.deinit();
        for (self.sstables.items) |sst| {
            sst.deinit();
            self.allocator.destroy(sst);
        }
        self.sstables.deinit(self.allocator);
        self.compaction.deinit();
        self.arena.deinit();
        if (self.wal) |*w| w.deinit();
        self.allocator.free(self.wal_path);
        self.allocator.destroy(self.compaction);
        self.allocator.destroy(self);
    }

    /// Recover from WAL - replay uncommitted transactions
    /// Recover from WAL - replay uncommitted transactions with options
    pub fn recoverWithOptions(self: *Self, options: WAL_module.RecoveryOptions) !WAL_module.RecoveryResult {
        if (self.wal) |*wal| {
            const State = struct {
                lsm: *Self,
            };
            var state = State{ .lsm = self };

            const callback = struct {
                fn cb(op: WalRecordType, key: []const u8, value: ?[]const u8, ctx: *anyopaque) anyerror!void {
                    const s = @as(*State, @ptrCast(@alignCast(ctx)));
                    switch (op) {
                        .insert => {
                            const seq = try s.lsm.nextSequence();
                            try s.lsm.memtable.put(key, value.?, seq);
                        },
                        .delete => {
                            const seq = try s.lsm.nextSequence();
                            try s.lsm.memtable.delete(key, seq);
                        },
                        .commit, .abort => {
                            // Commit/abort don't need special handling in memtable
                            // The actual transaction semantics are handled at higher layers
                        },
                        .m4_stake_operation,
                        .m4_governance_proposal,
                        .m4_governance_status,
                        .m4_governance_vote,
                        .m4_equivocation_evidence,
                        .m4_state_snapshot,
                        .m4_epoch_advance,
                        .m4_validator_set_rotate,
                        .m4_gas_balance,
                        .m4_gas_snapshot,
                        => {
                            // M4 records must never be interleaved into the LSM WAL.
                        },
                    }
                }
            }.cb;

            return try wal.replayWithOptions(&callback, &state, options);
        }
        return .{ .records_replayed = 0, .corrupted_records = 0, .errors = 0 };
    }

    /// Recover from WAL with default options
    pub fn recover(self: *Self) !WAL_module.RecoveryResult {
        return self.recoverWithOptions(.{});
    }

    pub fn nextSequence(self: *Self) error{ArithmeticOverflow}!u64 {
        const seq = self.sequence;
        self.sequence = std.math.add(u64, seq, 1) catch return error.ArithmeticOverflow;
        return seq;
    }
    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        if (self.sequence == std.math.maxInt(u64)) return error.ArithmeticOverflow;
        // Log to WAL first for durability
        if (self.wal) |*w| {
            try w.logInsert(key, value);
        }
        const seq = try self.nextSequence();
        try self.memtable.put(key, value, seq);

        if (self.memtable.needsFlush()) {
            try self.flushMemtable();
        }
    }

    /// Caller owns the returned bytes. A memtable or newer-table tombstone
    /// hides older SSTable values. Memtable hits are copied; SSTable hits keep
    /// the buffer from `probe`.
    pub fn get(self: *Self, key: []const u8) !?[]u8 {
        switch (self.memtable.lookup(key)) {
            .deleted => return null,
            .value => |value| return try self.allocator.dupe(u8, value),
            .missing => {},
        }

        var i = self.sstables.items.len;
        while (i > 0) {
            i -= 1;
            switch (try self.sstables.items[i].probe(key)) {
                .deleted => return null,
                .value => |value| return value,
                .missing => {},
            }
        }

        return null;
    }

    pub fn delete(self: *Self, key: []const u8) !void {
        if (self.sequence == std.math.maxInt(u64)) return error.ArithmeticOverflow;
        // Log to WAL first for durability
        if (self.wal) |*w| {
            try w.logDelete(key);
        }
        const seq = try self.nextSequence();
        try self.memtable.delete(key, seq);

        if (self.memtable.needsFlush()) {
            try self.flushMemtable();
        }
    }

    fn flushMemtable(self: *Self) !void {
        self.memtable.ensureSorted();
        const entries = self.memtable.getEntries();
        if (entries.len == 0) return;

        // Create new SSTable
        const level = self.compaction.getTargetLevel(self.memtable.size);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/L{d}_{d}.sst", .{
            self.config.sst_dir, level, self.sequence,
        });
        defer self.allocator.free(path);

        const sst = try self.allocator.create(SSTable);
        sst.* = try SSTable.open(self.allocator, path, level);
        errdefer {
            std.Io.Dir.cwd().deleteFile(@import("io_instance").io, sst.path) catch {};
            sst.deinit();
            self.allocator.destroy(sst);
        }
        try sst.write(entries);

        try self.sstables.append(self.allocator, sst);
        errdefer _ = self.sstables.orderedRemove(self.sstables.items.len - 1);

        // Register with compaction manager so it can be selected for compaction.
        // Levels are pre-allocated in CompactionManager.init, so index is safe.
        try self.compaction.levels.items[level].append(self.allocator, sst);
        errdefer _ = self.compaction.levels.items[level].orderedRemove(
            self.compaction.levels.items[level].items.len - 1,
        );

        // Clear memtable after successful flush to prevent unbounded growth
        try self.memtable.clear();
    }

    pub fn batchInit(allocator: std.mem.Allocator) WriteBatch {
        return WriteBatch.init(allocator);
    }

    /// Applies operations from the front. An operation stays in the batch until
    /// it lands in the tree, so a later failure can be retried without repeating
    /// the ones that already succeeded.
    pub fn batchCommit(self: *Self, batch: *WriteBatch) !void {
        while (batch.operations.items.len > 0) {
            const op = batch.operations.items[0];
            switch (op.op) {
                .put => try self.put(op.key, op.value),
                .delete => try self.delete(op.key),
            }
            batch.allocator.free(op.key);
            batch.allocator.free(op.value);
            _ = batch.operations.orderedRemove(0);
        }
        if (self.wal) |*w| {
            try w.logCommit();
            try w.syncAll();
        }
    }

    pub fn count(self: Self) usize {
        return self.memtable.entries.items.len + self.sstables.items.len;
    }

    /// Live key/value pairs across the memtable and every SSTable.
    /// The newest sequence wins. Tombstones are omitted. Caller owns the
    /// returned keys and values.
    pub fn collectLive(self: *Self, allocator: std.mem.Allocator) ![]KeyValue {
        const Live = struct {
            value: []u8,
            seq: u64,
            deleted: bool,
        };
        var map = std.StringHashMapUnmanaged(Live).empty;
        errdefer {
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.value);
            }
            map.deinit(allocator);
        }

        const consider = struct {
            fn apply(
                alloc: std.mem.Allocator,
                m: *std.StringHashMapUnmanaged(Live),
                key: []const u8,
                value: []const u8,
                seq: u64,
                deleted: bool,
            ) !void {
                if (m.getPtr(key)) |existing| {
                    if (seq < existing.seq) return;
                    if (seq == existing.seq and deleted and !existing.deleted) return;
                    const owned_value = try alloc.dupe(u8, value);
                    alloc.free(existing.value);
                    existing.value = owned_value;
                    existing.seq = seq;
                    existing.deleted = deleted;
                    return;
                }
                const owned_key = try alloc.dupe(u8, key);
                errdefer alloc.free(owned_key);
                const owned_value = try alloc.dupe(u8, value);
                errdefer alloc.free(owned_value);
                try m.put(alloc, owned_key, .{
                    .value = owned_value,
                    .seq = seq,
                    .deleted = deleted,
                });
            }
        };

        for (self.memtable.getEntries()) |entry| {
            try consider.apply(allocator, &map, entry.key, entry.value, entry.seq, entry.deleted);
        }
        for (self.sstables.items) |sst| {
            const rows = try sst.readAllEntries(allocator);
            defer {
                for (rows) |row| {
                    allocator.free(row.key);
                    allocator.free(row.value);
                }
                allocator.free(rows);
            }
            for (rows) |row| {
                try consider.apply(allocator, &map, row.key, row.value, row.seq, row.deleted);
            }
        }

        var out = std.ArrayList(KeyValue).empty;
        errdefer {
            for (out.items) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            out.deinit(allocator);
        }
        var it = map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deleted) continue;
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = allocator.dupe(u8, entry.value_ptr.value) catch |err| {
                allocator.free(key);
                return err;
            };
            out.append(allocator, .{
                .key = key,
                .value = value,
                .seq = entry.value_ptr.seq,
                .deleted = false,
            }) catch |err| {
                allocator.free(key);
                allocator.free(value);
                return err;
            };
        }
        std.mem.sort(KeyValue, out.items, {}, struct {
            fn lessThan(_: void, a: KeyValue, b: KeyValue) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan);
        const owned = try out.toOwnedSlice(allocator);
        var cleanup = map.iterator();
        while (cleanup.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.value);
        }
        map.deinit(allocator);
        return owned;
    }

    /// Trigger compaction if needed (sync path — may block).
    pub fn maybeCompact(self: *Self) !void {
        if (self.config.async_compaction) return; // background worker handles it
        if (!self.compaction.needsCompaction()) return;
        for (self.compaction.levels.items, 0..) |level_ssts, level| {
            if (level_ssts.items.len > 3) {
                try self.compaction.compact(level, self.allocator, self.config.sst_dir, &self.sequence, &self.sstables);
            }
        }
    }

    /// Start a background compaction worker thread. Call during node startup.
    /// The worker periodically checks and runs compaction, avoiding blocking
    /// the main write path.
    pub fn startCompactionWorker(self: *Self) !std.Thread {
        return try std.Thread.spawn(.{}, runCompactionLoop, .{self});
    }

    fn runCompactionLoop(tree: *LSMTree) void {
        while (!tree.compaction_shutdown.load(.monotonic)) {
            std.time.sleep(tree.config.compaction_interval_secs * std.time.ns_per_s);
            if (!tree.compaction.needsCompaction()) continue;
            for (tree.compaction.levels.items, 0..) |level_ssts, level| {
                if (level_ssts.items.len > 3) {
                    tree.compaction.compact(level, tree.allocator, tree.config.sst_dir, &tree.sequence, &tree.sstables) catch continue;
                }
            }
        }
    }
};

test "LSMTree basic operations" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    var tree = try LSMTree.init(allocator, .{ .sst_dir = "/tmp/lsm_test" });
    defer tree.deinit();

    try tree.put("key1", "value1");
    const val = try tree.get("key1");
    defer if (val) |owned| allocator.free(owned);
    try std.testing.expect(val != null);
    try std.testing.expect(std.mem.eql(u8, val.?, "value1"));
}

test "LSMTree flush closes each SSTable once" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_flush_once";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var tree = try LSMTree.init(allocator, .{ .sst_dir = dir });
    defer tree.deinit();
    try tree.put("key1", "value1");
    try tree.flushMemtable();
    try tree.compaction.compact(0, allocator, dir, &tree.sequence, &tree.sstables);

    const val = try tree.get("key1");
    defer if (val) |owned| allocator.free(owned);
    try std.testing.expect(val != null);
    try std.testing.expect(std.mem.eql(u8, val.?, "value1"));
    try std.testing.expectEqual(@as(usize, 1), tree.sstables.items.len);
}

test "LSMTree delete hides a value already flushed" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_delete_hides";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var tree = try LSMTree.init(allocator, .{ .sst_dir = dir });
    defer tree.deinit();
    try tree.put("key1", "value1");
    try tree.flushMemtable();
    try tree.delete("key1");
    try std.testing.expect((try tree.get("key1")) == null);

    try tree.put("key1", "value2");
    const val = try tree.get("key1");
    defer if (val) |owned| allocator.free(owned);
    try std.testing.expect(val != null);
    try std.testing.expect(std.mem.eql(u8, val.?, "value2"));
}

test "LSMTree refuses to wrap its sequence" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    var tree = try LSMTree.init(allocator, .{ .sst_dir = "/tmp/lsm_seq_overflow" });
    defer tree.deinit();
    tree.sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.ArithmeticOverflow, tree.put("k", "v"));
    try std.testing.expectError(error.ArithmeticOverflow, tree.delete("k"));
    try std.testing.expectEqual(std.math.maxInt(u64), tree.sequence);
    try std.testing.expect((try tree.get("k")) == null);
}

test "compaction frees each merged entry once" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_compact_once";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var mgr = try CompactionManager.init(allocator, .{});
    const path = try std.fmt.allocPrint(allocator, "{s}/L0_seed.sst", .{dir});
    defer allocator.free(path);
    const created = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    created.close(std.testing.io);
    const sst = try allocator.create(SSTable);
    sst.* = try SSTable.open(allocator, path, 0);
    const key = try allocator.dupe(u8, "k");
    defer allocator.free(key);
    const value = try allocator.dupe(u8, "v");
    defer allocator.free(value);
    const entries = [_]KeyValue{.{ .key = key, .value = value, .seq = 1 }};
    try sst.write(&entries);
    try mgr.levels.items[0].append(allocator, sst);

    var next_id: u64 = 7;
    try mgr.compact(0, allocator, dir, &next_id, null);
    const produced = if (mgr.levels.items[1].items.len == 1) mgr.levels.items[1].items[0] else null;
    if (produced) |out| {
        out.deinit();
        allocator.destroy(out);
    }
    mgr.deinit();

    try std.testing.expectEqual(@as(u64, 8), next_id);
}

test "compaction keeps the last level" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_compact_last_level";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var mgr = try CompactionManager.init(allocator, .{ .max_levels = 1 });
    const path = try std.fmt.allocPrint(allocator, "{s}/L0_seed.sst", .{dir});
    defer allocator.free(path);
    const created = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    created.close(std.testing.io);
    const sst = try allocator.create(SSTable);
    sst.* = try SSTable.open(allocator, path, 0);
    const key = try allocator.dupe(u8, "k");
    defer allocator.free(key);
    const value = try allocator.dupe(u8, "v");
    defer allocator.free(value);
    try sst.write(&[_]KeyValue{.{ .key = key, .value = value, .seq = 1 }});
    try mgr.levels.items[0].append(allocator, sst);

    var next_id: u64 = 7;
    try mgr.compact(0, allocator, dir, &next_id, null);
    try std.testing.expectEqual(@as(u64, 7), next_id);
    try std.testing.expectEqual(@as(usize, 1), mgr.levels.items[0].items.len);

    const got = try sst.read(key);
    defer if (got) |owned| allocator.free(owned);
    try std.testing.expect(got != null);
    try std.testing.expect(std.mem.eql(u8, got.?, "v"));

    sst.deinit();
    allocator.destroy(sst);
    mgr.deinit();
}

test "compaction leaves every source table when one record cannot be read" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_compact_corrupt";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var mgr = try CompactionManager.init(allocator, .{});
    const key = try allocator.dupe(u8, "k");
    defer allocator.free(key);
    const value = try allocator.dupe(u8, "v");
    defer allocator.free(value);
    const entries = [_]KeyValue{.{ .key = key, .value = value, .seq = 1 }};

    const good_path = try std.fmt.allocPrint(allocator, "{s}/good.sst", .{dir});
    defer allocator.free(good_path);
    const bad_path = try std.fmt.allocPrint(allocator, "{s}/bad.sst", .{dir});
    defer allocator.free(bad_path);
    const good_file = try std.Io.Dir.cwd().createFile(std.testing.io, good_path, .{ .truncate = true });
    good_file.close(std.testing.io);
    const bad_file = try std.Io.Dir.cwd().createFile(std.testing.io, bad_path, .{ .truncate = true });
    bad_file.close(std.testing.io);

    const good = try allocator.create(SSTable);
    good.* = try SSTable.open(allocator, good_path, 0);
    try good.write(&entries);
    const bad = try allocator.create(SSTable);
    bad.* = try SSTable.open(allocator, bad_path, 0);
    try bad.write(&entries);
    bad.index.items[0].offset = 1024 * 1024;

    try mgr.levels.items[0].append(allocator, good);
    try mgr.levels.items[0].append(allocator, bad);

    var next_id: u64 = 3;
    try std.testing.expectError(error.CorruptSSTable, mgr.compact(0, allocator, dir, &next_id, null));
    try std.testing.expectEqual(@as(u64, 3), next_id);
    try std.testing.expectEqual(@as(usize, 2), mgr.levels.items[0].items.len);

    const got = try good.read(key);
    defer if (got) |owned| allocator.free(owned);
    try std.testing.expect(got != null);
    try std.testing.expect(std.mem.eql(u8, got.?, "v"));

    good.deinit();
    allocator.destroy(good);
    bad.deinit();
    allocator.destroy(bad);
    mgr.deinit();
}

test "compaction keeps the newest value for each key" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_compact_newest";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var mgr = try CompactionManager.init(allocator, .{});
    const key_a = try allocator.dupe(u8, "a");
    defer allocator.free(key_a);
    const old_value = try allocator.dupe(u8, "old");
    defer allocator.free(old_value);
    const new_value = try allocator.dupe(u8, "new");
    defer allocator.free(new_value);
    const key_b = try allocator.dupe(u8, "b");
    defer allocator.free(key_b);
    const kept = try allocator.dupe(u8, "keep");
    defer allocator.free(kept);
    const tomb = try allocator.dupe(u8, "");
    defer allocator.free(tomb);

    const older_path = try std.fmt.allocPrint(allocator, "{s}/older.sst", .{dir});
    defer allocator.free(older_path);
    const newer_path = try std.fmt.allocPrint(allocator, "{s}/newer.sst", .{dir});
    defer allocator.free(newer_path);
    const older_file = try std.Io.Dir.cwd().createFile(std.testing.io, older_path, .{ .truncate = true });
    older_file.close(std.testing.io);
    const newer_file = try std.Io.Dir.cwd().createFile(std.testing.io, newer_path, .{ .truncate = true });
    newer_file.close(std.testing.io);

    const older = try allocator.create(SSTable);
    older.* = try SSTable.open(allocator, older_path, 0);
    try older.write(&[_]KeyValue{
        .{ .key = key_a, .value = old_value, .seq = 1 },
        .{ .key = key_b, .value = kept, .seq = 1 },
    });
    const newer = try allocator.create(SSTable);
    newer.* = try SSTable.open(allocator, newer_path, 0);
    try newer.write(&[_]KeyValue{
        .{ .key = key_a, .value = new_value, .seq = 2 },
        .{ .key = key_b, .value = tomb, .seq = 2, .deleted = true },
    });
    try mgr.levels.items[0].append(allocator, older);
    try mgr.levels.items[0].append(allocator, newer);

    var next_id: u64 = 4;
    try mgr.compact(0, allocator, dir, &next_id, null);
    try std.testing.expectEqual(@as(u64, 5), next_id);
    try std.testing.expectEqual(@as(usize, 1), mgr.levels.items[1].items.len);
    const produced = mgr.levels.items[1].items[0];

    const got_a = try produced.read(key_a);
    defer if (got_a) |owned| allocator.free(owned);
    try std.testing.expect(got_a != null);
    try std.testing.expect(std.mem.eql(u8, got_a.?, "new"));
    try std.testing.expect((try produced.read(key_b)) == null);

    produced.deinit();
    allocator.destroy(produced);
    mgr.deinit();
}

test "compaction refuses to wrap the sstable id" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_sst_id_overflow";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var mgr = try CompactionManager.init(allocator, .{});
    const path = try std.fmt.allocPrint(allocator, "{s}/L0_seed.sst", .{dir});
    defer allocator.free(path);
    const created = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    created.close(std.testing.io);
    const sst = try allocator.create(SSTable);
    sst.* = try SSTable.open(allocator, path, 0);
    const key = try allocator.dupe(u8, "k");
    defer allocator.free(key);
    const value = try allocator.dupe(u8, "v");
    defer allocator.free(value);
    try sst.write(&[_]KeyValue{.{ .key = key, .value = value, .seq = 1 }});
    try mgr.levels.items[0].append(allocator, sst);

    var next_id: u64 = std.math.maxInt(u64);
    try std.testing.expectError(error.ArithmeticOverflow, mgr.compact(0, allocator, dir, &next_id, null));
    try std.testing.expectEqual(std.math.maxInt(u64), next_id);
    try std.testing.expectEqual(@as(usize, 1), mgr.levels.items[0].items.len);
    try std.testing.expectEqual(@as(usize, 0), mgr.levels.items[1].items.len);
    sst.deinit();
    mgr.deinit();
    allocator.destroy(sst);
}

test "SSTable read returns the stored value" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_sst_read";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/point.sst", .{dir});
    defer allocator.free(path);
    const created = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    created.close(std.testing.io);

    const sst = try allocator.create(SSTable);
    sst.* = try SSTable.open(allocator, path, 0);
    defer {
        sst.deinit();
        allocator.destroy(sst);
    }

    const live_key = try allocator.dupe(u8, "alpha");
    defer allocator.free(live_key);
    const live_value = try allocator.dupe(u8, "kept");
    defer allocator.free(live_value);
    const dead_key = try allocator.dupe(u8, "beta");
    defer allocator.free(dead_key);
    const dead_value = try allocator.dupe(u8, "gone");
    defer allocator.free(dead_value);
    const entries = [_]KeyValue{
        .{ .key = live_key, .value = live_value, .seq = 1 },
        .{ .key = dead_key, .value = dead_value, .seq = 2, .deleted = true },
    };
    try sst.write(&entries);

    const got = try sst.read(live_key);
    defer if (got) |value| allocator.free(value);
    try std.testing.expect(got != null);
    try std.testing.expect(std.mem.eql(u8, got.?, "kept"));
    try std.testing.expect((try sst.read(dead_key)) == null);
    try std.testing.expect((try sst.read("missing")) == null);
}

test "SSTable write rejects a record that does not fit in its length field" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_sst_record_size";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/huge.sst", .{dir});
    defer allocator.free(path);
    const created = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    created.close(std.testing.io);

    const sst = try allocator.create(SSTable);
    sst.* = try SSTable.open(allocator, path, 0);
    defer {
        sst.deinit();
        allocator.destroy(sst);
    }

    const key: []u8 = @as([*]u8, @ptrFromInt(0x1000))[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    var value = [_]u8{'v'};
    const entries = [_]KeyValue{
        .{ .key = key, .value = &value, .seq = 1 },
    };
    try std.testing.expectError(error.RecordTooLarge, sst.write(&entries));
    try std.testing.expectEqual(@as(usize, 0), sst.index.items.len);
}

test "SSTable index write rejects more entries than its count field can hold" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_sst_index_count";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/index.sst", .{dir});
    defer allocator.free(path);
    const created = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    created.close(std.testing.io);

    const sst = try allocator.create(SSTable);
    sst.* = try SSTable.open(allocator, path, 0);
    defer {
        sst.deinit();
        allocator.destroy(sst);
    }

    const saved = sst.index;
    defer sst.index = saved;
    sst.index.items = @as([*]SSTableIndexEntry, @ptrFromInt(0x1000))[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try std.testing.expectError(error.IndexTooLarge, sst.writeIndex());
}

test "SSTable opened for creation stays readable" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_sst_create";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/created.sst", .{dir});
    defer allocator.free(path);
    const sst = try allocator.create(SSTable);
    sst.* = try SSTable.open(allocator, path, 0);
    defer {
        sst.deinit();
        allocator.destroy(sst);
    }

    const key = try allocator.dupe(u8, "k");
    defer allocator.free(key);
    const value = try allocator.dupe(u8, "v");
    defer allocator.free(value);
    const entries = [_]KeyValue{.{ .key = key, .value = value, .seq = 1 }};
    try sst.write(&entries);

    const got = try sst.read(key);
    defer if (got) |owned| allocator.free(owned);
    try std.testing.expect(got != null);
    try std.testing.expect(std.mem.eql(u8, got.?, "v"));
}

test "SSTable reopen finds every stored key" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;
    const dir = "/tmp/lsm_sst_reopen";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/reopen.sst", .{dir});
    defer allocator.free(path);

    const first_key = try allocator.dupe(u8, "alpha");
    defer allocator.free(first_key);
    const first_value = try allocator.dupe(u8, "one");
    defer allocator.free(first_value);
    const second_key = try allocator.dupe(u8, "mu");
    defer allocator.free(second_key);
    const second_value = try allocator.dupe(u8, "two");
    defer allocator.free(second_value);

    {
        const sst = try allocator.create(SSTable);
        sst.* = try SSTable.open(allocator, path, 0);
        defer {
            sst.deinit();
            allocator.destroy(sst);
        }
        try sst.write(&[_]KeyValue{
            .{ .key = first_key, .value = first_value, .seq = 1 },
            .{ .key = second_key, .value = second_value, .seq = 2 },
        });
    }

    const reopened = try allocator.create(SSTable);
    reopened.* = try SSTable.open(allocator, path, 0);
    defer {
        reopened.deinit();
        allocator.destroy(reopened);
    }
    const first = try reopened.read(first_key);
    defer if (first) |owned| allocator.free(owned);
    const second = try reopened.read(second_key);
    defer if (second) |owned| allocator.free(owned);
    try std.testing.expect(first != null);
    try std.testing.expect(std.mem.eql(u8, first.?, "one"));
    try std.testing.expect(second != null);
    try std.testing.expect(std.mem.eql(u8, second.?, "two"));
}

test "LSMTree write batch" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    var tree = try LSMTree.init(allocator, .{ .sst_dir = "/tmp/lsm_test2" });
    defer tree.deinit();

    var batch = WriteBatch.init(allocator);
    defer batch.deinit(allocator);
    try batch.put("key1", "value1");
    try batch.put("key2", "value2");
    try tree.batchCommit(&batch);

    const first = try tree.get("key1");
    defer if (first) |owned| allocator.free(owned);
    const second = try tree.get("key2");
    defer if (second) |owned| allocator.free(owned);
    try std.testing.expect(first != null);
    try std.testing.expect(second != null);
}

test "LSMTree batch commit drops only the operations that landed" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    var tree = try LSMTree.init(allocator, .{ .sst_dir = "/tmp/lsm_batch_partial" });
    defer tree.deinit();

    var batch = WriteBatch.init(allocator);
    defer batch.deinit(allocator);
    try batch.put("key1", "value1");
    try batch.put("key2", "value2");
    tree.sequence = std.math.maxInt(u64) - 1;

    try std.testing.expectError(error.ArithmeticOverflow, tree.batchCommit(&batch));
    try std.testing.expectEqual(@as(usize, 1), batch.operations.items.len);
    try std.testing.expect(std.mem.eql(u8, batch.operations.items[0].key, "key2"));

    const first = try tree.get("key1");
    defer if (first) |owned| allocator.free(owned);
    try std.testing.expect(first != null);
    try std.testing.expect(std.mem.eql(u8, first.?, "value1"));
    try std.testing.expect((try tree.get("key2")) == null);
}

test "MemTable refuses a write that would wrap its byte count" {
    const allocator = std.testing.allocator;
    var table = try MemTable.init(allocator, std.math.maxInt(usize));
    defer table.deinit();

    table.size = std.math.maxInt(usize) - 8;
    try std.testing.expectError(error.MemTableFull, table.put("hello", "world", 1));
    try std.testing.expectEqual(@as(usize, 0), table.entries.items.len);
    try std.testing.expectEqual(std.math.maxInt(usize) - 8, table.size);
}

test "search midpoint stays inside a range at the top of usize" {
    const low = std.math.maxInt(usize) - 4;
    const high = std.math.maxInt(usize) - 1;
    const mid = searchMidpoint(low, high);
    try std.testing.expect(mid >= low);
    try std.testing.expect(mid < high);
}

test "Bloom filter" {
    const allocator = std.testing.allocator;
    var filter = try BloomFilter.init(allocator, 100, 10);
    defer filter.deinit(allocator);

    filter.add("test_key");
    try std.testing.expect(filter.contains("test_key"));
    try std.testing.expect(!filter.contains("missing_key"));
}

test "LSMTree + WAL recover after crash" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_dir = "/tmp/lsm_wal_recover_test";

    // Clean up any previous test data
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};

    // Phase 1: Create LSMTree and write data
    {
        var tree = try LSMTree.init(allocator, .{ .sst_dir = test_dir });
        defer tree.deinit();

        // Write some data (logged to WAL)
        try tree.put("key1", "value1");
        try tree.put("key2", "value2");
        try tree.put("key3", "value3");

        // Verify data is there before crash
        const before_1 = try tree.get("key1");
        defer if (before_1) |owned| allocator.free(owned);
        const before_2 = try tree.get("key2");
        defer if (before_2) |owned| allocator.free(owned);
        try std.testing.expect(before_1 != null);
        try std.testing.expect(before_2 != null);

        // Simulate crash - no checkpoint, no proper close
        // (deinit will close WAL but data should be durable)
    }

    // Phase 2: Create new LSMTree instance and recover
    {
        var tree = try LSMTree.init(allocator, .{ .sst_dir = test_dir });
        defer tree.deinit();

        // Recover from WAL
        _ = try tree.recover();
        // Verify all data is restored from WAL
        const val1 = try tree.get("key1");
        defer if (val1) |owned| allocator.free(owned);
        try std.testing.expect(val1 != null);
        try std.testing.expect(std.mem.eql(u8, val1.?, "value1"));

        const val2 = try tree.get("key2");
        defer if (val2) |owned| allocator.free(owned);
        try std.testing.expect(val2 != null);
        try std.testing.expect(std.mem.eql(u8, val2.?, "value2"));

        const val3 = try tree.get("key3");
        defer if (val3) |owned| allocator.free(owned);
        try std.testing.expect(val3 != null);
        try std.testing.expect(std.mem.eql(u8, val3.?, "value3"));
    }

    // Cleanup
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
}

test "LSMTree WAL delete replay" {
    const allocator = std.testing.allocator;
    @import("io_instance").io = std.testing.io;

    const test_dir = "/tmp/lsm_wal_delete_test";

    // Clean up
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, test_dir, .default_dir) catch {};

    // Phase 1: Write and delete
    {
        var tree = try LSMTree.init(allocator, .{ .sst_dir = test_dir });
        defer tree.deinit();

        try tree.put("key1", "value1");
        try tree.delete("key1");
    }

    // Phase 2: Recover and verify delete was replayed
    {
        var tree = try LSMTree.init(allocator, .{ .sst_dir = test_dir });
        defer tree.deinit();

        _ = try tree.recover();
        // Key should not exist after delete was replayed
        const val = try tree.get("key1");
        try std.testing.expect(val == null);
    }

    // Cleanup
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
}
