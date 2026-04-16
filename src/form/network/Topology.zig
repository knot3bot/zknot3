//! Topology - Validator network graph with Byzantine fault tolerance
//!
//! Implements validator network topology with:
//! - DAG-based adjacency for message propagation
//! - Byzantine fault tolerance
//! - Leader election support

const std = @import("std");

/// Validator node in the network
pub const Validator = struct {
    id: [32]u8, // Public key or address
    stake: u128, // Voting power
    network_address: []u8,
    is_active: bool,

    const Self = @This();

    pub fn totalWeight(validators: []const Self) u128 {
        var sum: u128 = 0;
        for (validators) |v| {
            if (v.is_active) sum += v.stake;
        }
        return sum;
    }
};

/// Network edge (connection between validators)
pub const Edge = struct {
    from: u32, // Validator index
    to: u32,
    latency_ms: u32,
};

/// Network topology
pub const Topology = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    validators: std.ArrayList(Validator),
    edges: std.ArrayList(Edge),
    adjacency: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(u32)),

    /// Initialize empty topology
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .validators = std.ArrayList(Validator).empty,
            .edges = std.ArrayList(Edge).empty,
            .adjacency = std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(u32)){},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.validators.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        var it = self.adjacency.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.adjacency.deinit(self.allocator);
    }

    /// Add a validator
    pub fn addValidator(self: *Self, validator: Validator) !u32 {
        const idx = @as(u32, @intCast(self.validators.items.len));
        try self.validators.append(self.allocator, validator);
        try self.adjacency.put(idx, std.ArrayList(u32).empty);
        return idx;
    }

    /// Add an edge between validators
    pub fn addEdge(self: *Self, from: u32, to: u32, latency_ms: u32) !void {
        try self.edges.append(self.allocator, .{ .from = from, .to = to, .latency_ms = latency_ms });
        if (self.adjacency.getPtr(from)) |neighbors| {
            try neighbors.append(self.allocator, to);
        }
    }

    /// Get Byzantine threshold (f = (n-1)/3)
    pub fn byzantineThreshold(self: Self) usize {
        const n = self.validators.items.len;
        return (n - 1) / 3;
    }

    /// Get quorum size (2f + 1)
    pub fn quorumSize(self: Self) usize {
        return 2 * self.byzantineThreshold() + 1;
    }

    /// Check if set of validators reaches quorum
    pub fn hasQuorum(self: Self, voters: []const u32, total_stake: u128) bool {
        var voting_power: u128 = 0;
        const threshold = (total_stake * 2) / 3; // 2/3 of total

        for (voters) |idx| {
            if (idx < self.validators.items.len) {
                voting_power += self.validators.items[idx].stake;
            }
        }

        return voting_power > threshold;
    }

    /// Get neighbors of a validator
    pub fn getNeighbors(self: Self, idx: u32) []const u32 {
        if (self.adjacency.get(idx)) |neighbors| {
            return neighbors.items;
        }
        return &.{};
    }

    /// Find path between two validators (BFS)
    pub fn findPath(self: Self, from: u32, to: u32) ?[]const u32 {
        if (from == to) return &.{from};

        var visited = std.AutoArrayHashMapUnmanaged(u32, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList(u32).init(self.allocator);
        defer queue.deinit();

        var parent = std.AutoArrayHashMapUnmanaged(u32, u32).init(self.allocator);
        defer parent.deinit();

        try visited.put(from, {});
        try queue.append(self.allocator, from);

        while (queue.popOrNull()) |current| {
            for (self.getNeighbors(current)) |neighbor| {
                if (!visited.contains(neighbor)) {
                    try visited.put(neighbor, {});
                    try parent.put(neighbor, current);
                    try queue.append(self.allocator, neighbor);

                    if (neighbor == to) {
                        // Reconstruct path
                        var path = std.ArrayList(u32).empty;
                        var node = to;
                        while (true) {
                            try path.append(self.allocator, node);
                            if (node == from) break;
                            node = parent.get(node).?;
                        }
                        // Reverse to get from -> to
                        std.mem.reverse(u32, path.items);
                        return path.toOwnedSlice();
                    }
                }
            }
        }

        return null;
    }
};

test "Topology quorum" {
    var topo = try Topology{};
    defer topo.deinit();

    // Add 4 validators with equal stake
    for (0..4) |i| {
        _ = try topo.addValidator(.{
            .id = [_]u8{@intCast(i)} ** 32,
            .stake = 1000,
            .network_address = "",
            .is_active = true,
        });
    }

    try std.testing.expect(topo.byzantineThreshold() == 1); // (4-1)/3 = 1
    try std.testing.expect(topo.quorumSize() == 3); // 2*1+1 = 3
}

test "Topology path finding" {
    var topo = try Topology{};
    defer topo.deinit();

    // Linear chain: 0 -> 1 -> 2 -> 3
    for (0..3) |i| {
        _ = try topo.addValidator(.{
            .id = [_]u8{@intCast(i)} ** 32,
            .stake = 1000,
            .network_address = "",
            .is_active = true,
        });
    }
    try topo.addEdge(0, 1, 10);
    try topo.addEdge(1, 2, 10);
    try topo.addEdge(2, 3, 10);

    const path = topo.findPath(0, 3);
    try std.testing.expect(path != null);
    try std.testing.expect(path.?.len == 4);
}
