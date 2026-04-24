//! DependencyGraph - Transaction dependency analysis for parallel execution
//!
//! Builds a dependency graph based on object access overlap.
//! Conservative default: all inputs are treated as read-write.

const std = @import("std");
const core = @import("../core.zig");
const Ingress = @import("Ingress.zig");

/// Edge in the dependency graph: target tx must execute after source tx
pub const Edge = struct {
    source: usize,
    target: usize,
};

/// Dependency graph for a batch of transactions
pub const DependencyGraph = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// incoming_edges[target] = list of source indices that must execute before target
    incoming_edges: [][]usize,
    /// outgoing_edges[source] = list of target indices that depend on source
    outgoing_edges: [][]usize,
    transaction_count: usize,

    pub fn init(allocator: std.mem.Allocator, transactions: []const Ingress.Transaction) !Self {
        const n = transactions.len;

        var incoming = try allocator.alloc([]usize, n);
        errdefer allocator.free(incoming);
        var outgoing = try allocator.alloc([]usize, n);
        errdefer allocator.free(outgoing);

        for (0..n) |i| {
            incoming[i] = &.{};
            outgoing[i] = &.{};
        }

        // Build edges based on input overlap (conservative: all inputs are writes)
        for (0..n) |i| {
            for (i + 1..n) |j| {
                if (haveOverlappingInputs(transactions[i], transactions[j])) {
                    // Tie-break by index to ensure acyclicity
                    try appendEdge(allocator, &incoming[j], i);
                    try appendEdge(allocator, &outgoing[i], j);
                }
            }
        }

        return .{
            .allocator = allocator,
            .incoming_edges = incoming,
            .outgoing_edges = outgoing,
            .transaction_count = n,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.incoming_edges) |edges| {
            if (edges.len > 0) self.allocator.free(edges);
        }
        self.allocator.free(self.incoming_edges);

        for (self.outgoing_edges) |edges| {
            if (edges.len > 0) self.allocator.free(edges);
        }
        self.allocator.free(self.outgoing_edges);
    }

    /// Compute topological batches. Each batch contains indices of transactions
    /// that have no remaining unexecuted dependencies and can run in parallel.
    pub fn topologicalBatches(self: Self, allocator: std.mem.Allocator) ![]const []const usize {
        var batches = std.ArrayList([]const usize).empty;
        errdefer {
            for (batches.items) |b| allocator.free(b);
            batches.deinit(allocator);
        }

        var remaining_deps = try allocator.alloc(usize, self.transaction_count);
        defer allocator.free(remaining_deps);
        for (0..self.transaction_count) |i| {
            remaining_deps[i] = self.incoming_edges[i].len;
        }

        var executed = try allocator.alloc(bool, self.transaction_count);
        defer allocator.free(executed);
        @memset(executed, false);

        var executed_count: usize = 0;
        while (executed_count < self.transaction_count) {
            var batch = std.ArrayList(usize).empty;
            errdefer batch.deinit(allocator);

            for (0..self.transaction_count) |i| {
                if (!executed[i] and remaining_deps[i] == 0) {
                    try batch.append(allocator, i);
                }
            }

            if (batch.items.len == 0) {
                batch.deinit(allocator);
                break;
            }

            for (batch.items) |idx| {
                executed[idx] = true;
                executed_count += 1;
                for (self.outgoing_edges[idx]) |target| {
                    if (remaining_deps[target] > 0) remaining_deps[target] -= 1;
                }
            }

            const owned_batch = try batch.toOwnedSlice(allocator);
            try batches.append(allocator, owned_batch);
        }

        return batches.toOwnedSlice(allocator);
    }

    pub fn hasDependencies(self: Self, index: usize) bool {
        return self.incoming_edges[index].len > 0;
    }

    pub fn dependencies(self: Self, index: usize) []const usize {
        return self.incoming_edges[index];
    }
};

fn haveOverlappingInputs(a: Ingress.Transaction, b: Ingress.Transaction) bool {
    for (a.inputs) |id_a| {
        for (b.inputs) |id_b| {
            if (id_a.eql(id_b)) return true;
        }
    }
    return false;
}

