//! Resource - Linear type system for Move resources
//!
//! Implements compile-time verification of linear type constraints:
//! - Resources cannot be copied (use-after-move semantics)
//! - Resources must be consumed exactly once
//! - No resource leaks at runtime

const std = @import("std");
const core = @import("../../core.zig");

/// Resource state for tracking linear usage
pub const ResourceState = enum {
    active,
    moved,
    consumed,
};

/// Resource container for tracking state
pub const ResourceContainer = struct {
    state: ResourceState = .active,
};

/// Resource tag - quotient set partition for resource types
pub const ResourceTag = enum(u8) {
    Coin = 0,
    NFT = 1,
    SharedObject = 2,
    Custom = 3,

    const Self = @This();

    /// Check if this is a builtin type
    pub fn isBuiltin(self: Self) bool {
        return @intFromEnum(self) < 3;
    }
};

/// Linear resource with move semantics
/// A resource can only be moved, not copied
pub const Resource = struct {
    const Self = @This();

    /// Resource identifier
    id: core.ObjectID,
    /// Resource type tag
    tag: ResourceTag,
    /// 16-byte aligned data for SIMD optimization
    data: [*]align(16) u8,
    /// Data length
    data_len: usize,
    /// Owner (for access control)
    owner: ?[32]u8,

    /// Resource status for linear tracking
    _state: ResourceState = .active,

    /// Initialize a new resource
    pub fn init(
        id: core.ObjectID,
        tag: ResourceTag,
        data: []const u8,
        owner: ?[32]u8,
        allocator: std.mem.Allocator,
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .id = id,
            .tag = tag,
            .data = (try allocator.alignedAlloc(u8, .@"16", data.len)).ptr,
            .data_len = data.len,
            .owner = owner,
            ._state = .active,
        };
        @memcpy(self.data[0..data.len], data);
        return self;
    }

    /// Deinitialize internal resources (does NOT destroy the object itself)
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.data[0..self.data_len]);
    }

    /// Move resource to another location (linear semantics)
    /// Source resource is invalidated after move
    pub fn move(self: *Self, destination: *Self) void {
        destination.* = .{
            .id = self.id,
            .tag = self.tag,
            .data = self.data,
            .data_len = self.data_len,
            .owner = self.owner,
            ._state = .active,
        };
        self.data_len = 0;
        self._state = .moved;
    }

    /// Check if resource is still valid (not moved/consumed)
    pub fn isValid(self: Self) bool {
        return self._state == .active;
    }

    /// Check if resource has been moved
    pub fn isMoved(self: Self) bool {
        return self._state == .moved;
    }

    /// Consume resource (final use in linear type)
    pub fn consume(self: *Self) void {
        self._state = .consumed;
    }

    /// Validate resource is properly tracked (for debug)
    pub fn validate(self: Self) void {
        std.debug.assert(self._state != .moved or self.data_len == 0);
    }

    /// Get resource type as string
    pub fn typeName(self: Self) []const u8 {
        return switch (self.tag) {
            .Coin => "Coin",
            .NFT => "NFT",
            .SharedObject => "SharedObject",
            .Custom => "Custom",
        };
    }

    /// Check ownership
    pub fn isOwnedBy(self: Self, address: [32]u8) bool {
        return self.owner != null and std.mem.eql(u8, &self.owner.?, &address);
    }
};

