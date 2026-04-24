//! MainnetExtensionHooks - M4 mainnet protocol-facing execution layer.
//!
//! This module provides an in-memory but executable protocol state machine for
//! stake/governance/proof flows so network APIs can run end-to-end with
//! verifiable artifacts.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const wal_pkg = @import("../form/storage/WAL.zig");

pub const StakeAction = enum {
    stake,
    unstake,
    reward,
    slash,
};

pub const StakeOperationInput = struct {
    validator: [32]u8,
    delegator: [32]u8,
    amount: u64,
    action: StakeAction,
    metadata: []const u8 = &.{},
};

pub const StakeOperation = struct {
    id: u64,
    submitted_at: i64,
    validator: [32]u8,
    delegator: [32]u8,
    amount: u64,
    action: StakeAction,
    metadata: []u8,
};

pub const StakeOperationStatus = enum {
    accepted,
    rejected,
};

pub const GovernanceKind = enum {
    parameter_change,
    chain_upgrade,
    treasury_action,
};

pub const GovernanceProposalInput = struct {
    proposer: [32]u8,
    title: []const u8,
    description: []const u8,
    kind: GovernanceKind,
    activation_epoch: ?u64 = null,
};

pub const GovernanceProposal = struct {
    id: u64,
    proposer: [32]u8,
    title: []u8,
    description: []u8,
    kind: GovernanceKind,
    activation_epoch: ?u64,
    created_at: i64,
    status: GovernanceStatus,
};

pub const GovernanceStatus = enum {
    pending,
    voting,
    approved,
    rejected,
    executed,
};

pub const GovernanceVote = struct {
    proposal_id: u64,
    validator: [32]u8,
    stake_weight: u64,
    approve: bool,
    voted_at: i64,
};

pub const CheckpointProofRequest = struct {
    sequence: u64,
    object_id: [32]u8,
};

pub const CheckpointProof = struct {
    sequence: u64,
    object_id: [32]u8,
    state_root: [32]u8,
    /// Canonical 80-byte signing payload (domain || state_root || sequence_be || object_id).
    proof_bytes: []u8,
    /// Ed25519 multi-sig list: magic "k3s1" || u32le count || (validator_id[32] || sig[64])*
    signatures: []u8,
    /// Aggregated BLS signature bytes.
    bls_signature: []u8,
    /// Signer bitmap for the BLS aggregate payload.
    bls_signer_bitmap: []u8,
};

/// One Ed25519 validator signature bound to `m4ProofSigningMessage`.
pub const ProofSigPair = struct {
    validator_id: [32]u8,
    signature: [64]u8,
};

/// 8-byte domain + 32 + 8 + 32 = 80 bytes, stable across RPC/GraphQL/SDK.
pub fn m4ProofSigningMessage(state_root: [32]u8, sequence: u64, object_id: [32]u8) [80]u8 {
    var out: [80]u8 = undefined;
    @memcpy(out[0..8], "ZKNOT3CP");
    @memcpy(out[8..40], &state_root);
    std.mem.writeInt(u64, out[40..48], sequence, .big);
    @memcpy(out[48..80], &object_id);
    return out;
}

pub fn encodeProofSignatureList(allocator: std.mem.Allocator, pairs: []const ProofSigPair) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "k3s1");
    var nb: [4]u8 = undefined;
    std.mem.writeInt(u32, &nb, @intCast(pairs.len), .little);
    try buf.appendSlice(allocator, &nb);
    for (pairs) |p| {
        try buf.appendSlice(allocator, &p.validator_id);
        try buf.appendSlice(allocator, &p.signature);
    }
    return try buf.toOwnedSlice(allocator);
}

/// Returns number of pairs and validates total buffer length, or null if malformed.
/// Lowercase hex encoding (no `0x` prefix); suitable for JSON `proof` / `signatures` fields.
pub fn allocHexLower(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 15];
    }
    return out;
}

pub fn decodeProofSignatureLayout(signatures: []const u8) ?struct { count: u32 } {
    if (signatures.len < 8) return null;
    if (!std.mem.eql(u8, signatures[0..4], "k3s1")) return null;
    const count = std.mem.readInt(u32, signatures[4..8], .little);
    const need: usize = 8 + @as(usize, count) * 96;
    if (signatures.len != need) return null;
    return .{ .count = count };
}

pub const ManagerError = error{
    InvalidAmount,
    InsufficientStake,
    ProposalNotFound,
    InvalidGovernanceTransition,
    InvalidWalPayload,
    UnsupportedWalReplayOp,
};

const DelegationKey = struct {
    validator: [32]u8,
    delegator: [32]u8,
};

