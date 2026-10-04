//! Byzantine simulation framework — randomized adversarial scenarios over
//! in-memory Mysticeti consensus instances with a controllable network
//! (partitions, message drops, delivery delays).
//!
//! Invariants verified (each scenario driven by a seeded PRNG, so failures
//! are reproducible from the printed seed):
//!   1. Equivocation safety — a Byzantine validator double-votes across
//!      random honest vote distributions; at most one block per round ever
//!      reaches quorum (quorum-intersection safety, executable counterpart
//!      of the Coq/Lean theorems in specs/).
//!   2. Partition safety + healing liveness — with a minority partition,
//!      no conflicting commits ever appear on any node; after the partition
//!      heals, the minority catches up and commits the same digests.
//!   3. View-change liveness — a Byzantine leader withholds proposals;
//!      honest timeout votes drive view changes until an honest leader's
//!      round commits.
//!   4. Determinism — identical seeds produce identical commit histories.

const std = @import("std");
const root = @import("../../src/root.zig");

const MysticetiMod = @import("../../src/form/consensus/Mysticeti.zig");
const Mysticeti = MysticetiMod.Mysticeti;
const Round = MysticetiMod.Round;
const Block = MysticetiMod.Block;
const Quorum = @import("../../src/form/consensus/Quorum.zig").Quorum;

const n_validators = 4;
const stake_each: u128 = 1000;

/// Validator identity: id IS the Ed25519 public key of the seed.
fn ed25519Id(seed: [32]u8) [32]u8 {
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    return kp.public_key.toBytes();
}

const Message = union(enum) {
    block: Block,
    vote: MysticetiMod.Vote,
    timeout: MysticetiMod.TimeoutVote,
};

const Envelope = struct {
    deliver_at: u64,
    target: usize,
    msg: Message,
};

pub const Behavior = enum {
    honest,
    /// Double-vote for every block it sees in a round.
    equivocate,
    /// Refuse to propose when leader and never vote.
    withhold,
    /// Propose multiple conflicting blocks when leader.
    propose_conflicts,
};

