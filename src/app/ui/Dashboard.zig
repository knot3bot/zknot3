//! Dashboard - Web UI dashboard with HTMX + Alpine.js

const std = @import("std");
const app = @import("../../app.zig");
const Node = app.Node;
const NodeStatsCoordinator = @import("../NodeStatsCoordinator.zig");
const core = @import("../../core.zig");
const NetworkConfig = @import("../Config.zig").NetworkConfig;

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
    next_cursor: ?u64 = null,
    has_more: bool = false,
};

pub const TransactionsResponse = struct {
    transactions: []TxnInfo,
    total: usize,
    next_cursor: ?[]const u8 = null,
    has_more: bool = false,
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

        const parsed_path = splitPathAndQuery(path);
        const route = parsed_path.path;
        const query = parsed_path.query;

        if (std.mem.eql(u8, route, "/api/node/info")) {
            return try toJSON(self.allocator, NodeInfoResponse.fromNode(node));
        } else if (std.mem.eql(u8, route, "/api/consensus/status")) {
            return try toJSON(self.allocator, ConsensusStatusResponse.fromNode(node));
        } else if (std.mem.eql(u8, route, "/api/txn/stats")) {
            return try toJSON(self.allocator, TxnStatsResponse.fromNode(node));
        } else if (std.mem.eql(u8, route, "/api/metrics")) {
            return try toJSON(self.allocator, TriSourceMetricsResponse.fromNode(node));
        } else if (std.mem.eql(u8, route, "/api/blocks")) {
            const limit = getQueryUsize(query, "limit") orelse 50;
            const cursor = getQueryU64(query, "cursor");
            return try self.handleBlocks(limit, cursor);
        } else if (std.mem.eql(u8, route, "/api/transactions")) {
            const limit = getQueryUsize(query, "limit") orelse 50;
            const cursor_hex = getQueryStr(query, "cursor");
            return try self.handleTransactions(limit, cursor_hex);
        } else if (std.mem.startsWith(u8, route, "/api/transactions/")) {
            const hash_hex = route["/api/transactions/".len..];
            return try self.handleTransactionDetail(hash_hex);
        } else if (std.mem.eql(u8, route, "/api/epoch")) {
            return try self.handleEpoch();
        } else if (std.mem.eql(u8, route, "/api/validators")) {
            return try self.handleValidators();
        } else if (std.mem.eql(u8, route, "/api/system/info")) {
            return try toJSON(self.allocator, SystemInfoResponse.fromNode(node));
        } else if (std.mem.eql(u8, route, "/api/events")) {
            const limit = getQueryUsize(query, "limit") orelse 50;
            const tx_hex = getQueryStr(query, "tx");
            return try self.handleEvents(limit, tx_hex);
        } else if (std.mem.eql(u8, route, "/api/objects")) {
            const limit = getQueryUsize(query, "limit") orelse 50;
            const owner_hex = getQueryStr(query, "owner");
            return try self.handleObjects(limit, owner_hex);
        } else if (std.mem.eql(u8, route, "/api/indexer/stats")) {
            return try self.handleIndexerStats();
        } else {
            return error.NotFound;
        }
    }

    const PathQuery = struct { path: []const u8, query: []const u8 };

    fn splitPathAndQuery(raw: []const u8) PathQuery {
        const qmark = std.mem.indexOfScalar(u8, raw, '?') orelse return .{ .path = raw, .query = "" };
        return .{ .path = raw[0..qmark], .query = raw[qmark + 1 ..] };
    }

    fn getQueryStr(query: []const u8, key: []const u8) ?[]const u8 {
        if (query.len == 0) return null;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const k = kv.next() orelse continue;
            const v = kv.next() orelse continue;
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }

    fn getQueryU64(query: []const u8, key: []const u8) ?u64 {
        const s = getQueryStr(query, key) orelse return null;
        return std.fmt.parseInt(u64, s, 10) catch null;
    }

    fn getQueryUsize(query: []const u8, key: []const u8) ?usize {
        const s = getQueryStr(query, key) orelse return null;
        return std.fmt.parseInt(usize, s, 10) catch null;
    }

    fn clampLimit(raw: usize) usize {
        const min = @as(usize, 1);
        const max = @as(usize, 500);
        return @min(max, @max(min, raw));
    }

    fn handleBlocks(self: *@This(), limit_raw: usize, cursor_round: ?u64) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;

        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        const limit = clampLimit(limit_raw);
        var blocks = try std.ArrayList(BlockInfo).initCapacity(self.allocator, @min(limit, 500));
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

        std.mem.sort(BlockInfo, blocks.items, {}, struct {
            fn lt(_: void, a: BlockInfo, b: BlockInfo) bool {
                return a.round > b.round;
            }
        }.lt);

        // Apply cursor: treat cursor as the last round from previous page; return items with round < cursor.
        var start: usize = 0;
        if (cursor_round) |c| {
            while (start < blocks.items.len and blocks.items[start].round >= c) : (start += 1) {}
        }
        const end = @min(blocks.items.len, start + limit);
        const page = blocks.items[start..end];

        const has_more = end < blocks.items.len;
        const next_cursor: ?u64 = if (has_more and page.len > 0) page[page.len - 1].round else null;

        const response = BlocksResponse{
            .blocks = page,
            .total = node.committed_blocks.count(),
            .next_cursor = next_cursor,
            .has_more = has_more,
        };
        const json = try toJSON(self.allocator, response);
        blocks.deinit(self.allocator);
        return json;
    }

    fn digestLtDesc(a: [32]u8, b: [32]u8) bool {
        // Descending lexicographic by bytes.
        return std.mem.order(u8, &a, &b) == .gt;
    }

    fn handleTransactions(self: *@This(), limit_raw: usize, cursor_hex: ?[]const u8) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;

        const limit = clampLimit(limit_raw);
        var txns = try std.ArrayList(TxnInfo).initCapacity(self.allocator, @min(limit, 500));
        var hex_strings = std.ArrayList([]u8).empty;
        defer {
            for (hex_strings.items) |s| self.allocator.free(s);
            hex_strings.deinit(self.allocator);
        }

        var cursor_digest: ?[32]u8 = null;
        if (cursor_hex) |hx| {
            if (hx.len == 64 or (hx.len == 66 and std.mem.startsWith(u8, hx, "0x"))) {
                const clean = if (std.mem.startsWith(u8, hx, "0x")) hx[2..] else hx;
                var tmp: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&tmp, clean) catch {};
                cursor_digest = tmp;
            }
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

        // Stable sort by digest desc (wire has no timestamp).
        std.mem.sort(TxnInfo, txns.items, {}, struct {
            fn lt(_: void, a: TxnInfo, b: TxnInfo) bool {
                var da: [32]u8 = .{0} ** 32;
                var db: [32]u8 = .{0} ** 32;
                _ = std.fmt.hexToBytes(&da, a.hash) catch {};
                _ = std.fmt.hexToBytes(&db, b.hash) catch {};
                return digestLtDesc(da, db);
            }
        }.lt);

        // Apply cursor: treat cursor as last digest from previous page; return items with digest < cursor in desc order.
        var start: usize = 0;
        if (cursor_digest) |c| {
            while (start < txns.items.len) : (start += 1) {
                var d: [32]u8 = .{0} ** 32;
                _ = std.fmt.hexToBytes(&d, txns.items[start].hash) catch {};
                // In desc order, skip until digest is strictly < cursor (i.e. order != .gt and != .eq)
                if (std.mem.order(u8, &d, &c) == .lt) break;
            }
        }
        const end = @min(txns.items.len, start + limit);
        const page = txns.items[start..end];
        const has_more = end < txns.items.len;
        const next_cursor: ?[]const u8 = if (has_more and page.len > 0) page[page.len - 1].hash else null;

        const response = TransactionsResponse{
            .transactions = page,
            .total = node.txn_history.count(),
            .next_cursor = next_cursor,
            .has_more = has_more,
        };
        const json = try toJSON(self.allocator, response);
        txns.deinit(self.allocator);
        return json;
    }

    fn handleTransactionDetail(self: *@This(), hash_hex: []const u8) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;
        if (hash_hex.len != 64 and !(hash_hex.len == 66 and std.mem.startsWith(u8, hash_hex, "0x"))) return error.NotFound;
        const clean = if (std.mem.startsWith(u8, hash_hex, "0x")) hash_hex[2..] else hash_hex;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, clean) catch return error.NotFound;

        const receipt = node.getTransactionReceipt(digest);
        const exec = node.getExecutionResult(digest);

        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        return try toJSON(self.allocator, .{
            .hash = clean,
            .receipt = if (receipt) |r| .{
                .status = @tagName(r.status),
                .gas_used = r.gas_used,
                .sender = try bytesToHex(self.allocator, &r.sender),
            } else null,
            .execution_result = if (exec) |e| .{
                .status = @tagName(e.status),
                .gas_used = e.gas_used,
                .output_len = e.output.len,
            } else null,
            .raw_tx = null,
            .note = "raw tx is not retained in node memory today; receipt/execution_result only",
            .server_time = now,
        });
    }

    fn decodeHex32(hx: []const u8) ?[32]u8 {
        const clean = if (std.mem.startsWith(u8, hx, "0x")) hx[2..] else hx;
        if (clean.len != 64) return null;
        var out: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, clean) catch return null;
        return out;
    }

    fn handleEpoch(self: *@This()) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;

        if (node.deps.epoch_bridge) |_| {
            const epoch = node.getEpochInfo();
            return try toJSON(self.allocator, .{
                .epoch_number = epoch.epoch_number,
                .total_stake = epoch.total_stake,
                .validator_count = @as(u32, @intCast(epoch.validator_count)),
                .quorum_threshold = epoch.quorum_threshold,
                .needs_reconfiguration = node.needsReconfiguration(),
                .source = "epoch_bridge",
            });
        }

        // Fallback: compute from static known validators in config.
        var total: u128 = 0;
        for (node.config.network.known_validators) |kv| total += @as(u128, kv.stake);
        const quorum: u128 = if (total == 0) 0 else ((2 * total + 2) / 3) + 1;
        return try toJSON(self.allocator, .{
            .epoch_number = @as(u64, 0),
            .total_stake = total,
            .validator_count = @as(u32, @intCast(node.config.network.known_validators.len)),
            .quorum_threshold = quorum,
            .needs_reconfiguration = node.needsReconfiguration(),
            .source = "config_known_validators",
        });
    }

    fn handleValidators(self: *@This()) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;

        // Connected peers (Ed25519 public keys in handshake sender field).
        var connected = std.AutoArrayHashMapUnmanaged([32]u8, void).empty;
        defer connected.deinit(self.allocator);
        if (node.getP2PServer()) |p2p| {
            const ids = try p2p.getPeerIDs();
            defer self.allocator.free(ids);
            for (ids) |id| try connected.put(self.allocator, id, {});
        }

        var list = std.ArrayList(ValidatorInfoV2).empty;
        defer list.deinit(self.allocator);

        var total_stake: u128 = 0;
        // Phase 0: prefer dynamic stake from epoch_bridge / mainnet_hooks when available.
        const use_dynamic_stake = true;
        for (node.config.network.known_validators) |kv| {
            const pk = decodeHex32(kv.public_key_hex) orelse continue;
            const dynamic_stake = if (use_dynamic_stake) node.getM4ValidatorStake(pk) else kv.stake;
            total_stake += @as(u128, dynamic_stake);
        }

        for (node.config.network.known_validators) |kv| {
            const pk = decodeHex32(kv.public_key_hex) orelse continue;
            const id_hex = try bytesToHex(self.allocator, &pk);
            const dynamic_stake = if (use_dynamic_stake) node.getM4ValidatorStake(pk) else kv.stake;
            const stake_pct: f64 = if (total_stake == 0) 0 else @as(f64, @floatFromInt(dynamic_stake)) / @as(f64, @floatFromInt(total_stake));
            try list.append(self.allocator, .{
                .id = id_hex,
                .name = kv.name,
                .stake = dynamic_stake,
                .stake_pct = stake_pct,
                .voting_power = dynamic_stake,
                .is_active = dynamic_stake > 0,
                .is_connected = connected.contains(pk),
            });
        }

        const quorum_threshold: u128 = if (total_stake == 0) 0 else ((2 * total_stake + 2) / 3) + 1;

        const response = .{
            .validators = list.items,
            .total = list.items.len,
            .total_stake = total_stake,
            .quorum_threshold = quorum_threshold,
        };
        return try toJSON(self.allocator, response);
    }

    fn handleEvents(self: *@This(), limit_raw: usize, tx_hex: ?[]const u8) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;
        const limit = clampLimit(limit_raw);
        var events_out = std.ArrayList(struct {
            tx_digest: []const u8,
            event_type: []const u8,
            timestamp: i64,
        }).empty;
        defer events_out.deinit(self.allocator);

        if (node.deps.indexer) |idx| {
            var query = @import("../../app/Indexer.zig").EventQuery{};
            if (tx_hex) |hx| {
                if (hx.len == 64 or (hx.len == 66 and std.mem.startsWith(u8, hx, "0x"))) {
                    const clean = if (std.mem.startsWith(u8, hx, "0x")) hx[2..] else hx;
                    var d: [32]u8 = undefined;
                    _ = std.fmt.hexToBytes(&d, clean) catch {};
                    query.transaction_digest = d;
                }
            }
            const result = try idx.queryEvents(query, null, limit);
            // result.data is a pointer to an ArrayList of IndexedEvent
            const evts = @as(*std.ArrayList(@import("../../app/Indexer.zig").IndexedEvent), @ptrCast(@alignCast(@constCast(result.data))));
            defer evts.deinit();
            for (evts.items) |evt| {
                const tx_d = try bytesToHex(self.allocator, &evt.transaction_digest);
                try events_out.append(self.allocator, .{
                    .tx_digest = tx_d,
                    .event_type = evt.event_type,
                    .timestamp = evt.timestamp,
                });
            }
        }

        return try toJSON(self.allocator, .{
            .events = events_out.items,
            .total = events_out.items.len,
        });
    }

    fn handleObjects(self: *@This(), limit_raw: usize, owner_hex: ?[]const u8) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;
        const limit = clampLimit(limit_raw);
        var objects_out = std.ArrayList(struct {
            id: []const u8,
            version: u64,
            object_type: []const u8,
        }).empty;
        defer objects_out.deinit(self.allocator);

        if (node.deps.indexer) |idx| {
            var query = @import("../../app/Indexer.zig").ObjectQuery{};
            if (owner_hex) |hx| {
                if (hx.len == 64 or (hx.len == 66 and std.mem.startsWith(u8, hx, "0x"))) {
                    const clean = if (std.mem.startsWith(u8, hx, "0x")) hx[2..] else hx;
                    var d: [32]u8 = undefined;
                    _ = std.fmt.hexToBytes(&d, clean) catch {};
                    query.owner = d;
                }
            }
            const result = try idx.queryObjects(query, null, limit);
            const ids = @as(*std.ArrayList(@import("../../core.zig").ObjectID), @ptrCast(@alignCast(@constCast(result.data))));
            defer ids.deinit();
            for (ids.items) |id| {
                if (idx.getObject(id)) |obj| {
                    const id_h = try bytesToHex(self.allocator, id.asBytes());
                    try objects_out.append(self.allocator, .{
                        .id = id_h,
                        .version = obj.version.seq,
                        .object_type = obj.type,
                    });
                }
            }
        }

        return try toJSON(self.allocator, .{
            .objects = objects_out.items,
            .total = objects_out.items.len,
        });
    }

    fn handleIndexerStats(self: *@This()) ![]u8 {
        if (self.node == null) return error.NodeNotSet;
        const node = self.node.?;
        const stats = if (node.deps.indexer) |idx| idx.stats() else @import("../../app/Indexer.zig").IndexerStats{
            .object_count = 0,
            .event_count = 0,
            .indexed_objects = 0,
            .indexed_events = 0,
        };
        return try toJSON(self.allocator, stats);
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

pub const ValidatorInfoV2 = struct {
    id: []const u8,
    name: []const u8,
    stake: u64,
    stake_pct: f64,
    voting_power: u64,
    is_active: bool,
    is_connected: bool,
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