pub const Manager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    next_stake_operation_id: u64 = 1,
    next_proposal_id: u64 = 1,
    stake_ops: std.ArrayList(StakeOperation),
    proposals: std.ArrayList(GovernanceProposal),
    votes: std.ArrayList(GovernanceVote),
    validator_stake: std.AutoArrayHashMapUnmanaged([32]u8, u64),
    delegations: std.AutoArrayHashMapUnmanaged(DelegationKey, u64),
    processed_evidence: std.AutoArrayHashMapUnmanaged([32]u8, void),
    total_slashed: u64 = 0,
    current_epoch: u64 = 0,
    validator_set_hash: [32]u8 = [_]u8{0} ** 32,
    /// Optional M4-only WAL (separate from LSM); owned by `Node`.
    m4_wal: ?*wal_pkg.WAL = null,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .stake_ops = std.ArrayList(StakeOperation).empty,
            .proposals = std.ArrayList(GovernanceProposal).empty,
            .votes = std.ArrayList(GovernanceVote).empty,
            .validator_stake = .empty,
            .delegations = .empty,
            .processed_evidence = .empty,
            .m4_wal = null,
        };
        return self;
    }

    pub fn setM4Wal(self: *Self, wal: ?*wal_pkg.WAL) void {
        self.m4_wal = wal;
    }

    pub fn deinit(self: *Self) void {
        for (self.stake_ops.items) |op| self.allocator.free(op.metadata);
        self.stake_ops.deinit(self.allocator);

        for (self.proposals.items) |p| {
            self.allocator.free(p.title);
            self.allocator.free(p.description);
        }
        self.proposals.deinit(self.allocator);
        self.votes.deinit(self.allocator);
        self.validator_stake.deinit(self.allocator);
        self.delegations.deinit(self.allocator);
        self.processed_evidence.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn submitStakeOperation(self: *Self, input: StakeOperationInput) (ManagerError || anyerror)!u64 {
        if (input.amount == 0) return error.InvalidAmount;
        const id = self.next_stake_operation_id;
        self.next_stake_operation_id += 1;
        const now = nowSeconds();

        try self.applyStakeOperation(input);

        try self.stake_ops.append(self.allocator, .{
            .id = id,
            .submitted_at = now,
            .validator = input.validator,
            .delegator = input.delegator,
            .amount = input.amount,
            .action = input.action,
            .metadata = try self.allocator.dupe(u8, input.metadata),
        });
        try self.appendStakeOperationWal(&self.stake_ops.items[self.stake_ops.items.len - 1]);
        return id;
    }

    pub fn submitGovernanceProposal(self: *Self, input: GovernanceProposalInput) (ManagerError || anyerror)!u64 {
        if (input.title.len == 0 or input.description.len == 0) return error.InvalidGovernanceTransition;
        const id = self.next_proposal_id;
        self.next_proposal_id += 1;
        try self.proposals.append(self.allocator, .{
            .id = id,
            .proposer = input.proposer,
            .title = try self.allocator.dupe(u8, input.title),
            .description = try self.allocator.dupe(u8, input.description),
            .kind = input.kind,
            .activation_epoch = input.activation_epoch,
            .created_at = nowSeconds(),
            .status = .pending,
        });
        try self.appendGovernanceProposalWal(&self.proposals.items[self.proposals.items.len - 1]);
        return id;
    }

    pub fn updateGovernanceStatus(self: *Self, proposal_id: u64, status: GovernanceStatus) (ManagerError || anyerror)!void {
        for (self.proposals.items) |*p| {
            if (p.id != proposal_id) continue;
            if (p.status == .executed) return error.InvalidGovernanceTransition;
            p.status = status;
            try self.appendGovernanceStatusWal(proposal_id, status);
            return;
        }
        return error.ProposalNotFound;
    }

    /// Cast a stake-weighted vote on a governance proposal.
    /// Auto-tallies after vote; transitions status to approved/rejected if thresholds met.
    pub fn voteOnProposal(self: *Self, proposal_id: u64, validator: [32]u8, approve: bool) (ManagerError || anyerror)!void {
        const stake = self.getValidatorStake(validator);
        if (stake == 0) return error.InsufficientStake;

        for (self.proposals.items) |*p| {
            if (p.id != proposal_id) continue;
            if (p.status != .pending and p.status != .voting) return error.InvalidGovernanceTransition;

            // Check for duplicate vote from same validator
            for (self.votes.items) |v| {
                if (v.proposal_id == proposal_id and std.mem.eql(u8, &v.validator, &validator)) {
                    return error.InvalidGovernanceTransition;
                }
            }

            const vote = GovernanceVote{
                .proposal_id = proposal_id,
                .validator = validator,
                .stake_weight = stake,
                .approve = approve,
                .voted_at = nowSeconds(),
            };
            try self.votes.append(self.allocator, vote);
            try self.appendGovernanceVoteWal(&vote);

            if (p.status == .pending) p.status = .voting;
            try self.tallyVotes(p);
            return;
        }
        return error.ProposalNotFound;
    }

    /// Tally votes for a proposal. Requires > 2/3 stake to approve, > 1/3 to reject.
    fn tallyVotes(self: *Self, proposal: *GovernanceProposal) !void {
        var yes_stake: u64 = 0;
        var no_stake: u64 = 0;
        var total_stake: u64 = 0;

        var it = self.validator_stake.iterator();
        while (it.next()) |entry| {
            total_stake += entry.value_ptr.*;
        }

        for (self.votes.items) |v| {
            if (v.proposal_id != proposal.id) continue;
            if (v.approve) {
                yes_stake += v.stake_weight;
            } else {
                no_stake += v.stake_weight;
            }
        }

        // Quorum: > 2/3 of total stake to approve; > 1/3 against to reject
        const approve_threshold = total_stake * 2 / 3;
        const reject_threshold = total_stake / 3;

        if (yes_stake >= approve_threshold) {
            proposal.status = .approved;
            try self.appendGovernanceStatusWal(proposal.id, .approved);
        } else if (no_stake > reject_threshold) {
            proposal.status = .rejected;
            try self.appendGovernanceStatusWal(proposal.id, .rejected);
        }
    }

    /// Execute an approved proposal. Transitions status to executed.
    pub fn executeProposal(self: *Self, proposal_id: u64) (ManagerError || anyerror)!void {
        for (self.proposals.items) |*p| {
            if (p.id != proposal_id) continue;
            if (p.status != .approved) return error.InvalidGovernanceTransition;

            // Placeholder execution based on kind
            switch (p.kind) {
                .parameter_change => {
                    // In production: apply parameter changes to config/state
                },
                .chain_upgrade => {
                    // In production: schedule/dispatch chain upgrade
                },
                .treasury_action => {
                    // In production: execute treasury transfer or allocation
                },
            }

            p.status = .executed;
            try self.appendGovernanceStatusWal(proposal_id, .executed);
            return;
        }
        return error.ProposalNotFound;
    }

    pub fn getValidatorStake(self: *const Self, validator: [32]u8) u64 {
        return self.validator_stake.get(validator) orelse 0;
    }

    pub fn getTotalSlashed(self: *const Self) u64 {
        return self.total_slashed;
    }

    pub fn getCurrentEpoch(self: *const Self) u64 {
        return self.current_epoch;
    }

    pub fn getValidatorSetHash(self: *const Self) [32]u8 {
        return self.validator_set_hash;
    }

    pub fn advanceEpoch(self: *Self, next_epoch: u64) !void {
        if (next_epoch <= self.current_epoch) return;
        self.current_epoch = next_epoch;
        try self.appendEpochAdvanceWal(next_epoch);
    }

    pub fn rotateValidatorSet(self: *Self, hash: [32]u8) !void {
        self.validator_set_hash = hash;
        try self.appendValidatorSetRotateWal(hash);
    }

    /// Applies slash exactly once per unique evidence digest.
    /// Returns true if slash executed, false if the evidence was already seen.
    pub fn applyEquivocationEvidence(
        self: *Self,
        validator: [32]u8,
        delegator: [32]u8,
        round: u64,
        evidence_payload: []const u8,
        slash_amount: u64,
    ) (ManagerError || anyerror)!bool {
        if (slash_amount == 0) return error.InvalidAmount;

        var digest_ctx = Blake3.init(.{});
        digest_ctx.update(&validator);
        var round_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &round_buf, round, .big);
        digest_ctx.update(&round_buf);
        digest_ctx.update(evidence_payload);
        var evidence_id: [32]u8 = undefined;
        digest_ctx.final(&evidence_id);

        if (self.processed_evidence.contains(evidence_id)) return false;
        try self.appendProcessedEvidenceWal(evidence_id);
        try self.processed_evidence.put(self.allocator, evidence_id, {});

        _ = try self.submitStakeOperation(.{
            .validator = validator,
            .delegator = delegator,
            .amount = slash_amount,
            .action = .slash,
            .metadata = "equivocation_evidence",
        });
        return true;
    }

    /// Builds binding fields; `signatures` is empty — production nodes should use
    /// `Node.buildCheckpointProof` which attaches Ed25519 quorum signatures.
    pub fn buildCheckpointProof(self: *Self, req: CheckpointProofRequest) !CheckpointProof {
        const state_root = try self.computeStateRoot();
        const msg = m4ProofSigningMessage(state_root, req.sequence, req.object_id);
        const proof_bytes = try self.allocator.dupe(u8, &msg);
        const signatures = try self.allocator.alloc(u8, 0);
        const bls_signature = try self.allocator.alloc(u8, 0);
        const bls_signer_bitmap = try self.allocator.alloc(u8, 0);
        return .{
            .sequence = req.sequence,
            .object_id = req.object_id,
            .state_root = state_root,
            .proof_bytes = proof_bytes,
            .signatures = signatures,
            .bls_signature = bls_signature,
            .bls_signer_bitmap = bls_signer_bitmap,
        };
    }

    pub fn freeCheckpointProof(self: *Self, proof: CheckpointProof) void {
        self.allocator.free(proof.proof_bytes);
        self.allocator.free(proof.signatures);
        self.allocator.free(proof.bls_signature);
        self.allocator.free(proof.bls_signer_bitmap);
    }

    fn applyStakeOperation(self: *Self, input: StakeOperationInput) (ManagerError || anyerror)!void {
        const key = DelegationKey{
            .validator = input.validator,
            .delegator = input.delegator,
        };

        const current_validator_stake = self.validator_stake.get(input.validator) orelse 0;
        const current_delegation = self.delegations.get(key) orelse 0;

        switch (input.action) {
            .stake, .reward => {
                try self.validator_stake.put(self.allocator, input.validator, current_validator_stake + input.amount);
                try self.delegations.put(self.allocator, key, current_delegation + input.amount);
            },
            .unstake => {
                if (current_delegation < input.amount) return error.InsufficientStake;
                if (current_validator_stake < input.amount) return error.InsufficientStake;
                try self.validator_stake.put(self.allocator, input.validator, current_validator_stake - input.amount);
                const next_delegation = current_delegation - input.amount;
                if (next_delegation == 0) {
                    _ = self.delegations.swapRemove(key);
                } else {
                    try self.delegations.put(self.allocator, key, next_delegation);
                }
            },
            .slash => {
                if (current_validator_stake == 0) return error.InsufficientStake;
                const slash_amount = @min(input.amount, current_validator_stake);
                try self.validator_stake.put(self.allocator, input.validator, current_validator_stake - slash_amount);
                self.total_slashed += slash_amount;
                try self.applySlashToDelegations(input.validator, slash_amount);
            },
        }
    }

    fn applySlashToDelegations(self: *Self, validator: [32]u8, slash_amount: u64) !void {
        if (slash_amount == 0) return;

        var remaining = slash_amount;
        var updates = std.ArrayList(struct { key: DelegationKey, value: u64 }).empty;
        defer updates.deinit(self.allocator);

        var it = self.delegations.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, &entry.key_ptr.validator, &validator)) continue;
            if (remaining == 0) break;
            const old = entry.value_ptr.*;
            const slash = @min(old, remaining);
            const next = old - slash;
            remaining -= slash;
            try updates.append(self.allocator, .{
                .key = entry.key_ptr.*,
                .value = next,
            });
        }

        for (updates.items) |u| {
            if (u.value == 0) {
                _ = self.delegations.swapRemove(u.key);
            } else {
                try self.delegations.put(self.allocator, u.key, u.value);
            }
        }
    }

    fn appendStakeOperationWal(self: *Self, op: *const StakeOperation) !void {
        const w = self.m4_wal orelse return;
        const payload = try self.serializeStakeOperationWal(op);
        defer self.allocator.free(payload);
        try w.logExtensionRecord(.m4_stake_operation, payload);
    }

    fn appendGovernanceProposalWal(self: *Self, p: *const GovernanceProposal) !void {
        const w = self.m4_wal orelse return;
        const payload = try self.serializeGovernanceProposalWal(p);
        defer self.allocator.free(payload);
        try w.logExtensionRecord(.m4_governance_proposal, payload);
    }

    fn appendGovernanceStatusWal(self: *Self, proposal_id: u64, status: GovernanceStatus) !void {
        const w = self.m4_wal orelse return;
        var buf: [13]u8 = undefined;
        @memcpy(buf[0..4], "m4t1");
        std.mem.writeInt(u64, buf[4..12], proposal_id, .big);
        buf[12] = @intFromEnum(status);
        try w.logExtensionRecord(.m4_governance_status, &buf);
    }

    fn appendGovernanceVoteWal(self: *Self, vote: *const GovernanceVote) !void {
        const w = self.m4_wal orelse return;
        var buf: [61]u8 = undefined;
        @memcpy(buf[0..4], "m4v1");
        std.mem.writeInt(u64, buf[4..12], vote.proposal_id, .big);
        @memcpy(buf[12..44], &vote.validator);
        std.mem.writeInt(u64, buf[44..52], vote.stake_weight, .big);
        buf[52] = if (vote.approve) 1 else 0;
        std.mem.writeInt(i64, buf[53..61], vote.voted_at, .big);
        try w.logExtensionRecord(.m4_governance_vote, &buf);
    }

    fn appendProcessedEvidenceWal(self: *Self, evidence_id: [32]u8) !void {
        const w = self.m4_wal orelse return;
        var buf: [36]u8 = undefined;
        @memcpy(buf[0..4], "m4e1");
        @memcpy(buf[4..36], &evidence_id);
        try w.logExtensionRecord(.m4_equivocation_evidence, &buf);
    }

    fn serializeStakeOperationWal(self: *Self, op: *const StakeOperation) ![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, "m4s1");
        var b8: [8]u8 = undefined;
        std.mem.writeInt(u64, &b8, op.id, .big);
        try list.appendSlice(self.allocator, &b8);
        std.mem.writeInt(i64, &b8, op.submitted_at, .big);
        try list.appendSlice(self.allocator, &b8);
        try list.appendSlice(self.allocator, &op.validator);
        try list.appendSlice(self.allocator, &op.delegator);
        std.mem.writeInt(u64, &b8, op.amount, .big);
        try list.appendSlice(self.allocator, &b8);
        try list.append(self.allocator, @intFromEnum(op.action));
        var b4: [4]u8 = undefined;
        std.mem.writeInt(u32, &b4, @intCast(op.metadata.len), .big);
        try list.appendSlice(self.allocator, &b4);
        try list.appendSlice(self.allocator, op.metadata);
        return try list.toOwnedSlice(self.allocator);
    }

    fn serializeGovernanceProposalWal(self: *Self, p: *const GovernanceProposal) ![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, "m4p1");
        var b8: [8]u8 = undefined;
        std.mem.writeInt(u64, &b8, p.id, .big);
        try list.appendSlice(self.allocator, &b8);
        try list.appendSlice(self.allocator, &p.proposer);
        var b4: [4]u8 = undefined;
        std.mem.writeInt(u32, &b4, @intCast(p.title.len), .big);
        try list.appendSlice(self.allocator, &b4);
        try list.appendSlice(self.allocator, p.title);
        std.mem.writeInt(u32, &b4, @intCast(p.description.len), .big);
        try list.appendSlice(self.allocator, &b4);
        try list.appendSlice(self.allocator, p.description);
        try list.append(self.allocator, @intFromEnum(p.kind));
        if (p.activation_epoch) |ae| {
            try list.append(self.allocator, 1);
            std.mem.writeInt(u64, &b8, ae, .big);
            try list.appendSlice(self.allocator, &b8);
        } else {
            try list.append(self.allocator, 0);
        }
        std.mem.writeInt(i64, &b8, p.created_at, .big);
        try list.appendSlice(self.allocator, &b8);
        try list.append(self.allocator, @intFromEnum(p.status));
        return try list.toOwnedSlice(self.allocator);
    }

    /// Replay one M4 WAL record into this manager (used after crash; disables further WAL writes during batch replay via caller).
    pub fn replayWalExtension(self: *Self, op: wal_pkg.WalRecordType, value: []const u8) !void {
        switch (op) {
            .m4_stake_operation => {
                const sop = try self.deserializeStakeOperationWal(value);
                try self.injectReplayedStakeOperation(sop);
            },
            .m4_governance_proposal => {
                const gp = try self.deserializeGovernanceProposalWal(value);
                try self.injectReplayedGovernanceProposal(gp);
            },
            .m4_governance_status => {
                if (value.len != 13 or !std.mem.eql(u8, value[0..4], "m4t1")) return error.InvalidWalPayload;
                const proposal_id = std.mem.readInt(u64, value[4..12], .big);
                const st = std.enums.fromInt(GovernanceStatus, value[12]) orelse return error.InvalidWalPayload;
                for (self.proposals.items) |*p| {
                    if (p.id == proposal_id) {
                        p.status = st;
                        return;
                    }
                }
                return error.ProposalNotFound;
            },
            .m4_equivocation_evidence => {
                if (value.len != 36 or !std.mem.eql(u8, value[0..4], "m4e1")) return error.InvalidWalPayload;
                const eid = value[4..36].*;
                try self.processed_evidence.put(self.allocator, eid, {});
            },
            .m4_epoch_advance => {
                if (value.len != 12 or !std.mem.eql(u8, value[0..4], "m4ea")) return error.InvalidWalPayload;
                self.current_epoch = std.mem.readInt(u64, value[4..12], .big);
            },
            .m4_validator_set_rotate => {
                if (value.len != 36 or !std.mem.eql(u8, value[0..4], "m4vr")) return error.InvalidWalPayload;
                self.validator_set_hash = value[4..36].*;
            },
            .m4_governance_vote => {
                const vote = try deserializeGovernanceVoteWal(value);
                try self.injectReplayedGovernanceVote(vote);
            },
            .m4_state_snapshot => {
                try self.deserializeStateSnapshot(value);
            },
            .insert, .delete, .commit, .abort => return error.UnsupportedWalReplayOp,
        }
    }

    fn appendEpochAdvanceWal(self: *Self, epoch: u64) !void {
        const w = self.m4_wal orelse return;
        var payload: [12]u8 = undefined;
        @memcpy(payload[0..4], "m4ea");
        std.mem.writeInt(u64, payload[4..12], epoch, .big);
        try w.logExtensionRecord(.m4_epoch_advance, &payload);
        try w.syncAll();
    }

    fn appendValidatorSetRotateWal(self: *Self, hash: [32]u8) !void {
        const w = self.m4_wal orelse return;
        var payload: [36]u8 = undefined;
        @memcpy(payload[0..4], "m4vr");
        @memcpy(payload[4..36], &hash);
        try w.logExtensionRecord(.m4_validator_set_rotate, &payload);
        try w.syncAll();
    }

    fn injectReplayedStakeOperation(self: *Self, op: StakeOperation) !void {
        errdefer self.allocator.free(op.metadata);
        if (op.id >= self.next_stake_operation_id) self.next_stake_operation_id = op.id + 1;
        try self.applyStakeOperation(.{
            .validator = op.validator,
            .delegator = op.delegator,
            .amount = op.amount,
            .action = op.action,
            .metadata = op.metadata,
        });
        try self.stake_ops.append(self.allocator, .{
            .id = op.id,
            .submitted_at = op.submitted_at,
            .validator = op.validator,
            .delegator = op.delegator,
            .amount = op.amount,
            .action = op.action,
            .metadata = try self.allocator.dupe(u8, op.metadata),
        });
        self.allocator.free(op.metadata);
    }

    fn injectReplayedGovernanceProposal(self: *Self, p: GovernanceProposal) !void {
        errdefer {
            self.allocator.free(p.title);
            self.allocator.free(p.description);
        }
        if (p.id >= self.next_proposal_id) self.next_proposal_id = p.id + 1;
        try self.proposals.append(self.allocator, .{
            .id = p.id,
            .proposer = p.proposer,
            .title = try self.allocator.dupe(u8, p.title),
            .description = try self.allocator.dupe(u8, p.description),
            .kind = p.kind,
            .activation_epoch = p.activation_epoch,
            .created_at = p.created_at,
            .status = p.status,
        });
        self.allocator.free(p.title);
        self.allocator.free(p.description);
    }

    fn injectReplayedGovernanceVote(self: *Self, vote: GovernanceVote) !void {
        try self.votes.append(self.allocator, vote);
    }

    fn deserializeGovernanceVoteWal(value: []const u8) !GovernanceVote {
        if (value.len != 61 or !std.mem.eql(u8, value[0..4], "m4v1")) return error.InvalidWalPayload;
        return .{
            .proposal_id = std.mem.readInt(u64, value[4..12], .big),
            .validator = value[12..44].*,
            .stake_weight = std.mem.readInt(u64, value[44..52], .big),
            .approve = value[52] != 0,
            .voted_at = std.mem.readInt(i64, value[53..61], .big),
        };
    }

    fn deserializeStakeOperationWal(self: *Self, value: []const u8) !StakeOperation {
        var off: usize = 0;
        if (value.len < 97 or !std.mem.eql(u8, value[0..4], "m4s1")) return error.InvalidWalPayload;
        off = 4;
        const id = std.mem.readInt(u64, value[off..][0..8], .big);
        off += 8;
        const submitted_at = std.mem.readInt(i64, value[off..][0..8], .big);
        off += 8;
        const validator = value[off..][0..32].*;
        off += 32;
        const delegator = value[off..][0..32].*;
        off += 32;
        const amount = std.mem.readInt(u64, value[off..][0..8], .big);
        off += 8;
        const action = std.enums.fromInt(StakeAction, value[off]) orelse return error.InvalidWalPayload;
        off += 1;
        const meta_len = std.mem.readInt(u32, value[off..][0..4], .big);
        off += 4;
        if (value.len < off + meta_len) return error.InvalidWalPayload;
        const metadata = try self.allocator.dupe(u8, value[off .. off + meta_len]);
        off += meta_len;
        if (off != value.len) return error.InvalidWalPayload;
        return .{
            .id = id,
            .submitted_at = submitted_at,
            .validator = validator,
            .delegator = delegator,
            .amount = amount,
            .action = action,
            .metadata = metadata,
        };
    }

    fn deserializeGovernanceProposalWal(self: *Self, value: []const u8) !GovernanceProposal {
        var off: usize = 0;
        if (value.len < 4 + 8 + 32 + 4 or !std.mem.eql(u8, value[0..4], "m4p1")) return error.InvalidWalPayload;
        off = 4;
        const id = std.mem.readInt(u64, value[off..][0..8], .big);
        off += 8;
        const proposer = value[off..][0..32].*;
        off += 32;
        const title_len = std.mem.readInt(u32, value[off..][0..4], .big);
        off += 4;
        if (value.len < off + title_len) return error.InvalidWalPayload;
        const title = try self.allocator.dupe(u8, value[off .. off + title_len]);
        off += title_len;
        const desc_len = std.mem.readInt(u32, value[off..][0..4], .big);
        off += 4;
        if (value.len < off + desc_len) return error.InvalidWalPayload;
        const description = try self.allocator.dupe(u8, value[off .. off + desc_len]);
        off += desc_len;
        if (value.len < off + 1) return error.InvalidWalPayload;
        const kind = std.enums.fromInt(GovernanceKind, value[off]) orelse return error.InvalidWalPayload;
        off += 1;
        var activation_epoch: ?u64 = null;
        if (value.len < off + 1) return error.InvalidWalPayload;
        const ae_flag = value[off];
        off += 1;
        if (ae_flag == 1) {
            if (value.len < off + 8) return error.InvalidWalPayload;
            activation_epoch = std.mem.readInt(u64, value[off..][0..8], .big);
            off += 8;
        } else if (ae_flag != 0) {
            return error.InvalidWalPayload;
        }
        if (value.len < off + 8 + 1) return error.InvalidWalPayload;
        const created_at = std.mem.readInt(i64, value[off..][0..8], .big);
        off += 8;
        const status = std.enums.fromInt(GovernanceStatus, value[off]) orelse return error.InvalidWalPayload;
        off += 1;
        if (off != value.len) return error.InvalidWalPayload;
        return .{
            .id = id,
            .proposer = proposer,
            .title = title,
            .description = description,
            .kind = kind,
            .activation_epoch = activation_epoch,
            .created_at = created_at,
            .status = status,
        };
    }

    /// Deterministic commitment over M4 manager state (for proofs and WAL replay).
    pub fn computeStateRoot(self: *Self) ![32]u8 {
        const asc_u64 = struct {
            fn less(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        };
        const asc_b32 = struct {
            fn less(_: void, a: [32]u8, b: [32]u8) bool {
                return std.mem.order(u8, &a, &b) == .lt;
            }
        };

        var ctx = Blake3.init(.{});
        var buf8: [8]u8 = undefined;
        var buf4: [4]u8 = undefined;

        std.mem.writeInt(u64, &buf8, self.next_stake_operation_id, .big);
        ctx.update(&buf8);
        std.mem.writeInt(u64, &buf8, self.next_proposal_id, .big);
        ctx.update(&buf8);
        std.mem.writeInt(u64, &buf8, @intCast(self.stake_ops.items.len), .big);
        ctx.update(&buf8);
        std.mem.writeInt(u64, &buf8, @intCast(self.proposals.items.len), .big);
        ctx.update(&buf8);
        std.mem.writeInt(u64, &buf8, self.total_slashed, .big);
        ctx.update(&buf8);

        // Stake operations (order-independent): hash by sorted id.
        {
            const n = self.stake_ops.items.len;
            const ids = try self.allocator.alloc(u64, n);
            defer self.allocator.free(ids);
            for (self.stake_ops.items, 0..) |op, j| ids[j] = op.id;
            std.mem.sort(u64, ids, {}, asc_u64.less);
            for (ids) |id| {
                for (self.stake_ops.items) |op| {
                    if (op.id != id) continue;
                    std.mem.writeInt(u64, &buf8, op.id, .big);
                    ctx.update(&buf8);
                    std.mem.writeInt(i64, &buf8, op.submitted_at, .big);
                    ctx.update(&buf8);
                    ctx.update(&op.validator);
                    ctx.update(&op.delegator);
                    std.mem.writeInt(u64, &buf8, op.amount, .big);
                    ctx.update(&buf8);
                    ctx.update(&.{@intFromEnum(op.action)});
                    std.mem.writeInt(u32, &buf4, @intCast(op.metadata.len), .big);
                    ctx.update(&buf4);
                    ctx.update(op.metadata);
                    break;
                }
            }
        }

        // Governance proposals by sorted id.
        {
            const n = self.proposals.items.len;
            const ids = try self.allocator.alloc(u64, n);
            defer self.allocator.free(ids);
            for (self.proposals.items, 0..) |p, j| ids[j] = p.id;
            std.mem.sort(u64, ids, {}, asc_u64.less);
            for (ids) |id| {
                for (self.proposals.items) |p| {
                    if (p.id != id) continue;
                    std.mem.writeInt(u64, &buf8, p.id, .big);
                    ctx.update(&buf8);
                    ctx.update(&p.proposer);
                    std.mem.writeInt(u32, &buf4, @intCast(p.title.len), .big);
                    ctx.update(&buf4);
                    ctx.update(p.title);
                    std.mem.writeInt(u32, &buf4, @intCast(p.description.len), .big);
                    ctx.update(&buf4);
                    ctx.update(p.description);
                    ctx.update(&.{@intFromEnum(p.kind)});
                    if (p.activation_epoch) |ae| {
                        ctx.update(&.{1});
                        std.mem.writeInt(u64, &buf8, ae, .big);
                        ctx.update(&buf8);
                    } else {
                        ctx.update(&.{0});
                    }
                    std.mem.writeInt(i64, &buf8, p.created_at, .big);
                    ctx.update(&buf8);
                    ctx.update(&.{@intFromEnum(p.status)});
                    break;
                }
            }
        }

        // Validator aggregate stake map (sorted keys).
        {
            const n = self.validator_stake.count();
            const keys = try self.allocator.alloc([32]u8, n);
            defer self.allocator.free(keys);
            var it = self.validator_stake.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                keys[i] = e.key_ptr.*;
            }
            std.mem.sort([32]u8, keys, {}, asc_b32.less);
            for (keys) |k| {
                const st = self.validator_stake.get(k) orelse continue;
                ctx.update(&k);
                std.mem.writeInt(u64, &buf8, st, .big);
                ctx.update(&buf8);
            }
        }

        // Delegations (sorted composite key).
        {
            const n = self.delegations.count();
            var keys = try self.allocator.alloc(DelegationKey, n);
            defer self.allocator.free(keys);
            var dit = self.delegations.iterator();
            var j: usize = 0;
            while (dit.next()) |e| : (j += 1) {
                keys[j] = e.key_ptr.*;
            }
            std.mem.sort(DelegationKey, keys, {}, struct {
                fn lt(_: void, a: DelegationKey, b: DelegationKey) bool {
                    const o = std.mem.order(u8, &a.validator, &b.validator);
                    if (o != .eq) return o == .lt;
                    return std.mem.order(u8, &a.delegator, &b.delegator) == .lt;
                }
            }.lt);
            for (keys) |k| {
                const amt = self.delegations.get(k) orelse continue;
                ctx.update(&k.validator);
                ctx.update(&k.delegator);
                std.mem.writeInt(u64, &buf8, amt, .big);
                ctx.update(&buf8);
            }
        }

        // Processed evidence ids (sorted).
        {
            const n = self.processed_evidence.count();
            var ev = try self.allocator.alloc([32]u8, n);
            defer self.allocator.free(ev);
            var eit = self.processed_evidence.iterator();
            var k: usize = 0;
            while (eit.next()) |e| : (k += 1) {
                ev[k] = e.key_ptr.*;
            }
            std.mem.sort([32]u8, ev, {}, asc_b32.less);
            for (ev) |h| ctx.update(&h);
        }

        var out: [32]u8 = undefined;
        ctx.final(&out);
        return out;
    }

    /// Serialize full M4 manager state into a binary blob for snapshot WAL records.
    /// Format: "m4ss" v1 + all fields in deterministic order.
    pub fn serializeStateSnapshot(self: *Self) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        const W = struct {
            fn appendU64(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, v, .big);
                try list.appendSlice(allocator, &b);
            }
            fn appendI64(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i64) !void {
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, v, .big);
                try list.appendSlice(allocator, &b);
            }
            fn appendU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, v, .big);
                try list.appendSlice(allocator, &b);
            }
        };

        try buf.appendSlice(self.allocator, "m4ss");
        try buf.append(self.allocator, 1); // version

        try W.appendU64(&buf, self.allocator, self.next_stake_operation_id);
        try W.appendU64(&buf, self.allocator, self.next_proposal_id);
        try W.appendU64(&buf, self.allocator, self.total_slashed);
        try W.appendU64(&buf, self.allocator, self.current_epoch);
        try buf.appendSlice(self.allocator, &self.validator_set_hash);

        // Stake operations (sorted by id)
        {
            const n = self.stake_ops.items.len;
            try W.appendU32(&buf, self.allocator, @intCast(n));
            const ids = try self.allocator.alloc(u64, n);
            defer self.allocator.free(ids);
            for (self.stake_ops.items, 0..) |op, j| ids[j] = op.id;
            std.mem.sort(u64, ids, {}, struct { fn less(_: void, a: u64, b: u64) bool { return a < b; } }.less);
            for (ids) |id| {
                for (self.stake_ops.items) |op| {
                    if (op.id != id) continue;
                    try W.appendU64(&buf, self.allocator, op.id);
                    try W.appendI64(&buf, self.allocator, op.submitted_at);
                    try buf.appendSlice(self.allocator, &op.validator);
                    try buf.appendSlice(self.allocator, &op.delegator);
                    try W.appendU64(&buf, self.allocator, op.amount);
                    try buf.append(self.allocator, @intFromEnum(op.action));
                    try W.appendU32(&buf, self.allocator, @intCast(op.metadata.len));
                    try buf.appendSlice(self.allocator, op.metadata);
                    break;
                }
            }
        }

        // Proposals (sorted by id)
        {
            const n = self.proposals.items.len;
            try W.appendU32(&buf, self.allocator, @intCast(n));
            const ids = try self.allocator.alloc(u64, n);
            defer self.allocator.free(ids);
            for (self.proposals.items, 0..) |p, j| ids[j] = p.id;
            std.mem.sort(u64, ids, {}, struct { fn less(_: void, a: u64, b: u64) bool { return a < b; } }.less);
            for (ids) |id| {
                for (self.proposals.items) |p| {
                    if (p.id != id) continue;
                    try W.appendU64(&buf, self.allocator, p.id);
                    try buf.appendSlice(self.allocator, &p.proposer);
                    try W.appendU32(&buf, self.allocator, @intCast(p.title.len));
                    try buf.appendSlice(self.allocator, p.title);
                    try W.appendU32(&buf, self.allocator, @intCast(p.description.len));
                    try buf.appendSlice(self.allocator, p.description);
                    try buf.append(self.allocator, @intFromEnum(p.kind));
                    if (p.activation_epoch) |ae| {
                        try buf.append(self.allocator, 1);
                        try W.appendU64(&buf, self.allocator, ae);
                    } else {
                        try buf.append(self.allocator, 0);
                    }
                    try W.appendI64(&buf, self.allocator, p.created_at);
                    try buf.append(self.allocator, @intFromEnum(p.status));
                    break;
                }
            }
        }

        // Votes
        {
            try W.appendU32(&buf, self.allocator, @intCast(self.votes.items.len));
            for (self.votes.items) |v| {
                try W.appendU64(&buf, self.allocator, v.proposal_id);
                try buf.appendSlice(self.allocator, &v.validator);
                try W.appendU64(&buf, self.allocator, v.stake_weight);
                try buf.append(self.allocator, if (v.approve) 1 else 0);
                try W.appendI64(&buf, self.allocator, v.voted_at);
            }
        }

        // Validator stake (sorted by key)
        {
            const n = self.validator_stake.count();
            try W.appendU32(&buf, self.allocator, @intCast(n));
            var keys = try self.allocator.alloc([32]u8, n);
            defer self.allocator.free(keys);
            var it = self.validator_stake.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
            std.mem.sort([32]u8, keys, {}, struct { fn less(_: void, a: [32]u8, b: [32]u8) bool { return std.mem.order(u8, &a, &b) == .lt; } }.less);
            for (keys) |k| {
                const st = self.validator_stake.get(k) orelse continue;
                try buf.appendSlice(self.allocator, &k);
                try W.appendU64(&buf, self.allocator, st);
            }
        }

        // Delegations (sorted composite key)
        {
            const n = self.delegations.count();
            try W.appendU32(&buf, self.allocator, @intCast(n));
            var keys = try self.allocator.alloc(DelegationKey, n);
            defer self.allocator.free(keys);
            var dit = self.delegations.iterator();
            var j: usize = 0;
            while (dit.next()) |e| : (j += 1) keys[j] = e.key_ptr.*;
            std.mem.sort(DelegationKey, keys, {}, struct {
                fn lt(_: void, a: DelegationKey, b: DelegationKey) bool {
                    const o = std.mem.order(u8, &a.validator, &b.validator);
                    if (o != .eq) return o == .lt;
                    return std.mem.order(u8, &a.delegator, &b.delegator) == .lt;
                }
            }.lt);
            for (keys) |k| {
                const amt = self.delegations.get(k) orelse continue;
                try buf.appendSlice(self.allocator, &k.validator);
                try buf.appendSlice(self.allocator, &k.delegator);
                try W.appendU64(&buf, self.allocator, amt);
            }
        }

        // Processed evidence (sorted)
        {
            const n = self.processed_evidence.count();
            try W.appendU32(&buf, self.allocator, @intCast(n));
            var ev = try self.allocator.alloc([32]u8, n);
            defer self.allocator.free(ev);
            var eit = self.processed_evidence.iterator();
            var k: usize = 0;
            while (eit.next()) |e| : (k += 1) ev[k] = e.key_ptr.*;
            std.mem.sort([32]u8, ev, {}, struct { fn less(_: void, a: [32]u8, b: [32]u8) bool { return std.mem.order(u8, &a, &b) == .lt; } }.less);
            for (ev) |h| try buf.appendSlice(self.allocator, &h);
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// Deserialize a state snapshot blob and replace all in-memory M4 state.
    pub fn deserializeStateSnapshot(self: *Self, data: []const u8) !void {
        if (data.len < 5 or !std.mem.eql(u8, data[0..4], "m4ss")) return error.InvalidWalPayload;
        if (data[4] != 1) return error.InvalidWalPayload;
        var off: usize = 5;

        const R = struct {
            fn readU64(d: []const u8, o: *usize) !u64 {
                if (o.* + 8 > d.len) return error.InvalidWalPayload;
                const v = std.mem.readInt(u64, d[o.*..][0..8], .big);
                o.* += 8;
                return v;
            }
            fn readI64(d: []const u8, o: *usize) !i64 {
                if (o.* + 8 > d.len) return error.InvalidWalPayload;
                const v = std.mem.readInt(i64, d[o.*..][0..8], .big);
                o.* += 8;
                return v;
            }
            fn readU32(d: []const u8, o: *usize) !u32 {
                if (o.* + 4 > d.len) return error.InvalidWalPayload;
                const v = std.mem.readInt(u32, d[o.*..][0..4], .big);
                o.* += 4;
                return v;
            }
            fn readBytes(d: []const u8, o: *usize, len: usize) ![]const u8 {
                if (o.* + len > d.len) return error.InvalidWalPayload;
                const v = d[o.*..][0..len];
                o.* += len;
                return v;
            }
            fn readArray(comptime N: usize, d: []const u8, o: *usize) ![N]u8 {
                if (o.* + N > d.len) return error.InvalidWalPayload;
                const v = d[o.*..][0..N].*;
                o.* += N;
                return v;
            }
        };

        self.next_stake_operation_id = try R.readU64(data, &off);
        self.next_proposal_id = try R.readU64(data, &off);
        self.total_slashed = try R.readU64(data, &off);
        self.current_epoch = try R.readU64(data, &off);
        self.validator_set_hash = try R.readArray(32, data, &off);

        // Clear existing collections
        for (self.stake_ops.items) |op| self.allocator.free(op.metadata);
        self.stake_ops.clearRetainingCapacity();
        for (self.proposals.items) |p| {
            self.allocator.free(p.title);
            self.allocator.free(p.description);
        }
        self.proposals.clearRetainingCapacity();
        self.votes.clearRetainingCapacity();
        self.validator_stake.clearRetainingCapacity();
        self.delegations.clearRetainingCapacity();
        self.processed_evidence.clearRetainingCapacity();

        // Stake operations
        {
            const n = try R.readU32(data, &off);
            for (0..n) |_| {
                const id = try R.readU64(data, &off);
                const submitted_at = try R.readI64(data, &off);
                const validator = try R.readArray(32, data, &off);
                const delegator = try R.readArray(32, data, &off);
                const amount = try R.readU64(data, &off);
                const action = std.enums.fromInt(StakeAction, data[off]) orelse return error.InvalidWalPayload;
                off += 1;
                const meta_len = try R.readU32(data, &off);
                const metadata = try self.allocator.dupe(u8, try R.readBytes(data, &off, meta_len));
                try self.stake_ops.append(self.allocator, .{
                    .id = id, .submitted_at = submitted_at, .validator = validator,
                    .delegator = delegator, .amount = amount, .action = action, .metadata = metadata,
                });
            }
        }

        // Proposals
        {
            const n = try R.readU32(data, &off);
            for (0..n) |_| {
                const id = try R.readU64(data, &off);
                const proposer = try R.readArray(32, data, &off);
                const title_len = try R.readU32(data, &off);
                const title = try self.allocator.dupe(u8, try R.readBytes(data, &off, title_len));
                const desc_len = try R.readU32(data, &off);
                const description = try self.allocator.dupe(u8, try R.readBytes(data, &off, desc_len));
                const kind = std.enums.fromInt(GovernanceKind, data[off]) orelse return error.InvalidWalPayload;
                off += 1;
                const ae_flag = data[off];
                off += 1;
                var activation_epoch: ?u64 = null;
                if (ae_flag == 1) {
                    activation_epoch = try R.readU64(data, &off);
                } else if (ae_flag != 0) {
                    return error.InvalidWalPayload;
                }
                const created_at = try R.readI64(data, &off);
                const status = std.enums.fromInt(GovernanceStatus, data[off]) orelse return error.InvalidWalPayload;
                off += 1;
                try self.proposals.append(self.allocator, .{
                    .id = id, .proposer = proposer, .title = title, .description = description,
                    .kind = kind, .activation_epoch = activation_epoch, .created_at = created_at, .status = status,
                });
            }
        }

        // Votes
        {
            const n = try R.readU32(data, &off);
            for (0..n) |_| {
                const proposal_id = try R.readU64(data, &off);
                const validator = try R.readArray(32, data, &off);
                const stake_weight = try R.readU64(data, &off);
                const approve = data[off] != 0;
                off += 1;
                const voted_at = try R.readI64(data, &off);
                try self.votes.append(self.allocator, .{
                    .proposal_id = proposal_id, .validator = validator, .stake_weight = stake_weight,
                    .approve = approve, .voted_at = voted_at,
                });
            }
        }

        // Validator stake
        {
            const n = try R.readU32(data, &off);
            for (0..n) |_| {
                const key = try R.readArray(32, data, &off);
                const val = try R.readU64(data, &off);
                try self.validator_stake.put(self.allocator, key, val);
            }
        }

        // Delegations
        {
            const n = try R.readU32(data, &off);
            for (0..n) |_| {
                const validator = try R.readArray(32, data, &off);
                const delegator = try R.readArray(32, data, &off);
                const amt = try R.readU64(data, &off);
                try self.delegations.put(self.allocator, .{ .validator = validator, .delegator = delegator }, amt);
            }
        }

        // Processed evidence
        {
            const n = try R.readU32(data, &off);
            for (0..n) |_| {
                const eid = try R.readArray(32, data, &off);
                try self.processed_evidence.put(self.allocator, eid, {});
            }
        }
    }

    pub fn appendStateSnapshotWal(self: *Self) !void {
        const w = self.m4_wal orelse return;
        const payload = try self.serializeStateSnapshot();
        defer self.allocator.free(payload);
        try w.logExtensionRecord(.m4_state_snapshot, payload);
        try w.syncAll();
    }
};