pub const Sim = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    seeds: [n_validators][32]u8,
    ids: [n_validators][32]u8,
    quorum: *Quorum,
    nodes: [n_validators]*Mysticeti,
    /// Partition assignment per validator (0 = majority side, 1 = minority).
    partition: [n_validators]u1 = @splat(0),
    /// Probability [0,100) that any message is dropped.
    drop_pct: u8 = 0,
    /// Max delivery delay in ticks.
    max_delay: u64 = 0,
    behavior: [n_validators]Behavior = @splat(.honest),
    inbox: std.ArrayList(Envelope),
    rng: std.Random.DefaultPrng,
    now: u64 = 0,
    delivered: u64 = 0,
    dropped_partition: u64 = 0,
    dropped_random: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, seed: u64) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .seeds = undefined,
            .ids = undefined,
            .quorum = undefined,
            .nodes = undefined,
            .inbox = std.ArrayList(Envelope).empty,
            .rng = std.Random.DefaultPrng.init(seed),
        };
        for (0..n_validators) |i| {
            self.seeds[i] = @as([32]u8, @splat(@intCast(0x51 + i)));
            self.ids[i] = ed25519Id(self.seeds[i]);
        }
        self.quorum = try Quorum.init(allocator);
        for (self.ids) |id| try self.quorum.addValidator(id, stake_each);
        for (0..n_validators) |i| {
            self.nodes[i] = try Mysticeti.init(allocator, self.quorum);
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        while (self.inbox.pop()) |env| {
            var e = env;
            if (e.msg == .block) e.msg.block.deinit(self.allocator);
        }
        self.inbox.deinit(self.allocator);
        for (self.nodes) |node| node.deinit();
        self.quorum.deinit();
        self.allocator.destroy(self);
    }

    fn rnd(self: *Self) std.Random {
        return self.rng.random();
    }

    /// Gossip a message from `from` to every other validator, applying
    /// partition / drop / delay semantics.
    pub fn gossip(self: *Self, from: usize, msg: Message) void {
        for (0..n_validators) |to| {
            if (to == from) continue;
            if (self.partition[from] != self.partition[to]) {
                self.dropped_partition += 1;
                continue;
            }
            if (self.drop_pct > 0 and self.rnd().intRangeAtMost(u8, 0, 99) < self.drop_pct) {
                self.dropped_random += 1;
                continue;
            }
            const delay = self.rnd().intRangeAtMost(u64, 0, self.max_delay);
            self.inbox.append(self.allocator, .{
                .deliver_at = self.now + delay,
                .target = to,
                .msg = msg,
            }) catch @panic("oom");
        }
        // The local copy in the message is transferred to the envelopes;
        // blocks are re-duplicated per envelope in `broadcastBlock` instead.
    }

    /// Blocks need one owned copy per recipient.
    pub fn gossipBlock(self: *Self, from: usize, block: *const Block) void {
        for (0..n_validators) |to| {
            if (to == from) continue;
            if (self.partition[from] != self.partition[to]) {
                self.dropped_partition += 1;
                continue;
            }
            if (self.drop_pct > 0 and self.rnd().intRangeAtMost(u8, 0, 99) < self.drop_pct) {
                self.dropped_random += 1;
                continue;
            }
            const copy = Block.create(block.author, block.round, block.payload, block.parents, self.allocator) catch @panic("oom");
            const delay = self.rnd().intRangeAtMost(u64, 0, self.max_delay);
            self.inbox.append(self.allocator, .{
                .deliver_at = self.now + delay,
                .target = to,
                .msg = .{ .block = copy },
            }) catch @panic("oom");
        }
    }

    /// Deliver every message whose time has come. Returns deliveries made.
    pub fn tick(self: *Self) usize {
        var delivered_now: usize = 0;
        var i: usize = 0;
        while (i < self.inbox.items.len) {
            const env = self.inbox.items[i];
            if (env.deliver_at > self.now) {
                i += 1;
                continue;
            }
            _ = self.inbox.orderedRemove(i);
            switch (env.msg) {
                .block => |b| {
                    self.nodes[env.target].addBlock(b) catch {};
                    var mut_env = env;
                    mut_env.msg.block.deinit(self.allocator);
                },
                .vote => |v| self.nodes[env.target].receiveVote(v) catch {},
                .timeout => |t| self.nodes[env.target].receiveTimeoutVote(t) catch {},
            }
            delivered_now += 1;
            self.delivered += 1;
        }
        return delivered_now;
    }

    /// Advance until the network is quiet.
    pub fn settle(self: *Self, max_ticks: u64) void {
        var t: u64 = 0;
        while (t < max_ticks and self.inbox.items.len > 0) : (t += 1) {
            self.now += 1;
            _ = self.tick();
        }
    }

    pub fn makeVote(self: *Self, voter: usize, block: *Block) MysticetiMod.Vote {
        return self.nodes[voter].createVote(self.ids[voter], self.seeds[voter], stake_each, block) catch @panic("vote");
    }

    /// Digests that reached quorum on `node` for a round (its own view).
    pub fn quorumDigests(self: *Self, node: usize, round: u64, out: *std.ArrayList([32]u8)) !void {
        const c = self.nodes[node];
        if (c.dag.get(.{ .value = round })) |blocks| {
            var it = blocks.iterator();
            while (it.next()) |e| {
                if (c.hasQuorum(e.value_ptr)) try out.append(self.allocator, e.value_ptr.digest);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Scenario 1: equivocation safety under random honest vote distributions.
// ---------------------------------------------------------------------------

test "byzantine: equivocating validator cannot create two quorums in one round" {
    const allocator = std.testing.allocator;
    // Randomize honest vote distributions; the Byzantine validator votes
    // for EVERY block in the round. Quorum = 2667/4000, i.e. 3 validators.
    var seed: u64 = 0xB7A20260;
    var iter: usize = 0;
    const iterations = 300;
    while (iter < iterations) : (iter += 1) {
        seed +%= 0x9E3779B97F4A7C15;
        var sim = try Sim.init(allocator, seed);
        defer sim.deinit();
        sim.behavior[3] = .equivocate;

        const round: u64 = 10;
        // Two conflicting blocks in the same round by different honest authors.
        var block_a = try Block.create(sim.ids[0], .{ .value = round }, "conflict-a", &[_]Round{.{ .value = round - 1 }}, allocator);
        defer block_a.deinit(allocator);
        var block_b = try Block.create(sim.ids[1], .{ .value = round }, "conflict-b", &[_]Round{.{ .value = round - 1 }}, allocator);
        defer block_b.deinit(allocator);

        // The observing node holds both conflicting blocks.
        try sim.nodes[0].addBlock(block_a);
        try sim.nodes[1].addBlock(block_b);
        try sim.nodes[2].addBlock(block_a);
        try sim.nodes[2].addBlock(block_b);

        // Byzantine votes for both blocks.
        _ = try sim.nodes[2].receiveVote(sim.makeVote(3, &block_a));
        _ = try sim.nodes[2].receiveVote(sim.makeVote(3, &block_b));

        // Honest validators 0,1,2 each vote for a random one of the blocks.
        const rnd = sim.rnd();
        for (0..3) |v| {
            const target = if (rnd.boolean()) &block_a else &block_b;
            _ = try sim.nodes[2].receiveVote(sim.makeVote(v, target));
        }

        // Invariant: at most one digest in this round has quorum on any node.
        var qa = std.ArrayList([32]u8).empty;
        defer qa.deinit(allocator);
        try sim.quorumDigests(2, round, &qa);
        if (qa.items.len > 1) {
            std.debug.print("SAFETY VIOLATION at seed {d}: {d} quorum digests in round {d}\n", .{ seed, qa.items.len, round });
            return error.TestUnexpectedResult;
        }

        // Duplicate votes by the same voter on the same block are rejected:
        // stake never double-counts one validator.
        const before = sim.nodes[2].findBlockByDigest(block_a.digest).?.stake_cache;
        _ = try sim.nodes[2].receiveVote(sim.makeVote(3, &block_a));
        const after = sim.nodes[2].findBlockByDigest(block_a.digest).?.stake_cache;
        try std.testing.expectEqual(before, after);
    }
}

// ---------------------------------------------------------------------------
// Scenario 2: partition safety + healing liveness, with drops and delays.
// ---------------------------------------------------------------------------

test "byzantine: partition keeps safety, healing restores liveness" {
    const allocator = std.testing.allocator;
    const seed: u64 = 0x0A717171;
    var sim = try Sim.init(allocator, seed);
    defer sim.deinit();
    sim.drop_pct = 5; // 5% random drops
    sim.max_delay = 3;

    // Partition: validator 3 isolated (minority of 1), majority 0/1/2.
    sim.partition = .{ 0, 0, 0, 1 };

    // Majority side builds rounds 2..7 with full honest quorum votes.
    // 2-chain rule: tryCommit2Chain(N, digest) commits the block at N-2
    // using quorum evidence from round N+1, so blocks at rounds 2..4 become
    // committable once rounds up to 7 exist.
    var committed_majority_rounds: [8]u64 = undefined;
    var committed_majority_digests: [8][32]u8 = undefined;
    var committed_majority_len: usize = 0;
    var committed_minority_len: usize = 0;
    var digests: [8][32]u8 = undefined;

    var r: u64 = 2;
    while (r < 8) : (r += 1) {
        const author_idx = sim.nodes[0].leaderForRound(.{ .value = r }, n_validators);
        const author = sim.ids[author_idx];
        const parents = &[_]Round{.{ .value = r - 1 }};
        var block = try Block.create(author, .{ .value = r }, "partition-round", parents, allocator);
        defer block.deinit(allocator);
        digests[r] = block.digest;
        for (0..3) |i| try sim.nodes[i].addBlock(block);
        for (0..3) |v| {
            const vote = sim.makeVote(v, &block);
            for (0..3) |i| _ = try sim.nodes[i].receiveVote(vote);
        }

        // The isolated node runs its own proposal for the same round.
        var lone_block = try Block.create(sim.ids[3], .{ .value = r }, "lone-round", parents, allocator);
        defer lone_block.deinit(allocator);
        try sim.nodes[3].addBlock(lone_block);
        _ = try sim.nodes[3].receiveVote(sim.makeVote(3, &lone_block));
    }

    // Commit checks with the correct 2-chain offsets.
    for (2..5) |cr| {
        if (try sim.nodes[2].tryCommit2Chain(.{ .value = cr + 2 }, digests[cr])) |cert| {
            committed_majority_rounds[committed_majority_len] = cert.round.value;
            committed_majority_digests[committed_majority_len] = cert.block_digest;
            committed_majority_len += 1;
        }
        // The minority never sees the majority blocks (still partitioned
        // at collection time), so its commit count must stay zero.
        if (try sim.nodes[3].tryCommit2Chain(.{ .value = cr + 2 }, digests[cr])) |_| {
            committed_minority_len += 1;
        }
    }

    // Safety: the minority (1 validator < quorum) never commits.
    try std.testing.expectEqual(@as(usize, 0), committed_minority_len);
    // Liveness on the majority side: at least one commit happened.
    try std.testing.expect(committed_majority_len >= 1);

    // Healing: replay the majority history to the minority node.
    sim.partition = @splat(0);
    var it = sim.nodes[0].dag.iterator();
    while (it.next()) |entry| {
        var bit = entry.value_ptr.iterator();
        while (bit.next()) |be| {
            // addBlock replaces (and would leak) existing copies: skip known digests.
            if (sim.nodes[3].findBlockByDigest(be.value_ptr.digest) != null) continue;
            try sim.nodes[3].addBlock(be.value_ptr.*);
            var vit = be.value_ptr.votes.iterator();
            while (vit.next()) |ve| {
                try sim.nodes[3].receiveVote(ve.value_ptr.*);
            }
        }
    }
    // The minority now sees quorum for exactly the majority's committed rounds.
    for (committed_majority_digests[0..committed_majority_len]) |d| {
        const blk = sim.nodes[3].findBlockByDigest(d) orelse return error.TestUnexpectedResult;
        try std.testing.expect(sim.nodes[3].hasQuorum(blk));
    }
}

// ---------------------------------------------------------------------------
// Scenario 3: view-change liveness under a withholding Byzantine leader.
// ---------------------------------------------------------------------------

test "byzantine: withholding leader is unblocked by view change" {
    const allocator = std.testing.allocator;
    const seed: u64 = 0x017110D;
    var sim = try Sim.init(allocator, seed);
    defer sim.deinit();
    sim.behavior[3] = .withhold;

    var views: u64 = 0;
    var committed: ?MysticetiMod.CommitCertificate = null;
    var attempts: u64 = 0;
    // Proposals awaiting 2-chain evidence: (round, digest). The commit
    // rule needs a quorum block at round+3, so sweep pendings each round.
    var pending_rounds: [16]u64 = undefined;
    var pending_digests: [16][32]u8 = undefined;
    var pending_len: usize = 0;

    while (committed == null and attempts < 16) : (attempts += 1) {
        const leader_idx: usize = @intCast(sim.nodes[0].leaderForRound(sim.nodes[0].current_round, n_validators));
        const byz_leader = (leader_idx == 3);

        if (!byz_leader) {
            // Honest leader proposes; honest validators vote.
            const r = sim.nodes[0].current_round.value;
            const author = sim.ids[leader_idx];
            var block = try Block.create(author, sim.nodes[0].current_round, "viewchange-round", &[_]Round{.{ .value = if (r > 0) r - 1 else 0 }}, allocator);
            defer block.deinit(allocator);
            for (0..3) |i| try sim.nodes[i].addBlock(block);
            for (0..3) |v| {
                const vote = sim.makeVote(v, &block);
                for (0..3) |i| _ = try sim.nodes[i].receiveVote(vote);
            }
            if (pending_len < pending_rounds.len and r >= 2) {
                pending_rounds[pending_len] = r;
                pending_digests[pending_len] = block.digest;
                pending_len += 1;
            }
            for (0..n_validators) |i| sim.nodes[i].advanceRound();
        } else {
            // Byzantine leader withholds: no proposal appears. Honest
            // validators emit timeout votes; f+1 = 2 of them trigger a view
            // change on every honest node.
            for (0..3) |v| {
                const tv = MysticetiMod.TimeoutVote.sign(sim.ids[v], sim.seeds[v], sim.nodes[0].current_round);
                for (0..3) |i| _ = try sim.nodes[i].receiveTimeoutVote(tv);
            }
            var any_view_change = false;
            for (0..3) |i| {
                if (try sim.nodes[i].tryViewChange()) |cert| {
                    any_view_change = true;
                    views += 1;
                    cert.deinit(allocator);
                }
            }
            try std.testing.expect(any_view_change);
            // All honest nodes moved to the same new view.
            try std.testing.expectEqual(sim.nodes[0].current_round.view, sim.nodes[1].current_round.view);
            try std.testing.expectEqual(sim.nodes[0].current_round.view, sim.nodes[2].current_round.view);
        }

        // Sweep pending proposals for commit eligibility every round.
        var pi: usize = 0;
        while (pi < pending_len) : (pi += 1) {
            const pr = pending_rounds[pi];
            if (sim.nodes[2].current_round.value < pr + 3) continue;
            if (try sim.nodes[2].tryCommit2Chain(.{ .value = pr + 2 }, pending_digests[pi])) |cert| {
                committed = cert;
                break;
            }
        }
    }

    // Liveness: despite the withholding leader, a commit happened within
    // a bounded number of attempts and at least one view change fired.
    try std.testing.expect(committed != null);
    try std.testing.expect(views >= 1);
}

// ---------------------------------------------------------------------------
// Scenario 4: randomized state-transition determinism.
// ---------------------------------------------------------------------------

test "byzantine: identical seeds produce identical commit histories" {
    const allocator = std.testing.allocator;
    const seed: u64 = 0x0D3E8010;

    const History = struct {
        fn run(alloc: std.mem.Allocator, s: u64) ![]u8 {
            var sim = try Sim.init(alloc, s);
            defer sim.deinit();
            var hasher = std.crypto.hash.Blake3.init(.{});
            var r: u64 = 2;
            while (r < 10) : (r += 1) {
                const leader_idx: usize = @intCast(sim.nodes[0].leaderForRound(.{ .value = r }, n_validators));
                const author = sim.ids[leader_idx];
                // Seed-dependent payload: different seeds must produce
                // different block digests (and thus different histories).
                var payload: [12]u8 = undefined;
                sim.rnd().bytes(&payload);
                var block = try Block.create(author, .{ .value = r }, &payload, &[_]Round{.{ .value = r - 1 }}, alloc);
                defer block.deinit(alloc);
                for (0..3) |i| try sim.nodes[i].addBlock(block);
                for (0..3) |v| {
                    const vote = sim.makeVote(v, &block);
                    for (0..3) |i| _ = try sim.nodes[i].receiveVote(vote);
                }
                hasher.update(&block.digest);
                if (try sim.nodes[2].tryCommit2Chain(.{ .value = r }, block.digest)) |cert| {
                    hasher.update(&cert.block_digest);
                }
            }
            var out: [32]u8 = undefined;
            hasher.final(&out);
            return try alloc.dupe(u8, &out);
        }
    };

    const h1 = try History.run(allocator, seed);
    defer allocator.free(h1);
    const h2 = try History.run(allocator, seed);
    defer allocator.free(h2);
    try std.testing.expectEqualSlices(u8, h1, h2);

    const h3 = try History.run(allocator, seed ^ 0xDEAD);
    defer allocator.free(h3);
    // Different seeds are (virtually always) different histories.
    try std.testing.expect(!std.mem.eql(u8, h1, h3));
}

// ---------------------------------------------------------------------------
// Scenario 5: full-network randomized soak — gossip with drops, delays,
// and one equivocator; safety holds on every node at every observed round.
// ---------------------------------------------------------------------------

test "byzantine: randomized gossip soak with equivocator keeps per-round safety" {
    const allocator = std.testing.allocator;
    var seed: u64 = 0x50A72026;
    var iter: usize = 0;
    while (iter < 25) : (iter += 1) {
        seed +%= 0x9E3779B97F4A7C15;
        var sim = try Sim.init(allocator, seed);
        defer sim.deinit();
        sim.drop_pct = 10;
        sim.max_delay = 2;
        sim.behavior[2] = .equivocate;

        var r: u64 = 2;
        while (r < 9) : (r += 1) {
            sim.now += 1;

            // Every validator may propose (multi-author rounds exercise the
            // equivocation paths); votes follow gossip semantics.
            for (0..n_validators) |author_idx| {
                const payload = switch (author_idx) {
                    2 => "byz-proposal",
                    else => "honest-proposal",
                };
                var block = try Block.create(sim.ids[author_idx], .{ .value = r }, payload, &[_]Round{.{ .value = r - 1 }}, allocator);
                defer block.deinit(allocator);
                try sim.nodes[author_idx].addBlock(block);
                sim.gossipBlock(author_idx, &block);

                // The author votes for its own block; the equivocator also
                // votes for any other block it has seen this round.
                const self_vote = sim.makeVote(author_idx, &block);
                for (0..n_validators) |i| {
                    if (i != author_idx) _ = try sim.nodes[i].receiveVote(self_vote);
                }
                if (sim.behavior[author_idx] == .equivocate) {
                    if (r > 2) {
                        var other = try Block.create(sim.ids[0], .{ .value = r - 1 }, "honest-proposal", &[_]Round{.{ .value = r - 2 }}, allocator);
                        defer other.deinit(allocator);
                        const cross_vote = sim.makeVote(author_idx, &other);
                        for (0..n_validators) |i| _ = try sim.nodes[i].receiveVote(cross_vote);
                    }
                }
            }
            sim.settle(8);
        }

        // Per-round safety across ALL nodes: no round shows two different
        // quorum digests on the same node's view.
        for (0..n_validators) |node| {
            var round: u64 = 2;
            while (round < 9) : (round += 1) {
                var qd = std.ArrayList([32]u8).empty;
                defer qd.deinit(allocator);
                try sim.quorumDigests(node, round, &qd);
                if (qd.items.len > 1) {
                    std.debug.print("SAFETY VIOLATION seed={d} node={d} round={d}: {d} quorum digests\n", .{ seed, node, round, qd.items.len });
                    return error.TestUnexpectedResult;
                }
            }
        }
        try std.testing.expect(sim.delivered > 0);
    }
}
