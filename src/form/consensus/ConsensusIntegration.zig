//! ConsensusIntegration - Wires P2P networking to Mysticeti consensus

const std = @import("std");
const Node = @import("../../app/Node.zig").Node;
const P2PServer = @import("../network/P2PServer.zig").P2PServer;
const Mysticeti = @import("Mysticeti.zig");
const Message = @import("../network/Transport.zig").Message;
const Log = @import("../../app/Log.zig");
const CommitCoordinator = @import("../../app/CommitCoordinator.zig");

/// Read errors that mean "nothing available right now", not "peer is gone".
/// These must never evict a peer: the socket is healthy, we simply raced the
/// sender.
fn isTransientReadError(err: anyerror) bool {
    return switch (err) {
        error.WouldBlock, error.Unexpected => true,
        else => false,
    };
}

/// Read errors that mean the connection can no longer carry framed messages.
/// Only these may evict a peer.
///
/// `WouldBlock` is transient, and a short read is not fatal: `readSliceShort`
/// only returns a short count at end of stream, which `recvMessage` surfaces as
/// EOF (a null message) rather than as an error.
fn isFatalPeerError(err: anyerror) bool {
    return switch (err) {
        error.EndOfStream,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        // A peer that sends a frame we cannot parse is either broken or hostile.
        // Either way the stream is no longer trustworthy, so drop it rather than
        // keep accepting whatever it sends next.
        error.UnknownMessageType,
        error.MessageTooShort,
        error.MessageTooLarge,
        error.InvalidMessage,
        error.IncompleteHeader,
        error.IncompletePayload,
        => true,
        else => false,
    };
}

/// Recent equivocation wire payloads retained for peers that missed the
/// first gossip. One slot is rebroadcast per elapsed interval.
pub const evidence_ring_cap: usize = 16;
pub const default_equivocation_rebroadcast_interval_secs: i64 = 30;

pub const EvidencePick = struct {
    index: usize,
    next_cursor: usize,
};

/// Chooses at most one occupied ring slot.
/// `interval_secs == 0` disables rebroadcast. Does not allocate or send.
pub fn nextEvidence(
    count: usize,
    cursor: usize,
    last_sent_secs: i64,
    now_secs: i64,
    interval_secs: i64,
) ?EvidencePick {
    if (interval_secs == 0 or count == 0) return null;
    if (now_secs -| last_sent_secs < interval_secs) return null;
    return .{
        .index = cursor % count,
        .next_cursor = cursor +% 1,
    };
}