fn nowSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

test "mainnet hooks allocate ids monotonically" {
    const allocator = std.testing.allocator;
    var mgr = try Manager.init(allocator);
    defer mgr.deinit();

    const op_id_1 = try mgr.submitStakeOperation(.{
        .validator = [_]u8{1} ** 32,
        .delegator = [_]u8{2} ** 32,
        .amount = 10,
        .action = .stake,
    });
    const op_id_2 = try mgr.submitStakeOperation(.{
        .validator = [_]u8{1} ** 32,
        .delegator = [_]u8{2} ** 32,
        .amount = 5,
        .action = .unstake,
    });
    try std.testing.expectEqual(@as(u64, 1), op_id_1);
    try std.testing.expectEqual(@as(u64, 2), op_id_2);
}

test "mainnet hooks governance proposal id increments" {
    const allocator = std.testing.allocator;
    var mgr = try Manager.init(allocator);
    defer mgr.deinit();

    const p1 = try mgr.submitGovernanceProposal(.{
        .proposer = [_]u8{9} ** 32,
        .title = "t1",
        .description = "d1",
        .kind = .parameter_change,
    });
    const p2 = try mgr.submitGovernanceProposal(.{
        .proposer = [_]u8{9} ** 32,
        .title = "t2",
        .description = "d2",
        .kind = .chain_upgrade,
    });
    try std.testing.expectEqual(@as(u64, 1), p1);
    try std.testing.expectEqual(@as(u64, 2), p2);
}

