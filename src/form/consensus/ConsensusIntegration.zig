//! ConsensusIntegration - Wires P2P networking to Mysticeti consensus

const std = @import("std");
const Node = @import("../../app/Node.zig").Node;
const P2PServer = @import("../network/P2PServer.zig").P2PServer;
const Mysticeti = @import("Mysticeti.zig");
const Message = @import("../network/Transport.zig").Message;
const Log = @import("../../app/Log.zig");
const CommitCoordinator = @import("../../app/CommitCoordinator.zig");

pub const ConsensusIntegration = struct {
    allocator: std.mem.Allocator,
    node: *Node,
    p2p_server: *P2PServer,
    validator_id: [32]u8,
    validator_key: [32]u8,
    validator_index: usize,
    last_round_advance: i64,
    last_proposed_round: u64,
    round_interval_secs: i64 = 2,
    peer_scan_cursor: usize = 0,
    max_messages_per_tick: usize = 256,
    max_block_messages_per_tick: usize = 64,
    max_vote_messages_per_tick: usize = 128,
    max_certificate_messages_per_tick: usize = 32,
    max_transaction_messages_per_tick: usize = 32,
    per_peer_batch_limit: usize = 4,

    pending_tx_medium_threshold: usize = 256,
    pending_tx_high_threshold: usize = 2048,
    medium_tx_budget_boost: usize = 24,
    high_tx_budget_boost: usize = 48,
    near_round_vote_budget_boost: usize = 24,
    near_round_certificate_budget_boost: usize = 16,
    near_round_block_budget_boost: usize = 8,

    min_block_messages_per_tick: usize = 32,
    min_vote_messages_per_tick: usize = 64,
    min_certificate_messages_per_tick: usize = 16,
    min_transaction_messages_per_tick: usize = 8,

    /// Adaptive commit-drain sizing. Shrinks during idle ticks so the commit
    /// loop does not redundantly sweep the pending map, and grows during
    /// bursts so we can drain the full backlog in a single tick without
    /// starving the rest of the main loop.
    commit_batch: CommitCoordinator.AdaptiveBatchState = CommitCoordinator.AdaptiveBatchState.init(4, 1, 256),
    /// Last observed drain count; exposed for metrics / tests.
    last_commit_drain: usize = 0,
    quarantined_peers: std.AutoArrayHashMapUnmanaged([32]u8, i64) = .empty,
    equivocation_events: u64 = 0,
    /// Deferred commit flag. Set when a vote/block suggests a commit may be
    /// possible; cleared by `maybeCommit` in the main loop. Prevents the
    /// heavy commit path from blocking P2P message processing.
    should_commit: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        node: *Node,
        p2p_server: *P2PServer,
        validator_id: [32]u8,
        validator_key: [32]u8,
        validator_index: usize,
    ) !*Self {
        const self_ptr = try allocator.create(Self);
        errdefer allocator.destroy(self_ptr);
        const cc = node.config.consensus;
        self_ptr.* = .{
            .allocator = allocator,
            .node = node,
            .p2p_server = p2p_server,
            .validator_id = validator_id,
            .validator_key = validator_key,
            .validator_index = validator_index,
            .last_round_advance = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .last_proposed_round = 0,
            .peer_scan_cursor = 0,
            .max_messages_per_tick = cc.max_messages_per_tick,
            .max_block_messages_per_tick = cc.max_block_messages_per_tick,
            .max_vote_messages_per_tick = cc.max_vote_messages_per_tick,
            .max_certificate_messages_per_tick = cc.max_certificate_messages_per_tick,
            .max_transaction_messages_per_tick = cc.max_transaction_messages_per_tick,
            .per_peer_batch_limit = cc.per_peer_batch_limit,
            .pending_tx_medium_threshold = cc.pending_tx_medium_threshold,
            .pending_tx_high_threshold = cc.pending_tx_high_threshold,
            .medium_tx_budget_boost = cc.medium_tx_budget_boost,
            .high_tx_budget_boost = cc.high_tx_budget_boost,
            .near_round_vote_budget_boost = cc.near_round_vote_budget_boost,
            .near_round_certificate_budget_boost = cc.near_round_certificate_budget_boost,
            .near_round_block_budget_boost = cc.near_round_block_budget_boost,
            .min_block_messages_per_tick = cc.min_block_messages_per_tick,
            .min_vote_messages_per_tick = cc.min_vote_messages_per_tick,
            .min_certificate_messages_per_tick = cc.min_certificate_messages_per_tick,
            .min_transaction_messages_per_tick = cc.min_transaction_messages_per_tick,
        };
        return self_ptr;
    }

    pub fn deinit(self: *Self) void {
        self.quarantined_peers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn onBlockReceived(self: *Self, peer_id: [32]u8, block_data: []const u8) !void {
        Log.debug("consensus_event=block_received peer_prefix={} payload_bytes={}", .{
            peer_id[0], block_data.len,
        });

        var block = Mysticeti.Block.deserialize(self.allocator, block_data) catch {
            Log.err("Failed to deserialize block", .{});
            return;
        };
        defer block.deinit(self.allocator);

        try self.node.receiveBlock(block_data);
        try self.createAndBroadcastVote(&block);
    }

    pub fn onVoteReceived(self: *Self, peer_id: [32]u8, vote_data: []const u8) !void {
        Log.debug("consensus_event=vote_received peer_prefix={} payload_bytes={}", .{
            peer_id[0], vote_data.len,
        });

        if (self.isPeerQuarantined(peer_id)) {
            Log.warn("Dropping vote from quarantined peer", .{});
            return;
        }

        const result = try self.node.receiveVote(vote_data);
        switch (result) {
            .accepted, .duplicate, .ignored_invalid => {},
            .equivocation => |evidence| {
                self.equivocation_events += 1;
                try self.quarantinePeer(peer_id);
                const ev_bytes = try evidence.serialize(self.allocator);
                defer self.allocator.free(ev_bytes);
                // Reuse certificate channel for evidence gossip in testnet phase.
                try self.p2p_server.broadcastCertificate(self.validator_id, ev_bytes);

                // Execute slash intent through M4 hooks exactly once per
                // evidence digest (prevents replay-slash amplification).
                _ = self.node.applyEquivocationEvidence(
                    evidence.voter,
                    evidence.voter,
                    evidence.round.value,
                    ev_bytes,
                    @max(@as(u64, 1), self.node.config.consensus.min_validator_stake / 100), // 1% floor slash
                ) catch |err| {
                    Log.err("consensus_event=equivocation_slash_failed error={s}", .{@errorName(err)});
                    return err;
                };
                Log.warn("consensus_event=equivocation_detected peer_prefix={} round={} action=quarantine_broadcast", .{
                    peer_id[0], evidence.round.value,
                });
            },
        }
        self.should_commit = true;
    }

    pub fn onCertificateReceived(_self: *Self, _: [32]u8, _: []const u8) !void {
        _ = _self;
        Log.debug("Received certificate from peer", .{});
    }

    pub fn onPeerConnected(self: *Self, peer_id: [32]u8) void {
        Log.info("Peer connected, total peers: {}", .{
            self.p2p_server.peerCount(),
            self.p2p_server.peerCount(),
        });
        _ = peer_id;
    }

    pub fn onPeerDisconnected(self: *Self, peer_id: [32]u8) void {
        Log.info("Peer disconnected, remaining peers: {}", .{
            self.p2p_server.peerCount(),
            self.p2p_server.peerCount(),
        });
        _ = peer_id;
    }

    fn createAndBroadcastVote(self: *Self, block: *const Mysticeti.Block) !void {
        const stake: u128 = 1000;

        var message: [40]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], block.round.value, .big);
        @memcpy(message[8..40], &block.digest);
        const sig = try @import("../../property/Signature.zig").Ed25519.sign(self.validator_key, &message);

        const vote = Mysticeti.Vote{
            .voter = self.validator_id,
            .stake = stake,
            .round = block.round,
            .block_digest = block.digest,
            .signature = sig,
        };

        const vote_data = try vote.serialize(self.allocator);
        defer self.allocator.free(vote_data);

        try self.p2p_server.broadcastVote(self.validator_id, vote_data);
        _ = try self.node.receiveVote(vote_data);
        Log.debug("Broadcast vote for block", .{});
    }

    /// Adaptive commit drain: asks `Node` for up to `commit_batch.current`
    /// certificates in a single call, then feeds the observed drain count back
    /// into the AIMD state. At low QPS this quickly shrinks the window so the
    /// idle path costs one short pending-map scan and no fsync-backed work;
    /// under bursts it opens up to 256 blocks/tick without per-certificate
    /// scheduler hops.
    fn tryCommit(self: *Self) !void {
        const CertCtx = struct { self: *Self };
        var cctx = CertCtx{ .self = self };
        const onCert = struct {
            fn call(raw: *anyopaque, cert: Mysticeti.CommitCertificate) anyerror!void {
                const c = @as(*CertCtx, @ptrCast(@alignCast(raw)));
                Log.info("consensus_event=commit_success round={} quorum_stake={} drain_budget={}", .{
                    cert.round.value, cert.quorum_stake, c.self.commit_batch.currentBudget(),
                });
                const cert_data = try cert.serialize(c.self.allocator);
                defer c.self.allocator.free(cert_data);
            }
        }.call;

        const budget = self.commit_batch.currentBudget();
        const drained = self.node.tryCommitBlocksBatch(budget, &cctx, onCert) catch |err| blk: {
            Log.err("tryCommitBlocksBatch error: {s}", .{@errorName(err)});
            break :blk 0;
        };
        self.last_commit_drain = drained;
        _ = self.commit_batch.observe(drained);
    }

    /// Run the deferred commit path if `should_commit` was set during message
    /// processing or proposal. Called from the main loop so heavy commit work
    /// does not block P2P recv.
    pub fn maybeCommit(self: *Self) void {
        if (!self.should_commit) return;
        self.should_commit = false;
        self.tryCommit() catch |err| {
            Log.err("maybeCommit tryCommit error: {s}", .{@errorName(err)});
        };
    }

    pub fn checkAndPropose(self: *Self) !void {
        if (!self.node.isRunning()) return;

        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };

            if (now - self.last_round_advance >= self.node.config.consensus.round_interval_secs) {
            self.node.advanceRound();
            self.last_round_advance = now;
            Log.info("Advanced to round {}", .{self.node.consensus_round});
        }

        if (self.isProposer()) {
            // Prevent multiple proposals in the same round
            if (self.node.consensus_round <= self.last_proposed_round) {
                return;
            }

            var payload = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
            defer payload.deinit(self.allocator);

            const max_txs_per_block = self.node.config.consensus.max_txs_per_block;
            var tx_count: u32 = 0;
            while (tx_count < max_txs_per_block) {
                if (self.node.txn_pool.next()) |tx| {
                    try payload.appendSlice(self.allocator, tx.sender[0..]);
                    tx_count += 1;
                } else {
                    break;
                }
            }

            Log.info("Proposed block with {} transactions", .{tx_count});

            const block = try self.node.proposeBlock(payload.items);
            if (block) |b| {
                self.last_proposed_round = self.node.consensus_round;
                Log.info("Proposed block at round {} with {} TXs", .{
                    b.round.value, tx_count,
                });

                const block_data = try b.serialize(self.allocator);
                defer self.allocator.free(block_data);

                try self.p2p_server.broadcastBlock(self.validator_id, block_data);

                // Self-vote to ensure block can be committed even without peers
                try self.createAndBroadcastVote(b);
                self.should_commit = true;
            }
        }
    }
    fn isProposer(self: *Self) bool {
        const validator_count: u64 = @intCast(self.node.config.consensus.min_validators);
        return (self.node.consensus_round % validator_count) == self.validator_index;
    }

    pub fn processPeerMessages(self: *Self) !usize {
        var dead_peers: std.ArrayList([32]u8) = .empty;
        defer dead_peers.deinit(self.allocator);
        var processed_messages: usize = 0;
        const total_peers = self.p2p_server.peers.count() + self.p2p_server.quic_peers.count();
        if (total_peers == 0) return 0;

        var peer_ids: std.ArrayList([32]u8) = .empty;
        defer peer_ids.deinit(self.allocator);

        var it_collect = self.p2p_server.peers.iterator();
        while (it_collect.next()) |entry| {
            try peer_ids.append(self.allocator, entry.key_ptr.*);
        }
        var qit_collect = self.p2p_server.quic_peers.iterator();
        while (qit_collect.next()) |entry| {
            try peer_ids.append(self.allocator, entry.key_ptr.*);
        }
        if (peer_ids.items.len == 0) return 0;

        var readable_peers: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty;
        defer readable_peers.deinit(self.allocator);
        var dead_peer_set: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty;
        defer dead_peer_set.deinit(self.allocator);

        if (self.p2p_server.config.transport_type == .tcp) {
            var poll_fds: std.ArrayList(std.posix.pollfd) = .empty;
            defer poll_fds.deinit(self.allocator);

            for (peer_ids.items) |peer_id| {
                const peer_conn = self.p2p_server.peers.getPtr(peer_id) orelse continue;
                try poll_fds.append(self.allocator, .{
                    .fd = peer_conn.*.conn.socket.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
            }
            if (poll_fds.items.len == 0) return 0;

            const ready_count = std.posix.poll(poll_fds.items, 0) catch 0;
            if (ready_count <= 0) return 0;

            for (poll_fds.items, 0..) |pfd, idx| {
                const peer_id = peer_ids.items[idx];
                if ((pfd.revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
                    try dead_peer_set.put(self.allocator, peer_id, {});
                    continue;
                }
                if ((pfd.revents & std.posix.POLL.IN) != 0) {
                    try readable_peers.put(self.allocator, peer_id, {});
                }
            }
        } else {
            for (peer_ids.items) |peer_id| {
                try readable_peers.put(self.allocator, peer_id, {});
            }
        }

        const start = if (peer_ids.items.len == 0) 0 else self.peer_scan_cursor % peer_ids.items.len;
        self.peer_scan_cursor +%= 1;
        const per_peer_batch_limit: usize = self.per_peer_batch_limit;
        var remaining_block_budget: usize = 0;
        var remaining_vote_budget: usize = 0;
        var remaining_certificate_budget: usize = 0;
        var remaining_transaction_budget: usize = 0;
        self.computeDynamicBudgets(
            &remaining_block_budget,
            &remaining_vote_budget,
            &remaining_certificate_budget,
            &remaining_transaction_budget,
        );

        outer: for (0..peer_ids.items.len) |offset| {
            const idx = (start + offset) % peer_ids.items.len;
            const peer_id = peer_ids.items[idx];
            if (dead_peer_set.contains(peer_id)) continue;
            if (self.isPeerQuarantined(peer_id)) continue;
            if (!readable_peers.contains(peer_id)) continue;

            var peer_dead = false;
            for (0..per_peer_batch_limit) |_| {
                if (processed_messages >= self.max_messages_per_tick) break :outer;

                // Re-validate peer before each recv in case map mutated during callbacks.
                // Try TCP peers first, then QUIC peers.
                const msg = blk: {
                    if (self.p2p_server.peers.getPtr(peer_id)) |peer| {
                        break :blk peer.*.recvMessage() catch |err| switch (err) {
                            error.WouldBlock => break,
                            else => {
                                peer_dead = true;
                                break;
                            },
                        };
                    }
                    if (self.p2p_server.quic_peers.getPtr(peer_id)) |peer| {
                        break :blk peer.*.recvMessage() catch |err| switch (err) {
                            error.WouldBlock => break,
                            else => {
                                peer_dead = true;
                                break;
                            },
                        };
                    }
                    break;
                };
                if (msg) |m| {
                    defer self.allocator.free(m.payload);
                    if (!self.p2p_server.allowIncomingMessage(peer_id, m.msg_type)) {
                        if (self.p2p_server.isPeerBanned(peer_id)) {
                            peer_dead = true;
                        }
                        continue;
                    }
                    if (self.consumeMessageBudget(
                        m.msg_type,
                        &remaining_block_budget,
                        &remaining_vote_budget,
                        &remaining_certificate_budget,
                        &remaining_transaction_budget,
                    )) {
                        try self.handleMessage(peer_id, m);
                        processed_messages += 1;
                    }
                } else {
                    // EOF
                    peer_dead = true;
                    break;
                }
            }

            if (peer_dead and !dead_peer_set.contains(peer_id)) {
                try dead_peer_set.put(self.allocator, peer_id, {});
            }
        }

        var it_dead = dead_peer_set.iterator();
        while (it_dead.next()) |entry| {
            try dead_peers.append(self.allocator, entry.key_ptr.*);
        }

        for (dead_peers.items) |peer_id| {
            self.p2p_server.disconnectPeer(peer_id);
        }
        return processed_messages;
    }

    fn computeDynamicBudgets(
        self: *Self,
        remaining_block_budget: *usize,
        remaining_vote_budget: *usize,
        remaining_certificate_budget: *usize,
        remaining_transaction_budget: *usize,
    ) void {
        // Base per-tick budgets
        var block_budget = self.max_block_messages_per_tick;
        var vote_budget = self.max_vote_messages_per_tick;
        var cert_budget = self.max_certificate_messages_per_tick;
        var tx_budget = self.max_transaction_messages_per_tick;

        const min_block: usize = self.min_block_messages_per_tick;
        const min_vote: usize = self.min_vote_messages_per_tick;
        const min_cert: usize = self.min_certificate_messages_per_tick;
        const min_tx: usize = self.min_transaction_messages_per_tick;

        const tx_stats = self.node.getTxnPoolStats();
        const pending = tx_stats.pending;

        const now = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            break :blk ts.sec;
        };
        const round_age = if (now >= self.last_round_advance) now - self.last_round_advance else 0;
        const near_round_boundary = self.node.config.consensus.round_interval_secs > 0 and
            (round_age + 1 >= self.node.config.consensus.round_interval_secs);

        // Dynamic budget shift based on mempool pressure
        if (pending >= self.pending_tx_high_threshold) {
            tx_budget += self.high_tx_budget_boost;
            vote_budget = saturatingSub(vote_budget, 24, min_vote);
            cert_budget = saturatingSub(cert_budget, 8, min_cert);
            block_budget = saturatingSub(block_budget, 16, min_block);
        } else if (pending >= self.pending_tx_medium_threshold) {
            tx_budget += self.medium_tx_budget_boost;
            vote_budget = saturatingSub(vote_budget, 12, min_vote);
            cert_budget = saturatingSub(cert_budget, 4, min_cert);
            block_budget = saturatingSub(block_budget, 8, min_block);
        } else {
            vote_budget += 16;
            cert_budget += 8;
            tx_budget = saturatingSub(tx_budget, 16, min_tx);
        }

        // Near round boundary, prioritize consensus progress.
        if (near_round_boundary) {
            vote_budget += self.near_round_vote_budget_boost;
            cert_budget += self.near_round_certificate_budget_boost;
            block_budget += self.near_round_block_budget_boost;
            tx_budget = saturatingSub(tx_budget, 24, min_tx);
        }

        // Ensure total budget stays within configured cap.
        const total_budget = block_budget + vote_budget + cert_budget + tx_budget;
        if (total_budget > self.max_messages_per_tick) {
            var overflow = total_budget - self.max_messages_per_tick;
            overflow = reduceBudgetBy(&tx_budget, min_tx, overflow);
            overflow = reduceBudgetBy(&block_budget, min_block, overflow);
            overflow = reduceBudgetBy(&vote_budget, min_vote, overflow);
            _ = reduceBudgetBy(&cert_budget, min_cert, overflow);
        }

        remaining_block_budget.* = block_budget;
        remaining_vote_budget.* = vote_budget;
        remaining_certificate_budget.* = cert_budget;
        remaining_transaction_budget.* = tx_budget;
    }

    fn saturatingSub(value: usize, delta: usize, floor: usize) usize {
        if (value <= floor) return floor;
        const reduced = if (value > delta) value - delta else 0;
        if (reduced < floor) return floor;
        return reduced;
    }

    fn reduceBudgetBy(budget: *usize, floor: usize, overflow: usize) usize {
        if (overflow == 0) return 0;
        if (budget.* <= floor) return overflow;

        const reducible = budget.* - floor;
        if (overflow >= reducible) {
            budget.* = floor;
            return overflow - reducible;
        }
        budget.* -= overflow;
        return 0;
    }

    fn consumeMessageBudget(
        self: *Self,
        msg_type: @import("../network/Transport.zig").MessageType,
        remaining_block_budget: *usize,
        remaining_vote_budget: *usize,
        remaining_certificate_budget: *usize,
        remaining_transaction_budget: *usize,
    ) bool {
        _ = self;
        switch (msg_type) {
            .block => {
                if (remaining_block_budget.* == 0) return false;
                remaining_block_budget.* -= 1;
                return true;
            },
            .consensus => {
                if (remaining_vote_budget.* == 0) return false;
                remaining_vote_budget.* -= 1;
                return true;
            },
            .certificate => {
                if (remaining_certificate_budget.* == 0) return false;
                remaining_certificate_budget.* -= 1;
                return true;
            },
            .transaction => {
                if (remaining_transaction_budget.* == 0) return false;
                remaining_transaction_budget.* -= 1;
                return true;
            },
            else => return true,
        }
    }

    fn handleMessage(self: *Self, peer_id: [32]u8, msg: Message) !void {
        switch (msg.msg_type) {
            .block => try self.onBlockReceived(peer_id, msg.payload),
            .consensus => try self.onVoteReceived(peer_id, msg.payload),
            .certificate => try self.onCertificateReceived(peer_id, msg.payload),
            .transaction => {
                Log.debug("Received transaction from peer", .{});
            },
            else => {
                Log.warn("Received unknown message type", .{});
            },
        }
    }

    fn isPeerQuarantined(self: *Self, peer_id: [32]u8) bool {
        return self.quarantined_peers.contains(peer_id);
    }

    fn quarantinePeer(self: *Self, peer_id: [32]u8) !void {
        const now = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            break :blk ts.sec;
        };
        try self.quarantined_peers.put(self.allocator, peer_id, now);
        self.p2p_server.disconnectPeer(peer_id);
    }
};
