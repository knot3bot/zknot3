//! CommitRule - Compile-time formal verification for consensus
//!
//! Implements commit rules with compile-time verification of:
//! - BFT safety constraints
//! - Quorum formation rules
//! - Latency bounds

const std = @import("std");

/// Commit rule configuration
pub const CommitRuleConfig = struct {
    /// Maximum round number
    max_round: u64 = 1000000,
    /// Minimum commit latency in milliseconds
    min_commit_latency_ms: u64 = 300,
    /// Network RTT estimate in milliseconds
    network_rtt_ms: u64 = 100,
};

/// Commit rule verifier
pub const CommitRule = struct {
    const Self = @This();

    config: CommitRuleConfig,

    /// Verify BFT safety: validators >= 3f + 1
    pub fn verifyBFT(comptime validators: usize, comptime f: usize) void {
        if (validators < 3 * f + 1) @compileError("validators must be >= 3f + 1 for BFT safety");
    }
    /// Verify quorum formation: stake > 2/3 total
    pub fn verifyQuorum(comptime stake: u128, comptime total: u128) void {
        if (stake <= (total * 2) / 3) @compileError("stake must be > 2/3 total for quorum");
    }
    /// Verify round latency bound: min_commit >= 3 * network_rtt
    pub fn verifyLatency(comptime min_latency: u64, comptime rtt: u64) void {
        if (min_latency < 3 * rtt) @compileError("min_latency must be >= 3 * rtt");
    }
    /// Verify throughput bound
    pub fn verifyThroughput(
        comptime tps: u64,
        comptime validators: u64,
        comptime bandwidth_mbps: u64,
        comptime tx_size_bytes: u64,
    ) void {
        // tps <= validators * bandwidth / tx_size
        if (tps > validators * bandwidth_mbps * 1024 * 1024 / tx_size_bytes) @compileError("tps exceeds throughput bound");
    }

    /// Runtime check for commit decision
    pub fn canCommit(
        self: Self,
        round: u64,
        stake: u128,
        total_stake: u128,
        elapsed_ms: u64,
    ) bool {
        // Check round bounds
        if (round > self.config.max_round) return false;

        // Check stake threshold
        const threshold = (total_stake * 2) / 3 + 1;
        if (stake <= threshold) return false;

        // Check latency bound
        if (elapsed_ms < self.config.min_commit_latency_ms) return false;

        return true;
    }

    /// Compute minimum stake for commit
    pub fn minCommitStake(self: Self, total_stake: u128) u128 {
        _ = self;
        return (total_stake * 2) / 3 + 1;
    }
};

test "CommitRule runtime check" {
    const rule = CommitRule{ .config = .{} };

    // Valid commit
    try std.testing.expect(rule.canCommit(100, 3001, 4000, 500));

    // Insufficient stake
    try std.testing.expect(!rule.canCommit(100, 2000, 4000, 500));

    // Too fast
    try std.testing.expect(!rule.canCommit(100, 3001, 4000, 100));
}

test "CommitRule min stake" {
    const rule = CommitRule{ .config = .{} };

    try std.testing.expect(rule.minCommitStake(4000) == 2667); // 4000*2/3+1 = 2667 (integer division)
}

// Example compile-time verification
test "Compile-time BFT verification" {
    // With 4 validators and f=1, we can verify at compile time
    CommitRule.verifyBFT(4, 1);
    CommitRule.verifyQuorum(3000, 4000);
    CommitRule.verifyLatency(300, 100);

    // This would fail at compile time:
    // CommitRule.verifyBFT(2, 1); // Error: validators < 3*f+1
}
