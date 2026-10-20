//! Merkle - binary Merkle tree over stored leaves
//!
//! Leaves live in a map keyed by object id. The root is recomputed from every
//! leaf after each insert or remove. This is not a 256-level sparse tree:
//! an odd trailing node is promoted, and a single leaf's root is the leaf hash.

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

/// Binary Merkle tree for state verification.
/// The historical name is SparseMerkle; the tree is built only over stored leaves.
pub const SparseMerkle = struct {
    const Self = @This();
    const LeafMap = std.AutoArrayHashMapUnmanaged(core.ObjectID, []u8);

    allocator: std.mem.Allocator,
    root: [32]u8,
    /// Number of pairing rounds above the leaves. Zero when the tree is empty or a single leaf.
    depth: usize,
    /// Number of stored leaves.
    node_count: usize,
    leaves: LeafMap,

    /// Initialize empty tree
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .root = emptyHash(0),
            .depth = 0,
            .node_count = 0,
            .leaves = .empty,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.leaves.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.leaves.deinit(self.allocator);
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

    fn lessThanKey(_: void, lhs: core.ObjectID, rhs: core.ObjectID) bool {
        return std.mem.lessThan(u8, &lhs.bytes, &rhs.bytes);
    }

    /// Leaf hashes sorted by key. `index` is the position of `needle` when one is given.
    fn sortedLeafHashes(self: *const Self, needle: ?core.ObjectID) !struct {
        hashes: [][32]u8,
        index: ?usize,
    } {
        const n = self.leaves.count();
        const keys = try self.allocator.alloc(core.ObjectID, n);
        defer self.allocator.free(keys);
        const hashes = try self.allocator.alloc([32]u8, n);
        errdefer self.allocator.free(hashes);

        @memcpy(keys, self.leaves.keys());
        std.mem.sort(core.ObjectID, keys, {}, lessThanKey);

        var index: ?usize = null;
        for (keys, hashes, 0..) |key, *out, i| {
            if (needle) |want| {
                if (want.eql(key)) index = i;
            }
            out.* = Self.hashLeaf(key, self.leaves.get(key).?);
        }
        return .{ .hashes = hashes, .index = index };
    }

    /// Pair adjacent hashes. A trailing odd node is copied upward unchanged.
    fn foldLevel(allocator: std.mem.Allocator, level: []const [32]u8) ![][32]u8 {
        const next_len = (level.len + 1) / 2;
        const next = try allocator.alloc([32]u8, next_len);
        var dst: usize = 0;
        var i: usize = 0;
        while (i < level.len) : (dst += 1) {
            if (i + 1 < level.len) {
                next[dst] = hashNode(level[i], level[i + 1]);
                i += 2;
            } else {
                next[dst] = level[i];
                i += 1;
            }
        }
        return next;
    }

    fn recomputeRoot(self: *Self) !void {
        const n = self.leaves.count();
        if (n == 0) {
            self.root = emptyHash(0);
            self.depth = 0;
            self.node_count = 0;
            return;
        }

        const sorted = try self.sortedLeafHashes(null);
        var hashes = sorted.hashes;
        defer self.allocator.free(hashes);

        var depth: usize = 0;
        while (hashes.len > 1) {
            const next = try foldLevel(self.allocator, hashes);
            self.allocator.free(hashes);
            hashes = next;
            depth += 1;
        }

        self.root = hashes[0];
        self.depth = depth;
        self.node_count = n;
    }

    /// Insert or update a key-value pair. `value` is copied; a previous buffer is freed.
    pub fn insert(self: *Self, key: core.ObjectID, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        const prev = self.leaves.fetchPut(self.allocator, key, owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        self.recomputeRoot() catch |err| {
            if (prev) |old| {
                self.leaves.getPtr(key).?.* = old.value;
            } else {
                _ = self.leaves.swapRemove(key);
            }
            self.allocator.free(owned);
            return err;
        };
        if (prev) |old| self.allocator.free(old.value);
    }

    /// Remove one key and recompute. A missing key leaves the tree unchanged.
    pub fn remove(self: *Self, key: core.ObjectID) void {
        const owned = self.leaves.get(key) orelse return;
        _ = self.leaves.swapRemove(key);
        self.recomputeRoot() catch {
            self.leaves.put(self.allocator, key, owned) catch {
                self.allocator.free(owned);
                return;
            };
            return;
        };
        self.allocator.free(owned);
    }

    /// Get current root hash
    pub fn getRoot(self: Self) [32]u8 {
        return self.root;
    }

    /// Check if key exists (non-empty value)
    pub fn contains(self: Self, key: core.ObjectID) bool {
        return self.leaves.contains(key);
    }

    /// Sibling path from the leaf up to the root.
    /// `direction.left` means the sibling sits on the left (`hashNode(sibling, current)`).
    /// `direction.right` means the sibling sits on the right (`hashNode(current, sibling)`).
    /// A promoted odd node contributes no sibling. A single leaf therefore has an empty path.
    /// Returns `error.NotFound` when `key` is absent or the stored bytes differ from `value`.
    pub fn generateProof(self: *Self, key: core.ObjectID, value: []const u8) !MerkleProof {
        const stored = self.leaves.get(key) orelse return error.NotFound;
        if (!std.mem.eql(u8, stored, value)) return error.NotFound;

        const sorted = try self.sortedLeafHashes(key);
        var hashes = sorted.hashes;
        defer self.allocator.free(hashes);
        var idx = sorted.index orelse return error.NotFound;

        var siblings: std.ArrayList(ProofNode) = .empty;
        errdefer siblings.deinit(self.allocator);

        while (hashes.len > 1) {
            if (idx % 2 == 0) {
                if (idx + 1 < hashes.len) {
                    try siblings.append(self.allocator, .{
                        .hash = hashes[idx + 1],
                        .direction = .right,
                    });
                }
            } else {
                try siblings.append(self.allocator, .{
                    .hash = hashes[idx - 1],
                    .direction = .left,
                });
            }
            const next = try foldLevel(self.allocator, hashes);
            self.allocator.free(hashes);
            hashes = next;
            idx /= 2;
        }

        return .{
            .key = key,
            .value_hash = Self.hashLeaf(key, value),
            .nodes = try siblings.toOwnedSlice(self.allocator),
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
    updates: std.AutoArrayHashMapUnmanaged(core.ObjectID, []u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .updates = .empty,
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

    /// Add update to batch. Replacing a key frees the previous buffer.
    pub fn put(self: *Self, key: core.ObjectID, value: []const u8) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        const prev = self.updates.fetchPut(self.allocator, key, owned_value) catch |err| {
            self.allocator.free(owned_value);
            return err;
        };
        if (prev) |old| self.allocator.free(old.value);
    }

    /// Remove key from batch
    pub fn remove(self: *Self, key: core.ObjectID) !void {
        const value = self.updates.get(key) orelse return;
        _ = self.updates.swapRemove(key);
        self.allocator.free(value);
    }

    /// Get update count
    pub fn count(self: Self) usize {
        return self.updates.count();
    }
};

test "SparseMerkle two keys contained and remove leaves the other" {
    const allocator = std.testing.allocator;
    var tree = try SparseMerkle.init(allocator);
    defer tree.deinit();

    const key_a = core.ObjectID.hash("alpha");
    const key_b = core.ObjectID.hash("beta");
    const key_missing = core.ObjectID.hash("missing");

    try std.testing.expect(std.mem.eql(u8, &tree.getRoot(), &SparseMerkle.emptyHash(0)));
    try std.testing.expect(!tree.contains(key_a));
    try std.testing.expect(tree.node_count == 0);

    try tree.insert(key_a, "first");
    try tree.insert(key_a, "a");
    try tree.insert(key_b, "b");

    try std.testing.expect(tree.contains(key_a));
    try std.testing.expect(tree.contains(key_b));
    try std.testing.expect(!tree.contains(key_missing));
    try std.testing.expect(tree.node_count == 2);
    try std.testing.expectError(error.NotFound, tree.generateProof(key_a, "first"));

    tree.remove(key_missing);
    try std.testing.expect(tree.contains(key_a));
    try std.testing.expect(tree.contains(key_b));
    try std.testing.expect(tree.node_count == 2);

    tree.remove(key_a);
    try std.testing.expect(!tree.contains(key_a));
    try std.testing.expect(tree.contains(key_b));
    try std.testing.expect(tree.node_count == 1);
    try std.testing.expectError(error.NotFound, tree.generateProof(key_a, "a"));

    var proof_b = try tree.generateProof(key_b, "b");
    defer proof_b.deinit(allocator);
    try std.testing.expect(proof_b.nodes.len == 0);
    const leaf_b = SparseMerkle.hashLeaf(key_b, "b");
    try std.testing.expect(std.mem.eql(u8, &tree.getRoot(), &leaf_b));
    try std.testing.expect(SparseMerkle.verify(proof_b, tree.getRoot(), key_b, "b"));
}

test "Merkle proof round-trip" {
    const allocator = std.testing.allocator;
    var tree = try SparseMerkle.init(allocator);
    defer tree.deinit();

    const key_a = core.ObjectID.hash("alpha");
    const key_b = core.ObjectID.hash("beta");

    try tree.insert(key_a, "va");
    var alone = try tree.generateProof(key_a, "va");
    defer alone.deinit(allocator);
    try std.testing.expect(alone.nodes.len == 0);
    const leaf_a = SparseMerkle.hashLeaf(key_a, "va");
    try std.testing.expect(std.mem.eql(u8, &tree.getRoot(), &leaf_a));
    try std.testing.expect(SparseMerkle.verify(alone, tree.getRoot(), key_a, "va"));

    try tree.insert(key_b, "vb");
    var proof_a = try tree.generateProof(key_a, "va");
    defer proof_a.deinit(allocator);
    var proof_b = try tree.generateProof(key_b, "vb");
    defer proof_b.deinit(allocator);

    const root = tree.getRoot();
    try std.testing.expect(SparseMerkle.verify(proof_a, root, key_a, "va"));
    try std.testing.expect(SparseMerkle.verify(proof_b, root, key_b, "vb"));
    try std.testing.expect(!std.mem.eql(u8, &root, &leaf_a));
}

test "Merkle proof verification fails with wrong value" {
    const allocator = std.testing.allocator;
    var tree = try SparseMerkle.init(allocator);
    defer tree.deinit();

    const key = core.ObjectID.hash("key");
    const value = "original";
    const wrong_value = "modified";

    try tree.insert(key, value);
    try std.testing.expectError(error.NotFound, tree.generateProof(key, wrong_value));

    var proof = try tree.generateProof(key, value);
    defer proof.deinit(allocator);

    try std.testing.expect(!SparseMerkle.verify(proof, tree.getRoot(), key, wrong_value));
    try std.testing.expect(SparseMerkle.verify(proof, tree.getRoot(), key, value));
}

test "Merkle stale proof fails after third insert" {
    const allocator = std.testing.allocator;
    var tree = try SparseMerkle.init(allocator);
    defer tree.deinit();

    const key_a = core.ObjectID.hash("alpha");
    const key_b = core.ObjectID.hash("beta");
    const key_c = core.ObjectID.hash("gamma");

    try tree.insert(key_a, "va");
    try tree.insert(key_b, "vb");

    var proof_a = try tree.generateProof(key_a, "va");
    defer proof_a.deinit(allocator);
    const old_root = tree.getRoot();
    try std.testing.expect(SparseMerkle.verify(proof_a, old_root, key_a, "va"));

    try tree.insert(key_c, "vc");
    try std.testing.expect(!SparseMerkle.verify(proof_a, tree.getRoot(), key_a, "va"));

    var fresh = try tree.generateProof(key_a, "va");
    defer fresh.deinit(allocator);
    try std.testing.expect(SparseMerkle.verify(fresh, tree.getRoot(), key_a, "va"));
}

test "Merkle batch operations" {
    const allocator = std.testing.allocator;
    var batch = try MerkleBatch.init(allocator);
    defer batch.deinit();

    const key1 = core.ObjectID.hash("key1");
    const key2 = core.ObjectID.hash("key2");

    try batch.put(key1, "value1");
    try batch.put(key2, "value2");
    try std.testing.expect(batch.count() == 2);

    try batch.put(key2, "value2-replaced");
    try std.testing.expect(batch.count() == 2);

    try batch.remove(key1);
    try std.testing.expect(batch.count() == 1);
    try batch.remove(key1);
    try std.testing.expect(batch.count() == 1);
}
