//! CommitCoordinator - commit-loop orchestration for Node.
//!
//! Adaptive batching:
//! The hot commit loop is driven from `ConsensusIntegration.tryCommit`, which
//! calls into this module. Under low QPS we want to avoid looping and issuing
//! empty drain sweeps (which are pure overhead and, for durability-backed
//! paths, cause empty fsync work). Under high QPS we want to drain as much
//! as possible per scheduler tick so we don't starve the main loop's other
//! responsibilities.
//!
//! `AdaptiveBatchState` exposes a simple TCP-like AIMD knob:
//! * Start at `initial_batch`.
//! * On a drain that hit the cap (`drained == batch`), double up to `max_batch`.
//! * On a drain shorter than the cap but non-empty, stay put.
//! * On an empty drain, halve down to `min_batch`.
//! This lets callers stop doing 10k-element map iterations during idle periods
//! and still open up a big drain window when bursts arrive.

const std = @import("std");
const Mysticeti = @import("../form/consensus/Mysticeti.zig");
const BlockCommit = @import("BlockCommit.zig");

pub const CommitOutcome = struct {
    cert: Mysticeti.CommitCertificate,
    promoted_round: u64,
};

pub const OnQuorumBlockFn = *const fn (ctx: *anyopaque, block: *const Mysticeti.Block) void;

/// Adaptive batch sizing for the commit drain loop.
pub const AdaptiveBatchState = struct {
    min_batch: usize = 1,
    max_batch: usize = 256,
    current: usize = 4,

    pub fn init(initial: usize, min_batch: usize, max_batch: usize) AdaptiveBatchState {
        return .{
            .min_batch = @max(@as(usize, 1), min_batch),
            .max_batch = @max(@as(usize, 1), max_batch),
            .current = std.math.clamp(initial, @max(@as(usize, 1), min_batch), @max(@as(usize, 1), max_batch)),
        };
    }

    /// Feed the actual drain count back; returns the batch size to use next time.
    pub fn observe(self: *AdaptiveBatchState, drained: usize) usize {
        if (drained == 0) {
            // Idle: shrink aggressively to avoid empty sweeps.
            self.current = @max(self.min_batch, self.current / 2);
        } else if (drained >= self.current) {
            // Saturated the window: open it up (AI step = double).
            self.current = @min(self.max_batch, self.current *| 2);
        }
        return self.current;
    }

    pub fn currentBudget(self: *const AdaptiveBatchState) usize {
        return self.current;
    }
};

pub fn tryCommitOne(
    allocator: std.mem.Allocator,
    pending_blocks: *BlockCommit.BlockMap,
    committed_blocks: *BlockCommit.BlockMap,
    vote_quorum: usize,
    max_committed_blocks: usize,
    on_quorum_block: OnQuorumBlockFn,
    on_quorum_ctx: *anyopaque,
) !?CommitOutcome {
    var it = pending_blocks.iterator();
    while (it.next()) |entry| {
        const block = entry.value_ptr.*;
        if (!BlockCommit.hasQuorum(&block, vote_quorum)) continue;

        on_quorum_block(on_quorum_ctx, &block);

        const cert = BlockCommit.buildCommitCertificate(&block);
        var promoted_round: u64 = 0;
        if (try BlockCommit.promotePendingBlock(
            allocator,
            pending_blocks,
            committed_blocks,
            block.digest,
            max_committed_blocks,
            &promoted_round,
        )) {
            return .{
                .cert = cert,
                .promoted_round = promoted_round,
            };
        }
    }

    return null;
}

