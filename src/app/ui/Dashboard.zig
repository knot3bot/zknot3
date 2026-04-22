//! Dashboard - Web UI dashboard with HTMX + Alpine.js

const std = @import("std");
const app = @import("../../app.zig");
const Node = app.Node;
const NodeStatsCoordinator = @import("../NodeStatsCoordinator.zig");

pub const NodeInfoResponse = struct {
    version: []const u8,
    state: []const u8,
    uptime_seconds: i64,
    object_store_count: u64,
    checkpoint_sequence: u64,
    pending_transactions: usize,
    committed_blocks: usize,

    pub fn fromNode(node: *Node) @This() {
        const info = node.getNodeInfo();
        return .{
            .version = "0.1.0",
            .state = "running",
            .uptime_seconds = info.uptime_seconds,
            .object_store_count = info.object_store_count,
            .checkpoint_sequence = info.checkpoint_sequence,
            .pending_transactions = info.pending_transactions,
            .committed_blocks = info.committed_blocks,
        };
    }
};

pub const BlockInfo = struct {
    hash: []const u8,
    round: u64,
    author: []const u8,
    timestamp: i64,
    tx_count: usize,
};

pub const TxnInfo = struct {
    hash: []const u8,
    status: []const u8,
    gas_used: u64,
    timestamp: i64,
    sender: []const u8,
};

pub const BlocksResponse = struct {
    blocks: []BlockInfo,
    total: usize,
};

pub const TransactionsResponse = struct {
    transactions: []TxnInfo,
    total: usize,
};

pub const ConsensusStatusResponse = struct {
    current_round: u64,
    highest_committed_block: u64,
    active_validators: u32,
    quorum_reached: bool,

    pub fn fromNode(node: *Node) @This() {
        const snap = NodeStatsCoordinator.snapshot(&node.stats);
        const has_quorum = if (node.committed_blocks.count() > 0) blk: {
            const values = node.committed_blocks.values();
            const latest = values[values.len - 1];
            break :blk latest.votes.count() >= node.config.consensus.vote_quorum;
        } else false;
        return .{
            .current_round = snap.highest_round,
            .highest_committed_block = snap.blocks_committed,
            .active_validators = if (node.deps.epoch_bridge) |bridge|
                @intCast(bridge.quorum.members.items.len)
            else
                @intCast(node.config.consensus.target_validators),
            .quorum_reached = has_quorum,
        };
    }
};

pub const TxnStatsResponse = struct {
    pending: usize,
    executing: usize,
    total_executed: u64,

    pub fn fromNode(node: *Node) @This() {
        const pool_stats = node.getTxnPoolStats();
        const total = NodeStatsCoordinator.txExecuted(&node.stats);
        return .{
            .pending = pool_stats.pending,
            .executing = pool_stats.executing,
            .total_executed = total,
        };
    }
};

pub const TriSourceMetricsResponse = struct {
    wu_feng: f64,
    xiang_da: f64,
    zi_zai: f64,

    pub fn fromNode(node: *Node) @This() {
        const m = node.getTriSourceMetrics();
        return .{
            .wu_feng = m.wu_feng,
            .xiang_da = m.xiang_da,
            .zi_zai = m.zi_zai,
        };
    }
};

pub const SystemInfoResponse = struct {
    cpu_count: usize,
    total_memory_bytes: u64,
    cpu_usage_percent: f64,

    pub fn fromNode(node: *Node) @This() {
        const s = node.getSystemInfo();
        return .{
            .cpu_count = s.cpu_count,
            .total_memory_bytes = s.total_memory_bytes,
            .cpu_usage_percent = s.cpu_usage_percent,
        };
    }
};

fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        result[i * 2] = hex_chars[b >> 4];
        result[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return result;
}

