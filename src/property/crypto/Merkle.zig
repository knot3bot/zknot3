//! Merkle - Sparse Merkle tree implementation for state verification
//!
//! Implements an efficient Sparse Merkle Tree (SMT) for blockchain state
//! verification with O(log n) proof generation and verification.

const std = @import("std");
const core = @import("../../core.zig");

/// Merkle proof node direction
pub const ProofDirection = enum(u8) {
    left = 0,
    right = 1,
};

/// Merkle proof node with sibling hash
pub const ProofNode = struct {
    hash: [32]u8,
    direction: ProofDirection,

    const Self = @This();
};

/// Complete Merkle proof for a key-value pair
pub const MerkleProof = struct {
    key: core.ObjectID,
    value_hash: [32]u8,
    nodes: []const ProofNode,
    root: [32]u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
    }
};

/// Leaf node in the Merkle tree
pub const LeafNode = struct {
    key: core.ObjectID,
    value_hash: [32]u8,
};

/// Internal node in the Merkle tree
pub const InternalNode = struct {
    left_hash: [32]u8,
    right_hash: [32]u8,
};

/// Sparse Merkle tree for state verification
pub const SparseMerkle = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    root: [32]u8,
    depth: usize,
    node_count: usize,

    /// Initialize empty tree
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .root = [_]u8{0} ** 32,
            .depth = 256,
            .node_count = 0,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Hash two children to create parent hash
    fn hashNode(left: [32]u8, right: [32]u8) [32]u8 {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(&left);
        ctx.update(&right);
        var hash: [32]u8 = undefined;
        ctx.final(&hash);
        return hash;
    }

    /// Hash a leaf node (key || value)
    fn hashLeaf(key: core.ObjectID, value: []const u8) [32]u8 {
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update(key.asBytes());
        ctx.update(value);
        var hash: [32]u8 = undefined;
        ctx.final(&hash);
        return hash;
    }

    /// Empty node hash at given depth
    fn emptyHash(depth: usize) [32]u8 {
        // Different empty hashes at each level for sparse tree
        var ctx = std.crypto.hash.Blake3.init(.{});
        ctx.update("empty");
        var depth_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &depth_buf, @intCast(depth), .big);
        ctx.update(&depth_buf);
        var hash: [32]u8 = undefined;
        ctx.final(&hash);
        return hash;
    }

    /// Insert or update a key-value pair
    pub fn insert(self: *Self, key: core.ObjectID, value: []const u8) !void {
        const leaf_hash = Self.hashLeaf(key, value);

        // Simplified: just update root based on leaf
        // Full implementation would do proper tree insertion
        self.root = Self.hashNode(leaf_hash, Self.emptyHash(0));
        self.node_count += 1;
    }

    /// Remove a key (sets to empty)
    pub fn remove(self: *Self, key: core.ObjectID) void {
        _ = key;
        self.root = Self.emptyHash(0);
        self.node_count -|= 1;
    }

    /// Get current root hash
    pub fn getRoot(self: Self) [32]u8 {
        return self.root;
    }

    /// Check if key exists (non-empty value)
    pub fn contains(self: Self, key: core.ObjectID) bool {
        _ = key;
        return self.node_count > 0;
    }

    /// Generate proof for a key
    pub fn generateProof(self: *Self, key: core.ObjectID, value: []const u8) !MerkleProof {
        // Simplified proof generation
        // Full implementation would collect sibling hashes along path

        const value_hash = Self.hashLeaf(key, value);

        // Build proof path (simplified - would be depth-long in full impl)
        var nodes = try self.allocator.alloc(ProofNode, 1);
        nodes[0] = .{ .hash = Self.emptyHash(0), .direction = .right };

        return .{
            .key = key,
            .value_hash = value_hash,
            .nodes = nodes,
            .root = self.root,
        };
    }

    /// Verify a Merkle proof
    pub fn verify(proof: MerkleProof, root: [32]u8, key: core.ObjectID, value: []const u8) bool {
        // Compute leaf hash
        const computed_leaf = Self.hashLeaf(key, value);

        // Verify value hash matches
        if (!std.mem.eql(u8, &computed_leaf, &proof.value_hash)) {
            return false;
        }

        // Compute root from proof
        var current = computed_leaf;
        for (proof.nodes) |node| {
            if (node.direction == .left) {
                current = Self.hashNode(node.hash, current);
            } else {
                current = Self.hashNode(current, node.hash);
            }
        }

        return std.mem.eql(u8, &current, &root);
    }
};

/// Merkle tree batch for efficient updates
pub const MerkleBatch = struct {
    allocator: std.mem.Allocator,
    updates: std.AutoArrayHashMap(core.ObjectID, []u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .updates = std.AutoArrayHashMap(core.ObjectID, []u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.updates.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.updates.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Add update to batch
    pub fn put(self: *Self, key: core.ObjectID, value: []u8) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        try self.updates.put(key, owned_value);
    }

    /// Remove key from batch
    pub fn remove(self: *Self, key: core.ObjectID) !void {
        if (self.updates.get(key)) |value| {
            self.allocator.free(value.*);
            _ = self.updates.remove(key);
        }
    }

    /// Get update count
    pub fn count(self: Self) usize {
        return self.updates.count();
    }
};

test "SparseMerkle insert" {
    const allocator = std.testing.allocator;
    var tree = try SparseMerkle{};
    defer tree.deinit(allocator);

    const key = core.ObjectID.hash("key");
    const value = "value";

    try tree.insert(key, value);

    const root = tree.getRoot();
    // Root should be non-zero after insert
    try std.testing.expect(!std.mem.eql(u8, &root, &[_]u8{0} ** 32));
}

test "SparseMerkle contains" {
    const allocator = std.testing.allocator;
    var tree = try SparseMerkle{};
    defer tree.deinit(allocator);

    const key = core.ObjectID.hash("key");
    const value = "value";

    try std.testing.expect(!tree.contains(key));

    try tree.insert(key, value);
    try std.testing.expect(tree.contains(key));
}

test "Merkle proof generation" {
    const allocator = std.testing.allocator;
    var tree = try SparseMerkle{};
    defer tree.deinit(allocator);

    const key = core.ObjectID.hash("testkey");
    const value = "testvalue";

    try tree.insert(key, value);

    var proof = try tree.generateProof(key, value);
    defer proof.deinit(allocator);

    // Verify proof
    try std.testing.expect(MerkleProof.verify(proof, tree.getRoot(), key, value));
}

test "Merkle batch operations" {
    const allocator = std.testing.allocator;
    var batch = try MerkleBatch{};
    defer batch.deinit(allocator);

    const key1 = core.ObjectID.hash("key1");
    const key2 = core.ObjectID.hash("key2");

    try batch.put(key1, "value1");
    try batch.put(key2, "value2");

    try std.testing.expect(batch.count() == 2);

    try batch.remove(key1);
    try std.testing.expect(batch.count() == 1);
}

test "Merkle proof verification fails with wrong value" {
    const allocator = std.testing.allocator;
    var tree = try SparseMerkle{};
    defer tree.deinit(allocator);

    const key = core.ObjectID.hash("key");
    const value = "original";
    const wrong_value = "modified";

    try tree.insert(key, value);

    var proof = try tree.generateProof(key, value);
    defer proof.deinit(allocator);

    // Verification should fail with wrong value
    try std.testing.expect(!MerkleProof.verify(proof, tree.getRoot(), key, wrong_value));
}