pub const EquivocationEvidenceRing = struct {
    slots: [evidence_ring_cap]?[]u8 = @as([evidence_ring_cap]?[]u8, @splat(null)),
    count: usize = 0,
    cursor: usize = 0,
    /// Next physical slot replaced once the ring is full.
    evict_at: usize = 0,
    last_sent_secs: i64 = 0,
    /// Invoked after a new payload is stored or an old one is evicted.
    /// Duplicate inserts do not call it. `loadFromFile` does not call it.
    on_changed: ?*const fn (*anyopaque) void = null,
    on_changed_ctx: ?*anyopaque = null,

    /// Takes ownership of `payload`. Frees it when an equal payload is already
    /// stored, and returns the bytes that remain in the ring.
    pub fn insert(self: *EquivocationEvidenceRing, allocator: std.mem.Allocator, payload: []u8) []u8 {
        return self.insertOwned(allocator, payload, true);
    }

    fn insertOwned(self: *EquivocationEvidenceRing, allocator: std.mem.Allocator, payload: []u8, notify: bool) []u8 {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const existing = self.slots[i] orelse continue;
            if (std.mem.eql(u8, existing, payload)) {
                allocator.free(payload);
                return existing;
            }
        }
        if (self.count < evidence_ring_cap) {
            self.slots[self.count] = payload;
            self.count += 1;
            if (notify) self.fireChanged();
            return payload;
        }
        const idx = self.evict_at % evidence_ring_cap;
        if (self.slots[idx]) |old| allocator.free(old);
        self.slots[idx] = payload;
        self.evict_at +%= 1;
        if (notify) self.fireChanged();
        return payload;
    }

    fn fireChanged(self: *EquivocationEvidenceRing) void {
        const cb = self.on_changed orelse return;
        const ctx = self.on_changed_ctx orelse return;
        cb(ctx);
    }

    pub fn deinit(self: *EquivocationEvidenceRing, allocator: std.mem.Allocator) void {
        for (self.slots[0..self.count]) |slot| {
            if (slot) |bytes| allocator.free(bytes);
        }
        self.* = .{};
    }

    /// `{m4_base}.equiv.ring`: `k3eq01` + u8 count + repeated `u32be len || bytes`.
    /// Temp file, fsync, then rename. Count is at most `evidence_ring_cap`.
    pub fn saveToFile(self: EquivocationEvidenceRing, allocator: std.mem.Allocator, path: []const u8) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        try body.appendSlice(allocator, "k3eq01");
        const count_at = body.items.len;
        try body.append(allocator, 0);
        var written: u8 = 0;
        var i: usize = 0;
        while (i < self.count and i < evidence_ring_cap) : (i += 1) {
            const bytes = self.slots[i] orelse continue;
            var lenb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lenb, @intCast(bytes.len), .big);
            try body.appendSlice(allocator, &lenb);
            try body.appendSlice(allocator, bytes);
            written += 1;
        }
        body.items[count_at] = written;

        const io = @import("io_instance").io;
        const cwd = std.Io.Dir.cwd();
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp_path);
        {
            const file = try cwd.createFile(io, tmp_path, .{ .truncate = true });
            defer file.close(io);
            errdefer cwd.deleteFile(io, tmp_path) catch {};
            try file.writeStreamingAll(io, body.items);
            try file.sync(io);
        }
        cwd.rename(tmp_path, cwd, path, io) catch |err| {
            cwd.deleteFile(io, tmp_path) catch {};
            return err;
        };
    }

    /// Loads payloads into this ring. A bad magic or a short file leaves the ring
    /// unchanged. A truncated length returns `error.InvalidEvidenceRing` before
    /// any insert. More than 16 entries keep the last 16. A missing file is
    /// `error.FileNotFound`.
    pub fn loadFromFile(self: *EquivocationEvidenceRing, allocator: std.mem.Allocator, path: []const u8) !void {
        const io = @import("io_instance").io;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            std.Io.Limit.limited(2 * 1024 * 1024),
        );
        defer allocator.free(bytes);
        if (bytes.len < 7 or !std.mem.eql(u8, bytes[0..6], "k3eq01")) return;
        const declared: usize = bytes[6];
        var parsed: std.ArrayList([]u8) = .empty;
        errdefer {
            for (parsed.items) |item| allocator.free(item);
            parsed.deinit(allocator);
        }
        var off: usize = 7;
        var n: usize = 0;
        while (n < declared) : (n += 1) {
            if (off + 4 > bytes.len) return error.InvalidEvidenceRing;
            const len = std.mem.readInt(u32, bytes[off..][0..4], .big);
            off += 4;
            if (len > 1024 * 1024 or off + len > bytes.len) return error.InvalidEvidenceRing;
            const copy = try allocator.dupe(u8, bytes[off..][0..len]);
            errdefer allocator.free(copy);
            try parsed.append(allocator, copy);
            off += len;
        }
        const start = if (parsed.items.len > evidence_ring_cap)
            parsed.items.len - evidence_ring_cap
        else
            0;
        var drop: usize = 0;
        while (drop < start) : (drop += 1) allocator.free(parsed.items[drop]);
        var keep: usize = start;
        while (keep < parsed.items.len) : (keep += 1) {
            _ = self.insertOwned(allocator, parsed.items[keep], false);
        }
        parsed.deinit(allocator);
    }
};

/// Sends every occupied ring slot on the certificate channel. An empty peer
/// table still returns the number of payloads that were offered. Does not
/// clear the ring.
pub fn broadcastEvidencePayloads(
    p2p: *P2PServer,
    validator_id: [32]u8,
    ring: *EquivocationEvidenceRing,
) !usize {
    var sent: usize = 0;
    var i: usize = 0;
    while (i < ring.count) : (i += 1) {
        const payload = ring.slots[i] orelse continue;
        try p2p.broadcastCertificate(validator_id, payload);
        sent += 1;
    }
    return sent;
}

fn realtimeSecs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