/// Drains up to `max_batch` quorum-reached blocks in a single call, forwarding
/// each committed certificate to `on_outcome`. Returns the number of blocks
/// committed this call. Stops early on the first sweep that finds no quorum
/// block, so a single empty sweep costs O(pending.count()) and no fsync /
/// callback work beyond what `tryCommitOne` normally performs.
///
/// `on_outcome` runs for each successfully committed block and may fail; on
/// failure the batch stops immediately and the error is propagated. Callers
/// that want "keep draining on error" semantics should swallow the error
/// inside `on_outcome` themselves.
pub fn tryCommitBatch(
    allocator: std.mem.Allocator,
    pending_blocks: *BlockCommit.BlockMap,
    committed_blocks: *BlockCommit.BlockMap,
    vote_quorum: usize,
    max_committed_blocks: usize,
    on_quorum_block: OnQuorumBlockFn,
    on_quorum_ctx: *anyopaque,
    max_batch: usize,
    on_outcome: *const fn (ctx: *anyopaque, outcome: CommitOutcome) anyerror!void,
    on_outcome_ctx: *anyopaque,
) !usize {
    if (max_batch == 0) return 0;
    var drained: usize = 0;
    while (drained < max_batch) {
        const maybe = try tryCommitOne(
            allocator,
            pending_blocks,
            committed_blocks,
            vote_quorum,
            max_committed_blocks,
            on_quorum_block,
            on_quorum_ctx,
        );
        const outcome = maybe orelse break;
        drained += 1;
        try on_outcome(on_outcome_ctx, outcome);
    }
    return drained;
}

fn makeVote(voter_seed: u8, round: u64, digest: [32]u8) Mysticeti.Vote {
    return .{
        .voter = [_]u8{voter_seed} ** 32,
        .stake = 1,
        .round = .{ .value = round },
        .block_digest = digest,
        .signature = [_]u8{0} ** 64,
    };
}

test "CommitCoordinator returns null when no block reaches quorum" {
    const allocator = std.testing.allocator;

    var pending = BlockCommit.BlockMap.empty;
    defer pending.deinit(allocator);
    var committed = BlockCommit.BlockMap.empty;
    defer committed.deinit(allocator);

    const block = try Mysticeti.Block.create(
        [_]u8{1} ** 32,
        .{ .value = 7 },
        "payload-a",
        &.{},
        allocator,
    );
    try pending.put(allocator, block.digest, block);

    const Ctx = struct { called: usize = 0 };
    var ctx = Ctx{};
    const onQuorum = struct {
        fn call(raw: *anyopaque, _: *const Mysticeti.Block) void {
            const c = @as(*Ctx, @ptrCast(@alignCast(raw)));
            c.called += 1;
        }
    }.call;

    const outcome = try tryCommitOne(
        allocator,
        &pending,
        &committed,
        1, // needs >=1 vote, but block has 0 vote
        16,
        onQuorum,
        &ctx,
    );

    try std.testing.expect(outcome == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.called);
    try std.testing.expectEqual(@as(usize, 1), pending.count());
    try std.testing.expectEqual(@as(usize, 0), committed.count());

    if (pending.getPtr(block.digest)) |b| b.deinit(allocator);
}

test "CommitCoordinator commits quorum block and invokes callback once" {
    const allocator = std.testing.allocator;

    var pending = BlockCommit.BlockMap.empty;
    defer pending.deinit(allocator);
    var committed = BlockCommit.BlockMap.empty;
    defer committed.deinit(allocator);

    var block = try Mysticeti.Block.create(
        [_]u8{2} ** 32,
        .{ .value = 11 },
        "payload-b",
        &.{},
        allocator,
    );
    try block.votes.put(allocator, [_]u8{9} ** 32, makeVote(9, block.round.value, block.digest));
    try pending.put(allocator, block.digest, block);

    const Ctx = struct { called: usize = 0 };
    var ctx = Ctx{};
    const onQuorum = struct {
        fn call(raw: *anyopaque, _: *const Mysticeti.Block) void {
            const c = @as(*Ctx, @ptrCast(@alignCast(raw)));
            c.called += 1;
        }
    }.call;

    const maybe_outcome = try tryCommitOne(
        allocator,
        &pending,
        &committed,
        1, // quorum met by one vote
        16,
        onQuorum,
        &ctx,
    );
    try std.testing.expect(maybe_outcome != null);
    const outcome = maybe_outcome.?;

    try std.testing.expectEqual(@as(usize, 1), ctx.called);
    try std.testing.expectEqual(@as(usize, 0), pending.count());
    try std.testing.expectEqual(@as(usize, 1), committed.count());
    try std.testing.expectEqual(@as(u64, 11), outcome.promoted_round);
    try std.testing.expectEqual(block.digest, outcome.cert.block_digest);

    if (committed.getPtr(block.digest)) |b| b.deinit(allocator);
}