test "mainnet hooks apply stake and slash to validator stake" {
    const allocator = std.testing.allocator;
    var mgr = try Manager.init(allocator);
    defer mgr.deinit();

    const validator = [_]u8{7} ** 32;
    const delegator = [_]u8{8} ** 32;

    _ = try mgr.submitStakeOperation(.{
        .validator = validator,
        .delegator = delegator,
        .amount = 100,
        .action = .stake,
    });
    try std.testing.expectEqual(@as(u64, 100), mgr.getValidatorStake(validator));

    _ = try mgr.submitStakeOperation(.{
        .validator = validator,
        .delegator = delegator,
        .amount = 30,
        .action = .slash,
        .metadata = "equivocation",
    });
    try std.testing.expectEqual(@as(u64, 70), mgr.getValidatorStake(validator));
    try std.testing.expectEqual(@as(u64, 30), mgr.getTotalSlashed());
}

test "mainnet hooks buildCheckpointProof emits canonical signing payload" {
    const allocator = std.testing.allocator;
    var mgr = try Manager.init(allocator);
    defer mgr.deinit();

    const proof = try mgr.buildCheckpointProof(.{
        .sequence = 9,
        .object_id = [_]u8{0xAB} ** 32,
    });
    defer mgr.freeCheckpointProof(proof);

    const expected = m4ProofSigningMessage(proof.state_root, 9, [_]u8{0xAB} ** 32);
    try std.testing.expectEqual(@as(usize, 80), proof.proof_bytes.len);
    try std.testing.expect(std.mem.eql(u8, proof.proof_bytes, &expected));
    try std.testing.expectEqual(@as(usize, 0), proof.signatures.len);
}

