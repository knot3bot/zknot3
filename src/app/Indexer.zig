//! Indexer - Indexing service for object/event queries
//!
//! Provides indexing and querying for objects and events with
//! support for pagination and filtered queries.

const std = @import("std");
const core = @import("../core.zig");

/// Indexed object with metadata
pub const IndexedObject = struct {
    id: core.ObjectID,
    version: core.Version,
    type: []u8,
    owner: ?[32]u8,
    data: []u8,
    timestamp: i64,
    const Self = @This();
    pub fn eq(self: Self, other: Self) bool {
        return self.id.eql(other.id);
    }
};

/// Indexed event with transaction reference
pub const IndexedEvent = struct {
    transaction_digest: [32]u8,
    event_type: []const u8,
    contents: []const u8,
    timestamp: i64,
    event_index: u64, // Index within the transaction
};

/// Query filter for objects
pub const ObjectQuery = struct {
    owner: ?[32]u8 = null,
    object_type: ?[]u8 = null,
    version: ?u64 = null,
};

/// Query filter for events  
pub const EventQuery = struct {
    transaction_digest: ?[32]u8 = null,
    event_type: ?[]u8 = null,
    start_time: ?i64 = null,
    end_time: ?i64 = null,
};

/// Paginated result with owned data
pub const PaginatedResult = struct {
    data: []const u8,
    next_cursor: ?[]u8,
    has_more: bool,

    pub fn deinit(self: *PaginatedResult, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
        if (self.next_cursor) |cursor| allocator.free(cursor);
        self.* = undefined;
    }
};

/// Index configuration
pub const IndexConfig = struct {
    enable_object_index: bool = true,
    enable_event_index: bool = true,
    max_page_size: usize = 100,
};

