//! Gauges for the rollback rules in `docs/mainnet_cutover_checklist.md`.
//!
//! Checkpoint stall is epochs since the last committed checkpoint.
//! Proof failures are cumulative for this process; the rollback bit trips only
//! after 100 attempts and a rate strictly above 0.1%. Recovery counts a
//! restart slower than 120s. A ban storm is 50 or more peers banned since start.

const std = @import("std");

pub const slow_recovery_ns: u64 = 120 * std.time.ns_per_s;
pub const stall_epochs: u64 = 2;
pub const proof_min_attempts: u64 = 100;
pub const consecutive_slow_limit: u32 = 3;
pub const ban_storm_total: u64 = 50;

pub const State = struct {
    checkpoint_epoch: u64 = 0,
    checkpoint_seen: bool = false,
    proof_attempts: u64 = 0,
    proof_failures: u64 = 0,
    recovery_slow_total: u64 = 0,
    consecutive_slow_recoveries: u32 = 0,

    pub fn noteCheckpoint(self: *State, epoch: u64) void {
        self.checkpoint_seen = true;
        self.checkpoint_epoch = epoch;
    }

    pub fn noteProof(self: *State, ok: bool) void {
        self.proof_attempts += 1;
        if (!ok) self.proof_failures += 1;
    }

    pub fn noteRecovery(self: *State, elapsed_ns: u64) void {
        if (elapsed_ns > slow_recovery_ns) {
            self.recovery_slow_total += 1;
            self.consecutive_slow_recoveries += 1;
        } else {
            self.consecutive_slow_recoveries = 0;
        }
    }

    pub fn gauges(self: State, current_epoch: u64, banned_peers_total: u64) Gauges {
        const stall = if (!self.checkpoint_seen or current_epoch < self.checkpoint_epoch)
            0
        else
            current_epoch - self.checkpoint_epoch;
        const proof_hot = self.proof_attempts >= proof_min_attempts and
            self.proof_failures * 1000 > self.proof_attempts;
        return .{
            .stall_epochs = stall,
            .rollback_stall = if (stall >= stall_epochs) 1 else 0,
            .proof_attempts = self.proof_attempts,
            .proof_failures = self.proof_failures,
            .rollback_proof = if (proof_hot) 1 else 0,
            .recovery_slow_total = self.recovery_slow_total,
            .consecutive_slow_recoveries = self.consecutive_slow_recoveries,
            .rollback_recovery = if (self.consecutive_slow_recoveries >= consecutive_slow_limit) 1 else 0,
            .banned_peers_total = banned_peers_total,
            .rollback_ban_storm = if (banned_peers_total >= ban_storm_total) 1 else 0,
        };
    }
};

pub const Gauges = struct {
    stall_epochs: u64,
    rollback_stall: u64,
    proof_attempts: u64,
    proof_failures: u64,
    rollback_proof: u64,
    recovery_slow_total: u64,
    consecutive_slow_recoveries: u32,
    rollback_recovery: u64,
    banned_peers_total: u64,
    rollback_ban_storm: u64,
};

test "cutover gauges follow the checklist thresholds" {
    var state: State = .{};
    var g = state.gauges(5, 0);
    try std.testing.expectEqual(@as(u64, 0), g.rollback_stall);

    state.noteCheckpoint(1);
    g = state.gauges(3, 0);
    try std.testing.expectEqual(@as(u64, 2), g.stall_epochs);
    try std.testing.expectEqual(@as(u64, 1), g.rollback_stall);

    var i: usize = 0;
    while (i < 100) : (i += 1) state.noteProof(true);
    g = state.gauges(3, 0);
    try std.testing.expectEqual(@as(u64, 0), g.rollback_proof);
    state.noteProof(false);
    g = state.gauges(3, 49);
    try std.testing.expectEqual(@as(u64, 1), g.rollback_proof);
    try std.testing.expectEqual(@as(u64, 0), g.rollback_ban_storm);
    g = state.gauges(3, 50);
    try std.testing.expectEqual(@as(u64, 1), g.rollback_ban_storm);

    state.noteRecovery(slow_recovery_ns);
    state.noteRecovery(slow_recovery_ns + 1);
    state.noteRecovery(slow_recovery_ns + 1);
    g = state.gauges(3, 50);
    try std.testing.expectEqual(@as(u32, 2), g.consecutive_slow_recoveries);
    try std.testing.expectEqual(@as(u64, 0), g.rollback_recovery);
    state.noteRecovery(1);
    g = state.gauges(3, 50);
    try std.testing.expectEqual(@as(u32, 0), g.consecutive_slow_recoveries);
}
