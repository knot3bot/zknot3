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
    /// Bloom filter bits per key
    bloom_bits: usize = 10,
    /// SSTable directory
    sst_dir: []const u8 = "./data/sst",
};

/// Key-Value pair for LSM-Tree
pub const KeyValue = struct {
    key: []u8,
    value: []u8,
    seq: u64, // Sequence number for MVCC
    deleted: bool = false,

    pub fn lessThan(self: @This(), other: @This()) bool {
        const key_cmp = std.mem.lessThan(u8, self.key, other.key);
        return key_cmp or (std.mem.eql(u8, self.key, other.key) and self.seq > other.seq);
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
            const bit_pos = (h1 +% idx * h2) % self.num_bits;
            self.bits[bit_pos / 8] |= @as(u8, 1) << @as(u3, @intCast(bit_pos % 8));
        }
    }

    pub fn contains(self: *Self, key: []const u8) bool {
        const h1 = std.hash.Wyhash.hash(0, key);
        const h2 = std.hash.Wyhash.hash(h1, key);

        var idx: usize = 0;
        while (idx < self.num_hashes) : (idx += 1) {
            const bit_pos = (h1 +% idx * h2) % self.num_bits;
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

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !Self {
        const bloom = try allocator.create(BloomFilter);
        errdefer allocator.destroy(bloom);
        bloom.* = try BloomFilter.init(allocator, 1000000, 10);

        return .{
            .allocator = allocator,
            .entries = std.ArrayList(KeyValue){},
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
        const entry_size = key.len + value.len + 24;
        if (self.size + entry_size > self.max_size) {
            return error.MemTableFull;
        }

        try self.entries.append(self.allocator, .{
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
            .seq = seq,
            .deleted = false,
        });
        self.bloom.add(key);
        self.size += entry_size;

        // Sort by key + seq descending
        std.mem.sort(KeyValue, self.entries.items, {}, struct {
            fn lessThan(_: void, a: KeyValue, b: KeyValue) bool {
                return a.lessThan(b);
            }
        }.lessThan);
    }

    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        // Bloom filter check first
        if (!self.bloom.contains(key)) return null;

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key) and !entry.deleted) {
                return entry.value;
            }
        }
        return null;
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
};

/// SSTable index entry
pub const SSTableIndexEntry = struct {
    key: []u8,
    offset: u64,
    size: u32,
};