pub fn toJSON(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub const DashboardHandler = struct {
    allocator: std.mem.Allocator,
    node: ?*Node,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .node = null,
        };
    }

    pub fn setNode(self: *@This(), node: *Node) void {
        self.node = node;
    }

    pub fn handleAPI(self: *@This(), path: []const u8) ![]u8 {
        if (self.node == null) {
            return error.NodeNotSet;
        }
        const node = self.node.?;

        if (std.mem.eql(u8, path, "/api/node/info")) {
            return try toJSON(self.allocator, NodeInfoResponse.fromNode(node));
        } else if (std.mem.eql(u8, path, "/api/consensus/status")) {
            return try toJSON(self.allocator, ConsensusStatusResponse.fromNode(node));
        } else if (std.mem.eql(u8, path, "/api/txn/stats")) {
            return try toJSON(self.allocator, TxnStatsResponse.fromNode(node));
        } else if (std.mem.eql(u8, path, "/api/metrics")) {
            return try toJSON(self.allocator, TriSourceMetricsResponse.fromNode(node));
        } else if (std.mem.eql(u8, path, "/api/blocks")) {
            return try self.handleBlocks();
        } else if (std.mem.eql(u8, path, "/api/transactions")) {
            return try self.handleTransactions();
        } else if (std.mem.eql(u8, path, "/api/epoch")) {
            const epoch = node.getEpochInfo();
            return try toJSON(self.allocator, .{
                .epoch_number = epoch.epoch_number,
                .total_stake = epoch.total_stake,
                .validator_count = @as(u32, @intCast(epoch.validator_count)),
                .quorum_threshold = epoch.quorum_threshold,
                .needs_reconfiguration = node.needsReconfiguration(),
            });
        } else if (std.mem.eql(u8, path, "/api/validators")) {
            return try self.handleValidators();
        } else if (std.mem.eql(u8, path, "/api/system/info")) {
            return try toJSON(self.allocator, SystemInfoResponse.fromNode(node));
        } else {
            return error.NotFound;
        }
    }

    fn handleBlocks(self: *@This()) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;

        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        var blocks = try std.ArrayList(BlockInfo).initCapacity(self.allocator, 20);
        var hex_strings = std.ArrayList([]const u8).empty;
        defer {
            for (hex_strings.items) |s| self.allocator.free(s);
            hex_strings.deinit(self.allocator);
        }

        var it = node.committed_blocks.iterator();
        while (it.next()) |entry| {
            const block = entry.value_ptr.*;
            const tx_count = if (block.payload.len > 0) @as(usize, block.payload.len / 32) else 0;
            const author_hex = try bytesToHex(self.allocator, &block.author);
            try hex_strings.append(self.allocator, author_hex);
            const hash_hex = try bytesToHex(self.allocator, &block.digest);
            try hex_strings.append(self.allocator, hash_hex);

            try blocks.append(self.allocator, .{
                .hash = hash_hex,
                .round = block.round.value,
                .author = author_hex,
                .timestamp = now + 84 - @as(i64, @intCast(block.round.value)) * 2,
                .tx_count = tx_count,
            });
        }

        const response = BlocksResponse{
            .blocks = blocks.items,
            .total = node.committed_blocks.count(),
        };
        defer blocks.deinit(self.allocator);
        const json = try toJSON(self.allocator, response);
        return json;
    }

    fn handleTransactions(self: *@This()) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;

        var txns = try std.ArrayList(TxnInfo).initCapacity(self.allocator, 50);
        var hex_strings = std.ArrayList([]u8).empty;
        defer {
            for (hex_strings.items) |s| self.allocator.free(s);
            hex_strings.deinit(self.allocator);
        }

        var it = node.txn_history.iterator();
        while (it.next()) |entry| {
            const receipt = entry.value_ptr.*;
            const hash_hex = try bytesToHex(self.allocator, &receipt.digest);
            try hex_strings.append(self.allocator, hash_hex);
            const sender_hex = try bytesToHex(self.allocator, &receipt.sender);
            try hex_strings.append(self.allocator, sender_hex);

            try txns.append(self.allocator, .{
                .hash = hash_hex,
                .status = @tagName(receipt.status),
                .gas_used = receipt.gas_used,
                .timestamp = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
                .sender = sender_hex,
            });
        }

        const response = TransactionsResponse{
            .transactions = txns.items,
            .total = node.txn_history.count(),
        };
        defer txns.deinit(self.allocator);
        const json = try toJSON(self.allocator, response);
        return json;
    }

    fn handleValidators(self: *@This()) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;

        const validators = try node.getValidatorList(self.allocator);
        defer self.allocator.free(validators);

        var list = try std.ArrayList(ValidatorInfo).initCapacity(self.allocator, validators.len);
        var hex_strings = std.ArrayList([]const u8).empty;
        defer {
            for (hex_strings.items) |s| self.allocator.free(s);
            hex_strings.deinit(self.allocator);
        }

        for (validators) |v| {
            const id_hex = try bytesToHex(self.allocator, &v.id);
            try hex_strings.append(self.allocator, id_hex);
            try list.append(self.allocator, .{
                .id = id_hex,
                .stake = @intCast(v.stake),
                .voting_power = @intCast(v.voting_power),
                .is_active = v.is_active,
            });
        }

        const quorum_threshold = if (node.deps.epoch_bridge) |bridge|
            bridge.stake_pool.quorumThreshold()
        else
            0;

        const response = .{
            .validators = list.items,
            .total = list.items.len,
            .quorum_threshold = quorum_threshold,
        };
        defer list.deinit(self.allocator);
        const json = try toJSON(self.allocator, response);
        return json;
    }

    pub fn getHTML(self: *@This()) ![]const u8 {
        _ = self;
        return @embedFile("index.html");
    }
};

pub const ValidatorInfo = struct {
    id: []const u8,
    stake: u64,
    voting_power: u64,
    is_active: bool,
};

pub fn extendHTTPServerWithDashboard(
    server: *anyopaque,
    allocator: std.mem.Allocator,
    node: *Node,
) !void {
    _ = server;
    _ = allocator;
    _ = node;
}