/// Indexer - main indexing service
pub const Indexer = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    config: IndexConfig,
    
    /// Objects indexed by ID
    object_index: std.AutoArrayHashMapUnmanaged(core.ObjectID, IndexedObject),
    
    /// Events indexed by transaction digest
    event_index: std.AutoArrayHashMapUnmanaged([32]u8, std.ArrayList(IndexedEvent)),
    
    /// Events by type for filtering
    events_by_type: std.StringArrayHashMapUnmanaged(std.ArrayList(IndexedEvent)),
    
    /// Object count for metrics
    object_count: u64,
    /// Event count for metrics
    event_count: u64,
    
    pub fn init(allocator: std.mem.Allocator, config: IndexConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .object_index = std.AutoArrayHashMapUnmanaged(core.ObjectID, IndexedObject).empty,
            .event_index = std.AutoArrayHashMapUnmanaged([32]u8, std.ArrayList(IndexedEvent)).empty,
            .events_by_type = std.StringArrayHashMapUnmanaged(std.ArrayList(IndexedEvent)).empty,
            .object_count = 0,
            .event_count = 0,
        };
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        var obj_it = self.object_index.iterator();
        while (obj_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.type);
            self.allocator.free(entry.value_ptr.data);
        }
        self.object_index.deinit(self.allocator);
        
        var evt_it = self.event_index.iterator();
        while (evt_it.next()) |entry| {
            for (entry.value_ptr.items) |evt| {
                self.allocator.free(evt.event_type);
                self.allocator.free(evt.contents);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.event_index.deinit(self.allocator);
        
        var type_it = self.events_by_type.iterator();
        while (type_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.events_by_type.deinit(self.allocator);
        
        self.allocator.destroy(self);
    }
    
    /// Index an object
    pub fn indexObject(self: *Self, obj: IndexedObject) !void {
        if (!self.config.enable_object_index) return;
        
        // Make a copy of the object with owned memory
        const owned_obj = IndexedObject{
            .id = obj.id,
            .version = obj.version,
            .type = try self.allocator.dupe(u8, obj.type),
            .owner = obj.owner,
            .data = try self.allocator.dupe(u8, obj.data),
            .timestamp = obj.timestamp,
        };
        
        try self.object_index.put(self.allocator, obj.id, owned_obj);
        self.object_count += 1;
    }
    
    /// Index an event
    pub fn indexEvent(self: *Self, event: IndexedEvent) !void {
        if (!self.config.enable_event_index) return;

        // Make a copy with owned memory
        const owned_event = IndexedEvent{
            .transaction_digest = event.transaction_digest,
            .event_type = try self.allocator.dupe(u8, event.event_type),
            .contents = try self.allocator.dupe(u8, event.contents),
            .timestamp = event.timestamp,
            .event_index = event.event_index,
        };
        errdefer {
            self.allocator.free(owned_event.event_type);
            self.allocator.free(owned_event.contents);
        }

        // Index by transaction
        const tx_list = try self.event_index.getOrPutValue(self.allocator, event.transaction_digest,
            std.ArrayList(IndexedEvent).empty);
        try tx_list.value_ptr.append(self.allocator, owned_event);

        // Index by type — duplicate key so it outlives the caller's buffer
        const owned_type_key = try self.allocator.dupe(u8, owned_event.event_type);
        errdefer self.allocator.free(owned_type_key);
        const type_entry = try self.events_by_type.getOrPutValue(self.allocator, owned_type_key,
            std.ArrayList(IndexedEvent).empty);
        if (type_entry.found_existing) {
            self.allocator.free(owned_type_key);
        }
        try type_entry.value_ptr.append(self.allocator, owned_event);

        self.event_count += 1;
    }
    
    /// Get object by ID
    pub fn getObject(self: Self, id: core.ObjectID) ?IndexedObject {
        return self.object_index.get(id);
    }
    
    /// Query objects with filter.
    /// Returns owned PaginatedResult — caller must call result.deinit(allocator).
    pub fn queryObjects(self: Self, allocator: std.mem.Allocator, query: ObjectQuery, cursor: ?core.ObjectID, limit: usize) !PaginatedResult {
        var results = std.ArrayList(core.ObjectID).empty;
        defer results.deinit(allocator);

        var it = self.object_index.iterator();
        var passed_cursor = cursor == null;

        while (it.next()) |entry| {
            const obj = entry.value_ptr.*;

            // Apply cursor filter
            if (!passed_cursor) {
                if (obj.id.eql(cursor.?)) {
                    passed_cursor = true;
                }
                continue;
            }

            // Apply owner filter
            if (query.owner) |owner| {
                if (obj.owner == null or !std.mem.eql(u8, &obj.owner.?, &owner)) {
                    continue;
                }
            }

            // Apply type filter
            if (query.object_type) |obj_type| {
                if (!std.mem.eql(u8, obj.type, obj_type)) {
                    continue;
                }
            }

            // Apply version filter
            if (query.version) |ver| {
                if (obj.version.seq != ver) {
                    continue;
                }
            }

            try results.append(allocator, obj.id);

            if (results.items.len >= limit) break;
        }

        const has_more = it.next() != null;
        const next_cursor = if (has_more and results.items.len > 0)
            try allocator.dupe(u8, results.items[results.items.len - 1].asBytes())
        else
            null;
        errdefer if (next_cursor) |c| allocator.free(c);

        // Serialize results into an owned byte buffer
        const data_bytes = try allocator.alloc(u8, results.items.len * @sizeOf(core.ObjectID));
        errdefer allocator.free(data_bytes);
        for (results.items, 0..) |id, i| {
            @memcpy(data_bytes[i * @sizeOf(core.ObjectID) .. (i + 1) * @sizeOf(core.ObjectID)], id.asBytes());
        }

        return .{
            .data = data_bytes,
            .next_cursor = next_cursor,
            .has_more = has_more,
        };
    }
    
    /// Get events for transaction
    pub fn getEventsForTransaction(self: Self, tx_digest: [32]u8) ?[]const IndexedEvent {
        if (self.event_index.get(tx_digest)) |list| {
            return list.items;
        }
        return null;
    }

    /// Query events with filter.
    /// Returns owned PaginatedResult — caller must call result.deinit(allocator).
    pub fn queryEvents(self: Self, allocator: std.mem.Allocator, query: EventQuery, cursor: ?u64, limit: usize) !PaginatedResult {
        var results = std.ArrayList(IndexedEvent).empty;
        defer results.deinit(allocator);

        var it = self.event_index.iterator();
        var event_idx: u64 = 0;
        var passed_cursor = cursor == null;

        while (it.next()) |entry| {
            for (entry.value_ptr.items) |evt| {
                // Apply cursor filter
                if (!passed_cursor) {
                    if (event_idx == cursor.?) {
                        passed_cursor = true;
                    }
                    event_idx += 1;
                    continue;
                }

                // Apply transaction filter
                if (query.transaction_digest) |tx_digest| {
                    if (!std.mem.eql(u8, &evt.transaction_digest, &tx_digest)) {
                        continue;
                    }
                }

                // Apply type filter
                if (query.event_type) |evt_type| {
                    if (!std.mem.eql(u8, evt.event_type, evt_type)) {
                        continue;
                    }
                }

                // Apply time filter
                if (query.start_time) |start| {
                    if (evt.timestamp < start) continue;
                }
                if (query.end_time) |end| {
                    if (evt.timestamp > end) continue;
                }

                try results.append(allocator, evt);
                event_idx += 1;

                if (results.items.len >= limit) break;
            }
            if (results.items.len >= limit) break;
        }

        const has_more = it.next() != null;

        // Serialize results into an owned byte buffer
        // Format: [4-byte event_count][events...] where each event is:
        //   [32-byte tx_digest][4-byte type_len][type_bytes][4-byte contents_len][contents_bytes][8-byte timestamp][8-byte event_index]
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(results.items.len), .little);
            try buf.appendSlice(allocator, &tmp);
        }
        for (results.items) |evt| {
            try buf.appendSlice(allocator, &evt.transaction_digest);
            {
                var tmp: [4]u8 = undefined;
                std.mem.writeInt(u32, &tmp, @intCast(evt.event_type.len), .little);
                try buf.appendSlice(allocator, &tmp);
            }
            try buf.appendSlice(allocator, evt.event_type);
            {
                var tmp: [4]u8 = undefined;
                std.mem.writeInt(u32, &tmp, @intCast(evt.contents.len), .little);
                try buf.appendSlice(allocator, &tmp);
            }
            try buf.appendSlice(allocator, evt.contents);
            {
                var tmp: [8]u8 = undefined;
                std.mem.writeInt(i64, &tmp, evt.timestamp, .little);
                try buf.appendSlice(allocator, &tmp);
            }
            {
                var tmp: [8]u8 = undefined;
                std.mem.writeInt(u64, &tmp, evt.event_index, .little);
                try buf.appendSlice(allocator, &tmp);
            }
        }

        const owned_data = try buf.toOwnedSlice(allocator);
        errdefer allocator.free(owned_data);

        return .{
            .data = owned_data,
            .next_cursor = null,
            .has_more = has_more,
        };
    }
    
    /// Get events by type
    pub fn getEventsByType(self: Self, event_type: []u8) ?[]const IndexedEvent {
        if (self.events_by_type.get(event_type)) |list| {
            return list.items;
        }
        return null;
    }
    
    /// Calculate index coverage
    pub fn coverage(self: Self, object_count: usize) f64 {
        if (object_count == 0) return 1.0;
        return @as(f64, @floatFromInt(self.object_index.count())) / @as(f64, @floatFromInt(object_count));
    }
    
    /// Get statistics
    pub fn stats(self: Self) IndexerStats {
        return .{
            .object_count = self.object_count,
            .event_count = self.event_count,
            .indexed_objects = self.object_index.count(),
            .indexed_events = self.event_index.count(),
        };
    }
};