/// Resource tracker for linear type verification
pub const ResourceTracker = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    active_resources: std.AutoArrayHashMap(core.ObjectID, *Resource),
    moved_resources: std.AutoArrayHashMap(core.ObjectID, void),
    consumed_resources: std.AutoArrayHashMap(core.ObjectID, void),
    total_created: usize,
    total_transferred: usize,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .active_resources = std.AutoArrayHashMap(core.ObjectID, *Resource).init(allocator),
            .moved_resources = std.AutoArrayHashMap(core.ObjectID, void).init(allocator),
            .consumed_resources = std.AutoArrayHashMap(core.ObjectID, void).init(allocator),
            .total_created = 0,
            .total_transferred = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.active_resources.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.active_resources.deinit();
        self.moved_resources.deinit();
        self.consumed_resources.deinit();
    }

    pub fn track(self: *Self, resource: *Resource) !void {
        try self.active_resources.put(resource.id, resource);
        self.total_created += 1;
    }

    pub fn recordMove(self: *Self, resource_id: core.ObjectID) !void {
        if (self.active_resources.contains(resource_id)) {
            _ = self.active_resources.swapRemove(resource_id);
        }
        try self.moved_resources.put(resource_id, {});
        self.total_transferred += 1;
    }

    pub fn recordConsume(self: *Self, resource_id: core.ObjectID) !void {
        if (self.active_resources.contains(resource_id)) {
            _ = self.active_resources.swapRemove(resource_id);
        }
        try self.consumed_resources.put(resource_id, {});
    }

    pub fn getCreated(self: Self) ![]const core.ObjectID {
        var result = std.ArrayList(core.ObjectID).init(self.allocator);
        errdefer result.deinit(self.allocator);
        var it = self.active_resources.iterator();
        while (it.next()) |entry| {
            try result.append(entry.key_ptr.*);
        }
        return result.toOwnedSlice(self.allocator);
    }

    pub fn validate(self: Self) !void {
        var it = self.active_resources.iterator();
        while (it.next()) |entry| {
            try validateResource(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn validateResource(id: core.ObjectID, resource: *Resource) !void {
        if (resource._state != .active) return error.InvalidResourceState;
        if (!id.eql(resource.id)) return error.ResourceIdMismatch;
    }

    pub fn checkLeaks(self: Self) !void {
        if (self.active_resources.count() > 0) return error.ResourceLeak;
    }

    pub fn isTracked(self: Self, id: core.ObjectID) bool {
        return self.active_resources.contains(id);
    }

    pub fn wasMoved(self: Self, id: core.ObjectID) bool {
        return self.moved_resources.contains(id);
    }

    pub fn wasConsumed(self: Self, id: core.ObjectID) bool {
        return self.consumed_resources.contains(id);
    }

    pub fn activeCount(self: Self) usize {
        return self.active_resources.count();
    }

    pub fn getTotalCreated(self: Self) usize {
        return self.total_created;
    }

    pub fn getTotalTransferred(self: Self) usize {
        return self.total_transferred;
    }
};

test "Resource lifecycle" {
    const allocator = std.testing.allocator;
    var resource = try Resource.init(
        core.ObjectID.hash("test"),
        .Coin,
        "1000",
        null,
        allocator,
    );
    defer {
        resource.deinit(allocator);
        allocator.destroy(resource);
    }

    try std.testing.expect(resource.isValid());
    try std.testing.expect(resource.tag == .Coin);
}

test "Resource move semantics" {
    const allocator = std.testing.allocator;
    var src = try Resource.init(
        core.ObjectID.hash("test"),
        .Coin,
        "1000",
        null,
        allocator,
    );
    defer {
        src.deinit(allocator);
        allocator.destroy(src);
    }

    var dst: Resource = undefined;
    src.move(&dst);
    defer dst.deinit(allocator);

    try std.testing.expect(!src.isValid());
    try std.testing.expect(dst.isValid());
}

test "ResourceTracker leak detection" {
    const allocator = std.testing.allocator;
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    const resource = try Resource.init(
        core.ObjectID.hash("leak_test"),
        .Coin,
        "1000",
        null,
        allocator,
    );
    // tracker takes ownership, will free in tracker.deinit()

    try tracker.track(resource);
    try std.testing.expectError(error.ResourceLeak, tracker.checkLeaks());
}

test "ResourceTracker move tracking" {
    const allocator = std.testing.allocator;
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    const id = core.ObjectID.hash("test");
    var resource = try Resource.init(
        id,
        .Coin,
        "1000",
        null,
        allocator,
    );
    defer {
        resource.deinit(allocator);
        allocator.destroy(resource);
    }

    try tracker.track(resource);
    try std.testing.expect(tracker.isTracked(id));

    try tracker.recordMove(id);
    try std.testing.expect(!tracker.isTracked(id));
    try std.testing.expect(tracker.wasMoved(id));
}

test "ResourceTracker consume tracking" {
    const allocator = std.testing.allocator;
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    const id = core.ObjectID.hash("test");
    var resource = try Resource.init(
        id,
        .Coin,
        "1000",
        null,
        allocator,
    );
    defer {
        resource.deinit(allocator);
        allocator.destroy(resource);
    }

    try tracker.track(resource);
    try tracker.recordConsume(id);
    try std.testing.expect(!tracker.isTracked(id));
    try std.testing.expect(tracker.wasConsumed(id));
    try tracker.checkLeaks();
}