/// SSTable - Sorted String Table file
pub const SSTable = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    file: std.fs.File,
    path: []const u8,
    index: std.ArrayList(SSTableIndexEntry),
    bloom: *BloomFilter,
    level: usize,
    min_key: []const u8,
    max_key: []const u8,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, level: usize) !Self {
        const file = std.fs.cwd().createFile(path, .{}) catch {
            return try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        };

        return .{
            .allocator = allocator,
            .file = file,
            .path = try allocator.dupe(u8, path),
            .index = std.ArrayList(SSTableIndexEntry){},
            .bloom = try allocator.create(BloomFilter),
            .level = level,
            .min_key = &.{},
            .max_key = &.{},
        };
    }

    pub fn write(self: *Self, entries: []const KeyValue) !void {
        // Write data and index with streaming to handle any size
        var data_offset: u64 = 0;

        for (entries) |entry| {
            const key_len: u32 = @intCast(entry.key.len);
            const val_len: u32 = @intCast(entry.value.len);
            const deleted_flag: u8 = if (entry.deleted) 1 else 0;
            const record_size: u32 = 4 + key_len + 4 + val_len + 1 + 8;

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

        // Write index at end
        try self.writeIndex();
    }

    fn writeIndex(self: *Self) !void {
        // Index format: [count][key_len u32][key bytes][offset u64][size u32]...
        const count: u32 = @intCast(self.index.items.len);

        // Write count first
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, count, .big);
        try self.file.writeAll(&count_buf);

        for (self.index.items) |entry| {
            const key_len: u32 = @intCast(entry.key.len);

            // Write key_len (4 bytes)
            var key_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &key_len_buf, key_len, .big);
            try self.file.writeAll(&key_len_buf);

            // Write key bytes
            try self.file.writeAll(entry.key);

            // Write offset (8 bytes)
            var offset_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &offset_buf, entry.offset, .big);
            try self.file.writeAll(&offset_buf);

            // Write size (4 bytes)
            var size_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &size_buf, entry.size, .big);
            try self.file.writeAll(&size_buf);
        }
    }

    pub fn read(self: *Self, key: []const u8) !?[]const u8 {
        // Binary search in index
        var low: usize = 0;
        var high: usize = self.index.items.len;

        while (low < high) {
            const mid = (low + high) / 2;
            const cmp = std.mem.lessThan(u8, self.index.items[mid].key, key);
            if (cmp) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low < self.index.items.len) {
            const idx_entry = self.index.items[low];
            if (std.mem.eql(u8, idx_entry.key, key)) {
                // Seek and read value
                try self.file.seekTo(idx_entry.offset);

                // Read header (key_len + val_len + deleted)
                var header_buf: [12]u8 = undefined;
                _ = try self.file.readAll(&header_buf);

                const key_len_read = std.mem.readInt(u32, header_buf[0..4], .big);
                const val_len = std.mem.readInt(u32, header_buf[4..8], .big);
                _ = header_buf[8]; // deleted flag
                _ = key_len_read; // Already validated by index match

                // Read value (allocate exactly what we need)
                const value_buf = try self.allocator.alloc(u8, val_len);
                errdefer self.allocator.free(value_buf);
                _ = try self.file.readAll(value_buf);
                return value_buf;
            }
        }
        return null;
    }

    /// Read all entries from SSTable for compaction
    pub fn readAllEntries(self: *Self, allocator: std.mem.Allocator) ![]KeyValue {
        var entries = std.ArrayList(KeyValue){};
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            entries.deinit();
        }

        try self.file.seekTo(0);

        while (true) {
            // Read record header
            var header_buf: [12]u8 = undefined;
            const bytes_read = try self.file.readAll(&header_buf);
            if (bytes_read == 0) break;

            const key_len = std.mem.readInt(u32, header_buf[0..4], .big);
            const val_len = std.mem.readInt(u32, header_buf[4..8], .big);
            const deleted = header_buf[8] == 1;

            // Read key
            const key_buf = try allocator.alloc(u8, key_len);
            errdefer allocator.free(key_buf);
            try self.file.readAll(key_buf);

            // Read value
            const value_buf = try allocator.alloc(u8, val_len);
            try self.file.readAll(value_buf);

            // Read seq (8 bytes)
            var seq_buf: [8]u8 = undefined;
            try self.file.readAll(&seq_buf);
            const seq = std.mem.readInt(u64, &seq_buf, .big);

            try entries.append(.{
                .key = key_buf,
                .value = value_buf,
                .seq = seq,
                .deleted = deleted,
            });
        }

        return entries.toOwnedSlice();
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
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
        var levels = std.ArrayList(std.ArrayList(*SSTable)){};
        for (0..config.max_levels) |_| {
            try levels.append(allocator, std.ArrayList(*SSTable){});
        }

        return .{
            .allocator = allocator,
            .config = config,
            .levels = levels,
            .active_level = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.levels.items) |*level| {
            for (level.items) |sst| {
                sst.deinit();
            }
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
    pub fn compact(self: *Self, level: usize, allocator: std.mem.Allocator, sst_dir: []const u8, next_sst_id: *u64) !void {
        if (level >= self.levels.items.len or self.levels.items[level].items.len == 0) return;

        const sstables = self.levels.items[level].items;
        if (sstables.len == 0) return;

        var all_entries = std.ArrayList(KeyValue){};
        defer all_entries.deinit();

        for (sstables) |sst| {
            const entries = sst.readAllEntries(allocator) catch continue;
            defer {
                for (entries) |entry| {
                    allocator.free(entry.key);
                    allocator.free(entry.value);
                }
                allocator.free(entries);
            }
            for (entries) |entry| try all_entries.append(entry);
        }

        if (all_entries.items.len == 0) return;

        std.mem.sort(KeyValue, all_entries.items, {}, struct {
            fn lessThan(_: void, a: KeyValue, b: KeyValue) bool {
                return a.lessThan(b);
            }
        }.lessThan);

        var deduped = std.ArrayList(KeyValue){};
        defer {
            for (deduped.items) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            deduped.deinit();
        }

        var seen = std.AutoArrayHashMap([]const u8, void).init(allocator);
        defer seen.deinit();

        for (all_entries.items) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key);
            if (seen.contains(key_copy)) {
                allocator.free(key_copy);
                allocator.free(entry.key);
                allocator.free(entry.value);
                continue;
            }
            try seen.put(key_copy, {});
            try deduped.append(entry);
        }

        if (deduped.items.len == 0) return;

        const new_level = level + 1;
        if (new_level < self.levels.items.len) {
            const path = try std.fmt.allocPrint(allocator, "{s}/L{d}_{d}.sst", .{
                sst_dir, new_level, next_sst_id.*,
            });
            defer allocator.free(path);

            var new_sst = try allocator.create(SSTable);
            new_sst.* = try SSTable.open(allocator, path, new_level);
            defer new_sst.deinit();

            try new_sst.write(deduped.items);
            try self.levels.items[new_level].append(allocator, new_sst);
            next_sst_id.* += 1;
        }

        for (sstables) |old_sst| {
            old_sst.deinit();
            allocator.destroy(old_sst);
        }
        self.levels.items[level].clearRetainingCapacity();
    }

    pub fn needsCompaction(self: *Self) bool {
        for (self.levels.items) |level_ssts| {
            if (level_ssts.items.len > 2) return true;
        }
        return false;
    }
};
/// Write batch for atomic operations
pub const WriteBatch = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    operations: std.ArrayList(struct {
        op: enum { put, delete },
        key: []u8,
        value: []u8,
    }),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .operations = std.ArrayList(struct {
                op: enum { put, delete },
                key: []u8,
                value: []u8,
            }){},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.operations.items) |op| {
            self.allocator.free(op.key);
            self.allocator.free(op.value);
        }
        self.operations.deinit();
    }

    pub fn put(self: *Self, key: []u8, value: []u8) !void {
        try self.operations.append(self.allocator, .{
            .op = .put,
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        });
    }

    pub fn delete(self: *Self, key: []u8) !void {
        try self.operations.append(self.allocator, .{
            .op = .delete,
            .key = try self.allocator.dupe(u8, key),
            .value = &.{},
        });
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
    arena: std.heap.ArenaAllocator,
    wal: ?WAL,
    wal_path: []const u8,


/// Helper to init WAL, returning null on failure
fn initWALOrNull(allocator: std.mem.Allocator, path: []const u8) ?WAL {
    return WAL.init(allocator, path) catch null;
}

    pub fn init(allocator: std.mem.Allocator, config: LSMTreeConfig) !*Self {
        const self = try allocator.create(Self);
        // Initialize WAL for durability  
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{config.sst_dir});
        const wal: ?WAL = initWALOrNull(allocator, wal_path);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .memtable = try MemTable.init(allocator, config.memtable_size),
            .sstables = std.ArrayList(*SSTable){},
            .sequence = 0,
            .compaction = try allocator.create(CompactionManager),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .wal = wal,
            .wal_path = wal_path,
        };
        self.compaction.* = try CompactionManager.init(allocator, config);

        // Create SST directory
        std.fs.cwd().makeDir(config.sst_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.memtable.deinit();
        for (self.sstables.items) |sst| {
            sst.deinit();
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
    pub fn recover(self: *Self) !void {
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
                            const seq = s.lsm.nextSequence();
                            try s.lsm.memtable.put(key, value.?, seq);
                        },
                        .delete => {
                            const seq = s.lsm.nextSequence();
                            try s.lsm.memtable.delete(key, seq);
                        },
                        .commit, .abort => {
                            // Commit/abort don't need special handling in memtable
                            // The actual transaction semantics are handled at higher layers
                        },
                    }
                }
            }.cb;

            try wal.replay(&callback, &state);
        }
    }

    pub fn nextSequence(self: *Self) u64 {
        const seq = self.sequence;
        self.sequence += 1;
        return seq;
    }
    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        // Log to WAL first for durability
        if (self.wal) |*w| {
            try w.logInsert(key, value);
        }
        const seq = self.nextSequence();
        try self.memtable.put(key, value, seq);

        if (self.memtable.needsFlush()) {
            try self.flushMemtable();
        }
    }

    pub fn get(self: *Self, key: []const u8) !?[]const u8 {
        // Check memtable first
        if (self.memtable.get(key)) |value| {
            return value;
        }

        // Check SSTables (newest first)
        for (self.sstables.items) |sst| {
            if (sst.bloom.contains(key)) {
                if (try sst.read(key)) |value| {
                    return value;
                }
            }
        }

        return null;
    }

    pub fn delete(self: *Self, key: []const u8) !void {
        // Log to WAL first for durability
        if (self.wal) |*w| {
            try w.logDelete(key);
        }
        const seq = self.nextSequence();
        try self.memtable.delete(key, seq);

        if (self.memtable.needsFlush()) {
            try self.flushMemtable();
        }
    }

    fn flushMemtable(self: *Self) !void {
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
        try sst.write(entries);

        try self.sstables.append(self.allocator, sst);
    }

    pub fn batchInit(allocator: std.mem.Allocator) WriteBatch {
        return WriteBatch.init(allocator);
    }

    pub fn batchCommit(self: *Self, batch: *WriteBatch) !void {
        for (batch.operations.items) |op| {
            switch (op.op) {
                .put => try self.put(op.key, op.value),
                .delete => try self.delete(op.key),
            }
        }
        // Log commit to WAL after all operations
        if (self.wal) |*w| {
            try w.logCommit();
        }
        batch.clear();
    }

    pub fn count(self: Self) usize {
        return self.memtable.entries.items.len + self.sstables.items.len;
    }

    /// Trigger compaction if needed
    pub fn maybeCompact(self: *Self) !void {
        if (!self.compaction.needsCompaction()) return;

        for (self.compaction.levels.items, 0..) |level_ssts, level| {
            if (level_ssts.items.len > 3) {
                try self.compaction.compact(level, self.allocator, self.config.sst_dir, &self.sequence);
            }
        }
    }
};