/// Indexer statistics
pub const IndexerStats = struct {
    object_count: u64,
    event_count: u64,
    indexed_objects: usize,
    indexed_events: usize,
};

test "Indexer basic operations" {
    const allocator = std.testing.allocator;
    const config = IndexConfig{};
    var indexer = try Indexer.init(allocator, config);
    defer indexer.deinit();
    
    const obj_type = try allocator.dupe(u8, "Coin");
    defer allocator.free(obj_type);
    const obj_data = try allocator.dupe(u8, "data");
    defer allocator.free(obj_data);
    const obj = IndexedObject{
        .id = core.ObjectID.hash("test"),
        .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
        .type = obj_type,
        .owner = @as([32]u8, @splat(1)),
        .data = obj_data,
        .timestamp = 0,
    };
    
    try indexer.indexObject(obj);
    
    const retrieved = indexer.getObject(obj.id);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(std.mem.eql(u8, retrieved.?.type, "Coin"));
}

test "Indexer event indexing" {
    const allocator = std.testing.allocator;
    const config = IndexConfig{};
    var indexer = try Indexer.init(allocator, config);
    defer indexer.deinit();
    
    const tx_digest = @as([32]u8, @splat(1));
    
    const event_type = try allocator.dupe(u8, "CoinTransfer");
    defer allocator.free(event_type);
    const event_contents = try allocator.dupe(u8, "{}");
    defer allocator.free(event_contents);
    const event = IndexedEvent{
        .transaction_digest = tx_digest,
        .event_type = event_type,
        .contents = event_contents,
        .timestamp = 1000,
        .event_index = 0,
    };
    
    try indexer.indexEvent(event);
    
    const events = indexer.getEventsForTransaction(tx_digest);
    try std.testing.expect(events != null);
    try std.testing.expect(events.?.len == 1);
}

test "Indexer stats" {
    const allocator = std.testing.allocator;
    const config = IndexConfig{};
    var indexer = try Indexer.init(allocator, config);
    defer indexer.deinit();
    
    const stats = indexer.stats();
    try std.testing.expect(stats.object_count == 0);
    try std.testing.expect(stats.event_count == 0);
}
