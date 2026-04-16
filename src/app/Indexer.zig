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
    event_type: []u8,
    contents: []u8,
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

/// Paginated result
pub const PaginatedResult = struct {
    data: []const u8,
    next_cursor: ?[]u8,
    has_more: bool,
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
        
        // Index by transaction
        const tx_list = try self.event_index.getOrPutValue(self.allocator, event.transaction_digest,
            std.ArrayList(IndexedEvent).empty);
        try tx_list.value_ptr.append(self.allocator, owned_event);
        
        // Index by type
        const type_list = try self.events_by_type.getOrPutValue(self.allocator, event.event_type,
            std.ArrayList(IndexedEvent).empty);
        try type_list.value_ptr.append(self.allocator, owned_event);
        
        self.event_count += 1;
    }
    
    /// Get object by ID
    pub fn getObject(self: Self, id: core.ObjectID) ?IndexedObject {
        return self.object_index.get(id);
    }
    
    /// Query objects with filter
    pub fn queryObjects(self: Self, query: ObjectQuery, cursor: ?core.ObjectID, limit: usize) !PaginatedResult {
        var results = std.ArrayList(core.ObjectID).empty;
        defer results.deinit();
        
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
            
            try results.append(self.allocator, obj.id);
            
            if (results.items.len >= limit) break;
        }
        
        const has_more = it.next() != null;
        const next_cursor = if (has_more and results.items.len > 0)
            try self.allocator.dupe(u8, results.items[results.items.len - 1].asBytes())
        else
            null;
        
        return .{
            .data = &results,
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
    
    /// Query events with filter
    pub fn queryEvents(self: Self, query: EventQuery, cursor: ?u64, limit: usize) !PaginatedResult {
        var results = std.ArrayList(IndexedEvent).empty;
        defer results.deinit();
        
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
                
                try results.append(self.allocator, evt);
                event_idx += 1;
                
                if (results.items.len >= limit) break;
            }
            if (results.items.len >= limit) break;
        }
        
        const has_more = it.next() != null;
        
        return .{
            .data = &results,
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
    
    const obj = IndexedObject{
        .id = core.ObjectID.hash("test"),
        .version = .{ .seq = 1, .causal = [_]u8{0} ** 16 },
        .type = try allocator.dupe(u8, "Coin"),
        .owner = [_]u8{1} ** 32,
        .data = try allocator.dupe(u8, "data"),
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
    
    const tx_digest = [_]u8{1} ** 32;
    
    const event = IndexedEvent{
        .transaction_digest = tx_digest,
        .event_type = try allocator.dupe(u8, "CoinTransfer"),
        .contents = try allocator.dupe(u8, "{}"),
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