/// Handle an inbound block announced by a peer.
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
    /// Owned `k3eq01` payloads. `0` disables `rebroadcastEquivocation`.
    evidence_ring: EquivocationEvidenceRing = .{},
    /// Owned path `{data_dir}/m4_state.equiv.ring`. Null skips disk reload.
    evidence_ring_path: ?[]u8 = null,
    equivocation_rebroadcast_interval_secs: i64 = default_equivocation_rebroadcast_interval_secs,
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
            .last_round_advance = blk: {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                break :blk (ts.sec);
            },
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
        self.evidence_ring.deinit(self.allocator);
        if (self.evidence_ring_path) |path| self.allocator.free(path);
        self.quarantined_peers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Copies `path` (`{m4_base}.equiv.ring`). A previous path is freed.
    /// Insert and eviction call `evidence_ring.on_changed` so the owner can
    /// rewrite this file. `loadEvidenceRing` does not.
    pub fn setEvidenceRingPath(self: *Self, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        if (self.evidence_ring_path) |old| self.allocator.free(old);
        self.evidence_ring_path = owned;
    }

    /// Reloads `{m4_base}.equiv.ring` when a path is set. Missing file is success.
    pub fn loadEvidenceRing(self: *Self) void {
        const path = self.evidence_ring_path orelse return;
        self.evidence_ring.loadFromFile(self.allocator, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => Log.warn("consensus_event=equivocation_ring_load_failed error={s}", .{@errorName(err)}),
        };
    }

    /// Handle a block announced by a peer.
    ///
    /// `receiveBlock` validates the digest and files the block under it; we
    /// then re-read the validated block and vote on that. Previously this
    /// deserialized the bytes and voted on that copy *before* any digest check,
    /// so a peer could steer us into signing a vote for an arbitrary digest.
    pub fn onBlockReceived(self: *Self, peer_id: [32]u8, block_data: []const u8) !void {
        Log.debug("consensus_event=block_received peer_prefix={} payload_bytes={}", .{
            peer_id[0], block_data.len,
        });

        // Validate + store. On a malformed or digest-mismatched block this
        // returns an error and nothing is voted on.
        self.node.receiveBlock(block_data) catch |err| {
            Log.warn("Rejected block from peer: {s}", .{@errorName(err)});
            return err;
        };

        // Re-derive the block we just accepted, so the vote covers the digest
        // that is actually keyed in the pending set.
        var block = Mysticeti.Block.deserialize(self.allocator, block_data) catch {
            Log.err("Failed to deserialize block", .{});
            return;
        };
        defer block.deinit(self.allocator);

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
                const ev_bytes = try evidence.serializeWire(self.allocator);
                var release_bytes = true;
                defer if (release_bytes) self.allocator.free(ev_bytes);
                try self.p2p_server.broadcastCertificate(self.validator_id, ev_bytes);
                // The immediate send counts toward the rebroadcast interval.
                self.evidence_ring.last_sent_secs = realtimeSecs();
                const retained = self.evidence_ring.insert(self.allocator, ev_bytes);
                release_bytes = false;
                try self.punishEquivocation(evidence.voter, evidence.round.value, retained);
                Log.warn("consensus_event=equivocation_detected peer_prefix={} round={} action=quarantine_broadcast", .{
                    peer_id[0], evidence.round.value,
                });
            },
        }
        self.should_commit = true;
    }

    pub fn onCertificateReceived(self: *Self, _: [32]u8, payload: []const u8) !void {
        if (payload.len < Mysticeti.EquivocationEvidence.wire_magic.len) return;
        if (!std.mem.eql(u8, payload[0..Mysticeti.EquivocationEvidence.wire_magic.len], Mysticeti.EquivocationEvidence.wire_magic)) {
            Log.debug("Received certificate from peer", .{});
            return;
        }
        const evidence = Mysticeti.EquivocationEvidence.deserializeWire(self.allocator, payload) catch |err| {
            Log.warn("consensus_event=equivocation_gossip_rejected error={s}", .{@errorName(err)});
            return;
        };
        if (!evidence.signaturesHold()) {
            Log.warn("consensus_event=equivocation_gossip_rejected reason=bad_signature", .{});
            return;
        }
        try self.quarantinePeer(evidence.voter);
        // Slash stays on `applyEquivocationEvidence`, which ignores a repeated digest.
        self.punishEquivocation(evidence.voter, evidence.round.value, payload) catch |err| {
            Log.err("consensus_event=equivocation_slash_failed error={s}", .{@errorName(err)});
        };
        const copy = self.allocator.dupe(u8, payload) catch |err| {
            Log.err("consensus_event=equivocation_evidence_retain_failed error={s}", .{@errorName(err)});
            return;
        };
        _ = self.evidence_ring.insert(self.allocator, copy);
    }

    /// Sends one retained payload when `equivocation_rebroadcast_interval_secs`
    /// has elapsed since the previous certificate broadcast. Interval `0` returns
    /// without sending. `broadcastCertificate` borrows `payload` for the call:
    /// `sendMessage` serializes a frame and frees that frame before returning.
    pub fn rebroadcastEquivocation(self: *Self, now: i64) !void {
        const pick = nextEvidence(
            self.evidence_ring.count,
            self.evidence_ring.cursor,
            self.evidence_ring.last_sent_secs,
            now,
            self.equivocation_rebroadcast_interval_secs,
        ) orelse return;
        const payload = self.evidence_ring.slots[pick.index] orelse return;
        try self.p2p_server.broadcastCertificate(self.validator_id, payload);
        self.evidence_ring.cursor = pick.next_cursor;
        self.evidence_ring.last_sent_secs = now;
    }

    fn punishEquivocation(self: *Self, validator: [32]u8, round: u64, evidence_payload: []const u8) !void {
        const slash_amount = self.node.scheduledSlashAmount(validator);
        if (slash_amount == 0) return error.InsufficientStake;
        _ = try self.node.applyEquivocationEvidence(
            validator,
            validator,
            round,
            evidence_payload,
            slash_amount,
        );
    }

    pub fn onPeerConnected(self: *Self, peer_id: [32]u8) void {
        _ = peer_id;
        Log.info("Peer connected, total peers: {}", .{self.p2p_server.peerCount()});
        const sent = broadcastEvidencePayloads(self.p2p_server, self.validator_id, &self.evidence_ring) catch |err| {
            Log.warn("consensus_event=equivocation_catchup_failed error={s}", .{@errorName(err)});
            return;
        };
        if (sent > 0) self.evidence_ring.last_sent_secs = realtimeSecs();
    }

    pub fn onPeerDisconnected(self: *Self, peer_id: [32]u8) void {
        Log.info("Peer disconnected, remaining peers: {}", .{
            self.p2p_server.peerCount(),
            self.p2p_server.peerCount(),
        });
        _ = peer_id;
    }

    fn createAndBroadcastVote(self: *Self, block: *const Mysticeti.Block) !void {
        // Report this validator's real weight rather than a fixed constant, so
        // the receiving side can tally stake meaningfully. The receiver
        // overwrites this with its own stake pool anyway -- the wire value is
        // untrusted -- but sending the true value keeps the value that lands in
        // local logs and any future BLS-aggregation path honest.
        const stake_pool = self.node.stake_pool orelse return error.NoStakePool;
        const voting_power = stake_pool.getVotingPower(self.validator_id);
        if (voting_power == 0) {
            Log.warn("No stake for validator {}; refusing to vote", .{self.validator_id[0]});
            return error.UnknownValidatorStake;
        }

        var message: [40]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], block.round.value, .big);
        @memcpy(message[8..40], &block.digest);
        const sig_ed = try @import("../../property/Signature.zig").Ed25519.sign(self.validator_key, &message);
        var sig: [96]u8 = @as([96]u8, @splat(0));
        @memcpy(sig[0..64], &sig_ed);

        const vote = Mysticeti.Vote{
            .voter = self.validator_id,
            .stake = voting_power,
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

        const now = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            break :blk (ts.sec);
        };

        if (now - self.last_round_advance >= self.node.config.consensus.round_interval_secs) {
            try self.node.advanceRound();
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
                        break :blk peer.*.recvMessage() catch |err| {
                            if (isTransientReadError(err)) break; // retry next tick
                            if (!isFatalPeerError(err)) break;
                            peer_dead = true;
                            break;
                        };
                    }
                    if (self.p2p_server.quic_peers.getPtr(peer_id)) |peer| {
                        break :blk peer.*.recvMessage() catch |err| {
                            if (isTransientReadError(err)) break;
                            if (!isFatalPeerError(err)) break;
                            peer_dead = true;
                            break;
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

test "peer read errors: only fatal ones evict a peer" {
    // Regression: `processPeerMessages` used `else => peer_dead = true`, so any
    // error that was not `WouldBlock` removed the peer. Because Zig collapses
    // unrecognised errnos into `error.Unexpected`, healthy peers were evicted
    // on the first transient socket hiccup and the devnet never held a single
    // connection (`peers: 0` on every node).

    // Nothing available right now -> retry, never evict.
    try std.testing.expect(isTransientReadError(error.WouldBlock));
    try std.testing.expect(isTransientReadError(error.Unexpected));
    try std.testing.expect(!isFatalPeerError(error.WouldBlock));
    try std.testing.expect(!isFatalPeerError(error.Unexpected));

    // Connection genuinely gone -> evict.
    try std.testing.expect(isFatalPeerError(error.EndOfStream));
    try std.testing.expect(isFatalPeerError(error.BrokenPipe));
    try std.testing.expect(isFatalPeerError(error.ConnectionResetByPeer));

    // A frame we cannot parse means the stream is untrustworthy: evict. This is
    // also the path that keeps `Message.deserialize`'s unknown-type rejection
    // from turning into an endless stream of garbage from one peer.
    try std.testing.expect(isFatalPeerError(error.UnknownMessageType));
    try std.testing.expect(isFatalPeerError(error.MessageTooLarge));
    try std.testing.expect(isFatalPeerError(error.IncompleteHeader));
    try std.testing.expect(isFatalPeerError(error.IncompletePayload));

    // Still-unknown errors must not evict: the fail-open direction keeps a peer
    // that could be healthy, at the cost of retrying a dead one until it
    // reports EOF itself.
    try std.testing.expect(!isFatalPeerError(error.OutOfMemory));
    try std.testing.expect(!isTransientReadError(error.OutOfMemory));
}

test "equivocation evidence ring stores one payload and nextEvidence honors the interval" {
    const allocator = std.testing.allocator;
    var ring: EquivocationEvidenceRing = .{};
    defer ring.deinit(allocator);

    const payload = try allocator.dupe(u8, "k3eq-one");
    _ = ring.insert(allocator, payload);
    try std.testing.expectEqual(@as(usize, 1), ring.count);

    const duplicate = try allocator.dupe(u8, "k3eq-one");
    _ = ring.insert(allocator, duplicate);
    try std.testing.expectEqual(@as(usize, 1), ring.count);
    try std.testing.expectEqual(evidence_ring_cap, ring.slots.len);
    try std.testing.expectEqual(@as(i64, 30), default_equivocation_rebroadcast_interval_secs);

    // Interval 0 disables the picker. Cursor and last-sent stay put.
    try std.testing.expect(nextEvidence(ring.count, ring.cursor, ring.last_sent_secs, 10_000, 0) == null);
    try std.testing.expectEqual(@as(usize, 0), ring.cursor);

    ring.last_sent_secs = 1_000;
    try std.testing.expect(nextEvidence(ring.count, ring.cursor, ring.last_sent_secs, 1_029, 30) == null);

    const picked = nextEvidence(ring.count, ring.cursor, ring.last_sent_secs, 1_030, 30).?;
    try std.testing.expectEqual(@as(usize, 0), picked.index);
    try std.testing.expectEqual(@as(usize, 1), picked.next_cursor);
    try std.testing.expect(std.mem.eql(u8, ring.slots[picked.index].?, "k3eq-one"));

    const Hit = struct { n: usize = 0 };
    var hit: Hit = .{};
    ring.on_changed = struct {
        fn cb(ctx: *anyopaque) void {
            const h: *Hit = @ptrCast(@alignCast(ctx));
            h.n += 1;
        }
    }.cb;
    ring.on_changed_ctx = &hit;
    _ = ring.insert(allocator, try allocator.dupe(u8, "k3eq-two"));
    try std.testing.expectEqual(@as(usize, 1), hit.n);
    _ = ring.insert(allocator, try allocator.dupe(u8, "k3eq-two"));
    try std.testing.expectEqual(@as(usize, 1), hit.n);
    while (ring.count < evidence_ring_cap) {
        var byte: [1]u8 = .{@intCast(ring.count)};
        _ = ring.insert(allocator, try allocator.dupe(u8, &byte));
    }
    const filled = hit.n;
    _ = ring.insert(allocator, try allocator.dupe(u8, "evicted"));
    try std.testing.expectEqual(filled + 1, hit.n);
    try std.testing.expectEqual(evidence_ring_cap, ring.count);
    try std.testing.expect(std.mem.eql(u8, ring.slots[0].?, "evicted"));
    const persist_hook: *const fn (*anyopaque) void = @import("../../app/Node.zig").Node.onEvidenceRingChanged;
    _ = persist_hook;
}

test "equivocation evidence ring reloads the last 16 payloads and ignores a bad magic" {
    const allocator = std.testing.allocator;
    const io = @import("io_instance").io;
    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/zknot3_equiv_ring_reload.equiv.ring";
    const bad_path = "/tmp/zknot3_equiv_ring_bad_magic.equiv.ring";
    const over_path = "/tmp/zknot3_equiv_ring_over.equiv.ring";
    defer cwd.deleteFile(io, path) catch {};
    defer cwd.deleteFile(io, bad_path) catch {};
    defer cwd.deleteFile(io, over_path) catch {};

    var ring: EquivocationEvidenceRing = .{};
    defer ring.deinit(allocator);
    _ = ring.insert(allocator, try allocator.dupe(u8, "aaa"));
    _ = ring.insert(allocator, try allocator.dupe(u8, "bbb"));
    try ring.saveToFile(allocator, path);

    var loaded: EquivocationEvidenceRing = .{};
    defer loaded.deinit(allocator);
    try loaded.loadFromFile(allocator, path);
    try std.testing.expectEqual(@as(usize, 2), loaded.count);
    try std.testing.expect(std.mem.eql(u8, loaded.slots[0].?, "aaa"));
    try std.testing.expect(std.mem.eql(u8, loaded.slots[1].?, "bbb"));

    {
        const file = try cwd.createFile(io, bad_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "XXXXXX");
    }
    var ignored: EquivocationEvidenceRing = .{};
    defer ignored.deinit(allocator);
    _ = ignored.insert(allocator, try allocator.dupe(u8, "keep"));
    try ignored.loadFromFile(allocator, bad_path);
    try std.testing.expectEqual(@as(usize, 1), ignored.count);
    try std.testing.expect(std.mem.eql(u8, ignored.slots[0].?, "keep"));

    var over: std.ArrayList(u8) = .empty;
    defer over.deinit(allocator);
    try over.appendSlice(allocator, "k3eq01");
    try over.append(allocator, 20);
    var n: usize = 0;
    while (n < 20) : (n += 1) {
        var lenb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lenb, 1, .big);
        try over.appendSlice(allocator, &lenb);
        try over.append(allocator, @intCast(n));
    }
    {
        const file = try cwd.createFile(io, over_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, over.items);
    }
    var capped: EquivocationEvidenceRing = .{};
    defer capped.deinit(allocator);
    try capped.loadFromFile(allocator, over_path);
    try std.testing.expectEqual(evidence_ring_cap, capped.count);
    try std.testing.expectEqual(@as(u8, 4), capped.slots[0].?[0]);
    try std.testing.expectEqual(@as(u8, 19), capped.slots[evidence_ring_cap - 1].?[0]);
}

test "retained equivocation evidence is offered once per occupied slot" {
    const allocator = std.testing.allocator;
    var ring: EquivocationEvidenceRing = .{};
    defer ring.deinit(allocator);
    const empty = try P2PServer.init(allocator, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), try broadcastEvidencePayloads(empty, @as([32]u8, @splat(1)), &ring));

    _ = ring.insert(allocator, try allocator.dupe(u8, "one"));
    _ = ring.insert(allocator, try allocator.dupe(u8, "two"));
    try std.testing.expectEqual(@as(usize, 2), try broadcastEvidencePayloads(empty, @as([32]u8, @splat(1)), &ring));
    try std.testing.expectEqual(@as(usize, 2), ring.count);
}