fn appendEdge(allocator: std.mem.Allocator, list: *([]usize), value: usize) !void {
    const old_len = list.len;
    const new_ptr = if (old_len == 0)
        try allocator.alloc(usize, 1)
    else
        try allocator.realloc(@constCast(list.ptr)[0..old_len], old_len + 1);
    new_ptr[old_len] = value;
    list.* = new_ptr[0 .. old_len + 1];
}

test "DependencyGraph no overlap => single batch" {
    const allocator = std.testing.allocator;

    const txs = &[_]Ingress.Transaction{
        .{ .sender = [_]u8{1} ** 32, .inputs = &.{core.ObjectID.fromBytes(&[_]u8{1} ** 32)}, .program = &.{}, .gas_budget = 100, .sequence = 0 },
        .{ .sender = [_]u8{2} ** 32, .inputs = &.{core.ObjectID.fromBytes(&[_]u8{2} ** 32)}, .program = &.{}, .gas_budget = 100, .sequence = 0 },
    };

    var graph = try DependencyGraph.init(allocator, txs);
    defer graph.deinit();

    const batches = try graph.topologicalBatches(allocator);
    defer {
        for (batches) |b| allocator.free(b);
        allocator.free(batches);
    }

    try std.testing.expectEqual(@as(usize, 1), batches.len);
    try std.testing.expectEqual(@as(usize, 2), batches[0].len);
}

test "DependencyGraph overlap => two batches" {
    const allocator = std.testing.allocator;
    const shared = core.ObjectID.fromBytes(&[_]u8{0xAA} ** 32);

    const txs = &[_]Ingress.Transaction{
        .{ .sender = [_]u8{1} ** 32, .inputs = &.{shared}, .program = &.{}, .gas_budget = 100, .sequence = 0 },
        .{ .sender = [_]u8{2} ** 32, .inputs = &.{shared}, .program = &.{}, .gas_budget = 100, .sequence = 0 },
    };

    var graph = try DependencyGraph.init(allocator, txs);
    defer graph.deinit();

    try std.testing.expect(graph.hasDependencies(1));
    try std.testing.expect(!graph.hasDependencies(0));

    const batches = try graph.topologicalBatches(allocator);
    defer {
        for (batches) |b| allocator.free(b);
        allocator.free(batches);
    }

    try std.testing.expectEqual(@as(usize, 2), batches.len);
    try std.testing.expectEqual(@as(usize, 1), batches[0].len);
    try std.testing.expectEqual(@as(usize, 1), batches[1].len);
}

test "DependencyGraph chain of overlaps" {
    const allocator = std.testing.allocator;
    const id_a = core.ObjectID.fromBytes(&[_]u8{0xAA} ** 32);
    const id_b = core.ObjectID.fromBytes(&[_]u8{0xBB} ** 32);

    const txs = &[_]Ingress.Transaction{
        .{ .sender = [_]u8{1} ** 32, .inputs = &.{id_a}, .program = &.{}, .gas_budget = 100, .sequence = 0 },
        .{ .sender = [_]u8{2} ** 32, .inputs = &.{id_a, id_b}, .program = &.{}, .gas_budget = 100, .sequence = 0 },
        .{ .sender = [_]u8{3} ** 32, .inputs = &.{id_b}, .program = &.{}, .gas_budget = 100, .sequence = 0 },
    };

    var graph = try DependencyGraph.init(allocator, txs);
    defer graph.deinit();

    const batches = try graph.topologicalBatches(allocator);
    defer {
        for (batches) |batch| allocator.free(batch);
        allocator.free(batches);
    }

    // tx0 and tx2 are independent (no shared inputs), tx1 depends on both
    try std.testing.expectEqual(@as(usize, 2), batches.len);
    try std.testing.expectEqual(@as(usize, 2), batches[0].len);
    try std.testing.expectEqual(@as(usize, 1), batches[1].len);
}
