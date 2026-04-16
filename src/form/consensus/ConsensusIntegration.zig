//! ConsensusIntegration - Wires P2P networking to Mysticeti consensus

const std = @import("std");
const Node = @import("../../app/Node.zig").Node;
const P2PServer = @import("../network/P2PServer.zig").P2PServer;
const Mysticeti = @import("Mysticeti.zig");
const Message = @import("../network/Transport.zig").Message;
const Log = @import("../../app/Log.zig");

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
        self_ptr.* = .{
            .allocator = allocator,
            .node = node,
            .p2p_server = p2p_server,
            .validator_id = validator_id,
            .validator_key = validator_key,
            .validator_index = validator_index,
            .last_round_advance = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .last_proposed_round = 0,
        };
        return self_ptr;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn onBlockReceived(self: *Self, peer_id: [32]u8, block_data: []const u8) !void {
        _ = peer_id;
        Log.debug("Received block from peer", .{});

        var block = Mysticeti.Block.deserialize(self.allocator, block_data) catch {
            Log.err("Failed to deserialize block", .{});
            return;
        };
        defer block.deinit(self.allocator);

        try self.node.receiveBlock(block_data);
        try self.createAndBroadcastVote(&block);
    }

    pub fn onVoteReceived(self: *Self, peer_id: [32]u8, vote_data: []const u8) !void {
        _ = peer_id;
        Log.debug("Received vote from peer", .{});

        try self.node.receiveVote(vote_data);
        try self.tryCommit();
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
        try self.node.receiveVote(vote_data);
        Log.debug("Broadcast vote for block", .{});
    }

    fn tryCommit(self: *Self) !void {
        while (true) {
            const cert = self.node.tryCommitBlocks() catch break;
            if (cert) |c| {
                Log.info("Committed block at round {} with quorum_stake {}", .{
                    c.round.value, c.quorum_stake,
                });

                const cert_data = try c.serialize(self.allocator);
                defer self.allocator.free(cert_data);
            } else {
                break;
            }
        }
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
                try self.tryCommit();
            }
        }
    }
    fn isProposer(self: *Self) bool {
        const validator_count: u64 = @intCast(self.node.config.consensus.min_validators);
        return (self.node.consensus_round % validator_count) == self.validator_index;
    }

    pub fn processPeerMessages(self: *Self) !void {
        var dead_peers: std.ArrayList([32]u8) = .empty;
        defer dead_peers.deinit(self.allocator);

        var it = self.p2p_server.peers.iterator();
        while (it.next()) |entry| {
            const peer_id = entry.key_ptr.*;

            var peer_dead = false;
            for (0..10) |_| {
                // Re-validate peer before each recv in case broadcast removed it during handleMessage
                const peer_conn = self.p2p_server.peers.getPtr(peer_id) orelse break;

                const msg = peer_conn.*.recvMessage() catch {
                    peer_dead = true;
                    break;
                };
                if (msg) |m| {
                    defer self.allocator.free(m.payload);
                    try self.handleMessage(peer_id, m);
                } else {
                    // EOF - peer disconnected
                    peer_dead = true;
                    break;
                }
            }

            if (peer_dead) {
                try dead_peers.append(self.allocator, peer_id);
            }
        }

        for (dead_peers.items) |peer_id| {
            self.p2p_server.disconnectPeer(peer_id);
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
};