test "equivocation evidence replay is deduplicated" {
    const allocator = std.testing.allocator;
    var mgr = try Manager.init(allocator);
    defer mgr.deinit();

    const validator = [_]u8{0x22} ** 32;
    const delegator = [_]u8{0x33} ** 32;

    _ = try mgr.submitStakeOperation(.{
        .validator = validator,
        .delegator = delegator,
        .amount = 50,
        .action = .stake,
    });

    const evidence = "vote_a_vs_vote_b";
    const first_applied = try mgr.applyEquivocationEvidence(validator, delegator, 44, evidence, 10);
    const second_applied = try mgr.applyEquivocationEvidence(validator, delegator, 44, evidence, 10);

    try std.testing.expect(first_applied);
    try std.testing.expect(!second_applied);
    try std.testing.expectEqual(@as(u64, 10), mgr.getTotalSlashed());
    try std.testing.expectEqual(@as(u64, 40), mgr.getValidatorStake(validator));
}

test "governance vote WAL roundtrip" {
    const allocator = std.testing.allocator;
    var mgr = try Manager.init(allocator);
    defer mgr.deinit();

    const validator = [_]u8{0x11} ** 32;
    try mgr.validator_stake.put(allocator, validator, 500);

    // Create a proposal first (votes need a proposal to exist)
    _ = try mgr.submitGovernanceProposal(.{
        .proposer = validator,
        .title = "test",
        .description = "desc",
        .kind = .parameter_change,
        .activation_epoch = 5,
    });

    // Cast a vote
    try mgr.voteOnProposal(1, validator, true);
    try std.testing.expectEqual(@as(usize, 1), mgr.votes.items.len);

    // Simulate WAL replay by clearing votes and re-injecting
    mgr.votes.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), mgr.votes.items.len);

    // Manually construct the WAL payload and replay
    var buf: [61]u8 = undefined;
    @memcpy(buf[0..4], "m4v1");
    std.mem.writeInt(u64, buf[4..12], 1, .big);
    @memcpy(buf[12..44], &validator);
    std.mem.writeInt(u64, buf[44..52], 500, .big);
    buf[52] = 1;
    std.mem.writeInt(i64, buf[53..61], 1234567890, .big);

    const vote = try Manager.deserializeGovernanceVoteWal(&buf);
    try mgr.injectReplayedGovernanceVote(vote);

    try std.testing.expectEqual(@as(usize, 1), mgr.votes.items.len);
    try std.testing.expectEqual(@as(u64, 1), mgr.votes.items[0].proposal_id);
    try std.testing.expect(mgr.votes.items[0].approve);
    try std.testing.expectEqual(@as(u64, 500), mgr.votes.items[0].stake_weight);
}