test "AdaptiveBatchState grows on saturation and shrinks on idle" {
    var s = AdaptiveBatchState.init(4, 1, 64);
    try std.testing.expectEqual(@as(usize, 4), s.currentBudget());

    // Saturated drain -> should double.
    _ = s.observe(4);
    try std.testing.expectEqual(@as(usize, 8), s.currentBudget());

    _ = s.observe(8);
    try std.testing.expectEqual(@as(usize, 16), s.currentBudget());

    // Partial drain -> stay put.
    _ = s.observe(3);
    try std.testing.expectEqual(@as(usize, 16), s.currentBudget());

    // Idle -> halve, floor at min_batch.
    _ = s.observe(0);
    try std.testing.expectEqual(@as(usize, 8), s.currentBudget());
    _ = s.observe(0);
    _ = s.observe(0);
    _ = s.observe(0);
    _ = s.observe(0);
    try std.testing.expectEqual(@as(usize, 1), s.currentBudget());

    // Max cap respected.
    s = AdaptiveBatchState.init(32, 1, 64);
    _ = s.observe(32);
    _ = s.observe(64);
    _ = s.observe(64);
    try std.testing.expectEqual(@as(usize, 64), s.currentBudget());
}

test "tryCommitBatch drains up to max_batch, then stops on empty sweep" {
    const allocator = std.testing.allocator;

    var pending = BlockCommit.BlockMap.empty;
    defer pending.deinit(allocator);
    var committed = BlockCommit.BlockMap.empty;
    defer committed.deinit(allocator);

    var created_digests: [3][32]u8 = undefined;
    for (0..3) |i| {
        const seed: u8 = @intCast(50 + i);
        var b = try Mysticeti.Block.create(
            [_]u8{seed} ** 32,
            .{ .value = @intCast(20 + i) },
            "payload-batch",
            &.{},
            allocator,
        );
        try b.votes.put(allocator, [_]u8{seed} ** 32, makeVote(seed, b.round.value, b.digest));
        created_digests[i] = b.digest;
        try pending.put(allocator, b.digest, b);
    }

    const QuorumCtx = struct { called: usize = 0 };
    var qctx = QuorumCtx{};
    const onQuorum = struct {
        fn call(raw: *anyopaque, _: *const Mysticeti.Block) void {
            const c = @as(*QuorumCtx, @ptrCast(@alignCast(raw)));
            c.called += 1;
        }
    }.call;

    const OutcomeCtx = struct { count: usize = 0 };
    var octx = OutcomeCtx{};
    const onOutcome = struct {
        fn call(raw: *anyopaque, _: CommitOutcome) anyerror!void {
            const c = @as(*OutcomeCtx, @ptrCast(@alignCast(raw)));
            c.count += 1;
        }
    }.call;

    // First call: batch size 2 should drain exactly 2.
    const first = try tryCommitBatch(
        allocator,
        &pending,
        &committed,
        1,
        16,
        onQuorum,
        &qctx,
        2,
        onOutcome,
        &octx,
    );
    try std.testing.expectEqual(@as(usize, 2), first);
    try std.testing.expectEqual(@as(usize, 2), octx.count);
    try std.testing.expectEqual(@as(usize, 1), pending.count());

    // Second call: batch size 8, only 1 left, must return 1 and NOT loop a 2nd empty sweep.
    const second = try tryCommitBatch(
        allocator,
        &pending,
        &committed,
        1,
        16,
        onQuorum,
        &qctx,
        8,
        onOutcome,
        &octx,
    );
    try std.testing.expectEqual(@as(usize, 1), second);
    try std.testing.expectEqual(@as(usize, 3), octx.count);
    try std.testing.expectEqual(@as(usize, 0), pending.count());

    // Empty pool: batch returns 0 immediately.
    const third = try tryCommitBatch(
        allocator,
        &pending,
        &committed,
        1,
        16,
        onQuorum,
        &qctx,
        8,
        onOutcome,
        &octx,
    );
    try std.testing.expectEqual(@as(usize, 0), third);

    for (created_digests) |d| {
        if (committed.getPtr(d)) |b| b.deinit(allocator);
    }
}