test "LSMTree basic operations" {
    const allocator = std.testing.allocator;
    var tree = try LSMTree.init(allocator, .{ .sst_dir = "/tmp/lsm_test" });
    defer tree.deinit();

    try tree.put("key1", "value1");
    const val = try tree.get("key1");
    try std.testing.expect(val != null);
    try std.testing.expect(std.mem.eql(u8, val.?, "value1"));
}

test "LSMTree write batch" {
    const allocator = std.testing.allocator;
    var tree = try LSMTree.init(allocator, .{ .sst_dir = "/tmp/lsm_test2" });
    defer tree.deinit();

    var batch = tree.batchInit();
    defer batch.deinit();
    try batch.put("key1", "value1");
    try batch.put("key2", "value2");
    try tree.batchCommit(&batch);

    try std.testing.expect((try tree.get("key1")) != null);
    try std.testing.expect((try tree.get("key2")) != null);
}

test "Bloom filter" {
    const allocator = std.testing.allocator;
    var filter = try BloomFilter.init(allocator, 100, 10);
    defer filter.deinit();

    filter.add("test_key");
    try std.testing.expect(filter.contains("test_key"));
    try std.testing.expect(!filter.contains("missing_key"));
}

test "LSMTree + WAL recover after crash" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/lsm_wal_recover_test";

    // Clean up any previous test data
    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().makeDir(test_dir) catch {};

    // Phase 1: Create LSMTree and write data
    {
        var tree = try LSMTree.init(allocator, .{ .sst_dir = test_dir });
        defer tree.deinit();

        // Write some data (logged to WAL)
        try tree.put("key1", "value1");
        try tree.put("key2", "value2");
        try tree.put("key3", "value3");

        // Verify data is there before crash
        try std.testing.expect((try tree.get("key1")) != null);
        try std.testing.expect((try tree.get("key2")) != null);

        // Simulate crash - no checkpoint, no proper close
        // (deinit will close WAL but data should be durable)
    }

    // Phase 2: Create new LSMTree instance and recover
    {
        var tree = try LSMTree.init(allocator, .{ .sst_dir = test_dir });
        defer tree.deinit();

        // Recover from WAL
        try tree.recover();

        // Verify all data is restored from WAL
        const val1 = try tree.get("key1");
        try std.testing.expect(val1 != null);
        try std.testing.expect(std.mem.eql(u8, val1.?, "value1"));

        const val2 = try tree.get("key2");
        try std.testing.expect(val2 != null);
        try std.testing.expect(std.mem.eql(u8, val2.?, "value2"));

        const val3 = try tree.get("key3");
        try std.testing.expect(val3 != null);
        try std.testing.expect(std.mem.eql(u8, val3.?, "value3"));
    }

    // Cleanup
    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "LSMTree WAL delete replay" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/lsm_wal_delete_test";

    // Clean up
    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().makeDir(test_dir) catch {};

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

        try tree.recover();

        // Key should not exist after delete was replayed
        const val = try tree.get("key1");
        try std.testing.expect(val == null);
    }

    // Cleanup
    std.fs.cwd().deleteTree(test_dir) catch {};
}