test "M4 state snapshot roundtrip" {
    const allocator = std.testing.allocator;
    var mgr = try Manager.init(allocator);
    defer mgr.deinit();

    const validator = [_]u8{0x22} ** 32;
    const delegator = [_]u8{0x33} ** 32;

    // Populate some state
    try mgr.validator_stake.put(allocator, validator, 1000);
    try mgr.delegations.put(allocator, .{ .validator = validator, .delegator = delegator }, 500);
    _ = try mgr.submitStakeOperation(.{
        .validator = validator, .delegator = delegator, .amount = 500, .action = .stake, .metadata = "test",
    });
    _ = try mgr.submitGovernanceProposal(.{
        .proposer = validator, .title = "p1", .description = "d1", .kind = .parameter_change, .activation_epoch = 3,
    });
    try mgr.voteOnProposal(1, validator, true);
    try mgr.processed_evidence.put(allocator, [_]u8{0xEE} ** 32, {});
    mgr.current_epoch = 7;
    mgr.validator_set_hash = [_]u8{0xAA} ** 32;
    mgr.total_slashed = 50;

    // Serialize snapshot
    const snapshot = try mgr.serializeStateSnapshot();
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.startsWith(u8, snapshot, "m4ss"));

    // Clear and restore
    var mgr2 = try Manager.init(allocator);
    defer mgr2.deinit();
    try mgr2.deserializeStateSnapshot(snapshot);

    // Verify restored state
    try std.testing.expectEqual(@as(u64, 7), mgr2.current_epoch);
    try std.testing.expectEqual(@as(u64, 50), mgr2.total_slashed);
    try std.testing.expectEqual(@as(u64, 1), mgr2.stake_ops.items.len);
    try std.testing.expectEqual(@as(u64, 1), mgr2.proposals.items.len);
    try std.testing.expectEqual(@as(usize, 1), mgr2.votes.items.len);
    // submitStakeOperation added 500 to the pre-existing 1000/500 stakes
    try std.testing.expectEqual(@as(u64, 1500), mgr2.validator_stake.get(validator).?);
    try std.testing.expectEqual(@as(u64, 1000), mgr2.delegations.get(.{ .validator = validator, .delegator = delegator }).?);
    try std.testing.expect(mgr2.processed_evidence.contains([_]u8{0xEE} ** 32));
    try std.testing.expect(std.mem.eql(u8, &mgr2.validator_set_hash, &[_]u8{0xAA} ** 32));
}
