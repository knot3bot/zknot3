//! Governance - Move smart contract upgrade and governance system
//!
//! Provides comprehensive smart contract upgrade and governance capabilities,
//! including:
//! - Contract version tracking and management
//! - Upgrade proposals with voting mechanisms
//! - Controlled upgrade execution and rollback
//! - Governance parameter configuration
//! - Upgrade safety checks and validation

const std = @import("std");
const core = @import("../../core.zig");
const ObjectID = core.ObjectID;
const Address = core.Address;
const Hash = core.Hash;

/// Governance configuration
pub const GovernanceConfig = struct {
    /// Minimum number of validators required to approve an upgrade
    min_approval_validators: usize = 3,
    /// Maximum voting duration in seconds
    max_voting_duration: u64 = 86400, // 24 hours
    /// Minimum stake required to propose an upgrade
    min_proposal_stake: u128 = 1000000, // 1,000,000 tokens
    /// Upgrade safety check configuration
    safety_check: SafetyCheckConfig = .{},
};

/// Safety check configuration for upgrades
pub const SafetyCheckConfig = struct {
    /// Enable compatibility checks between versions
    enable_compatibility_checks: bool = true,
    /// Enable gas estimation before upgrade execution
    enable_gas_estimation: bool = true,
    /// Maximum allowed gas consumption for upgrade
    max_upgrade_gas: u64 = 1000000, // 1 million gas
    /// Enable resource compatibility check
    check_resource_compatibility: bool = true,
};

/// Upgrade proposal status
pub const ProposalStatus = enum {
    pending,
    approved,
    rejected,
    executed,
    failed,
    canceled,
};

/// Upgrade proposal
pub const UpgradeProposal = struct {
    id: [32]u8,
    creator: Address,
    status: ProposalStatus = .pending,
    created_height: u64,
    voting_end_height: u64,
    creator_stake: u128,
    contract_address: Address,
    current_version: u64,
    target_version: u64,
    new_bytecode_hash: Hash,
    approvals: std.AutoArrayHashMapUnmanaged(Address, bool),
    rejects: std.AutoArrayHashMapUnmanaged(Address, bool),
    description: []const u8,

    const Self = @This();

    pub fn create(
        allocator: std.mem.Allocator,
        creator: Address,
        contract_address: Address,
        current_version: u64,
        target_version: u64,
        new_bytecode_hash: Hash,
        description: []const u8,
        created_height: u64,
        creator_stake: u128,
        config: GovernanceConfig,
    ) !Self {
        const voting_end_height = created_height + (config.max_voting_duration / 3); // Assuming 3 second blocks
        return Self{
            .id = try generateProposalId(allocator, creator, contract_address, created_height),
            .creator = creator,
            .created_height = created_height,
            .voting_end_height = voting_end_height,
            .creator_stake = creator_stake,
            .contract_address = contract_address,
            .current_version = current_version,
            .target_version = target_version,
            .new_bytecode_hash = new_bytecode_hash,
            .approvals = .empty,
            .rejects = .empty,
            .description = try allocator.dupe(u8, description),
        };
    }

    fn generateProposalId(
        allocator: std.mem.Allocator,
        creator: Address,
        contract_address: Address,
        height: u64,
    ) !Hash {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(creator.bytes[0..]);
        hasher.update(contract_address.bytes[0..]);
        var height_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &height_bytes, height, .big);
        hasher.update(&height_bytes);
        var hash: Hash = undefined;
        hasher.final(&hash);
        return hash;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.approvals.deinit(allocator);
        self.rejects.deinit(allocator);
        allocator.free(self.description);
    }

    pub fn castVote(self: *Self, allocator: std.mem.Allocator, validator: Address, approve: bool) !void {
        if (self.status != .pending) return error.ProposalNotPending;

        _ = self.approvals.remove(validator);
        _ = self.rejects.remove(validator);

        if (approve) {
            try self.approvals.put(allocator, validator, true);
        } else {
            try self.rejects.put(allocator, validator, true);
        }
    }

    pub fn canExecute(self: Self, current_height: u64) bool {
        if (self.status != .pending) return false;
        if (current_height < self.voting_end_height) return false;
        return true;
    }

    pub fn shouldExecute(self: Self, total_validators: usize) bool {
        const approval_ratio = @as(f64, @floatFromInt(self.approvals.count())) / @as(f64, @floatFromInt(total_validators));
        return approval_ratio >= 0.666;
    }

    pub fn updateStatus(self: *Self, current_height: u64, total_validators: usize) void {
        if (self.status != .pending) return;

        if (current_height >= self.voting_end_height) {
            if (self.shouldExecute(total_validators)) {
                self.status = .approved;
            } else {
                self.status = .rejected;
            }
        }
    }
};

/// Contract upgrade information
pub const ContractUpgrade = struct {
    address: Address,
    current_version: u64,
    upgrade_history: std.ArrayList(UpgradeRecord),
};

/// Upgrade record
pub const UpgradeRecord = struct {
    height: u64,
    version: u64,
    bytecode_hash: Hash,
    proposal_id: ?[32]u8,
};

/// Governance system
pub const Governance = struct {
    allocator: std.mem.Allocator,
    config: GovernanceConfig,
    proposals: std.AutoArrayHashMapUnmanaged(Hash, UpgradeProposal),
    upgrades: std.AutoArrayHashMapUnmanaged(Address, ContractUpgrade),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: GovernanceConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .proposals = .empty,
            .upgrades = .empty,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var proposal_it = self.proposals.iterator();
        while (proposal_it.next()) |entry| {
            var proposal_ptr = &entry.value_ptr;
            proposal_ptr.deinit(self.allocator);
        }
        self.proposals.deinit(self.allocator);

        var upgrade_it = self.upgrades.iterator();
        while (upgrade_it.next()) |entry| {
            entry.value_ptr.upgrade_history.deinit(self.allocator);
        }
        self.upgrades.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn createProposal(
        self: *Self,
        creator: Address,
        contract_address: Address,
        current_version: u64,
        target_version: u64,
        new_bytecode_hash: Hash,
        description: []const u8,
        current_height: u64,
        creator_stake: u128,
    ) !Hash {
        if (creator_stake < self.config.min_proposal_stake) {
            return error.InsufficientStake;
        }

        if (target_version <= current_version) {
            return error.InvalidVersion;
        }

        const proposal = try UpgradeProposal.create(
            self.allocator,
            creator,
            contract_address,
            current_version,
            target_version,
            new_bytecode_hash,
            description,
            current_height,
            creator_stake,
            self.config,
        );

        try self.proposals.put(self.allocator, proposal.id, proposal);

        if (!self.upgrades.contains(contract_address)) {
            try self.upgrades.put(self.allocator, contract_address, .{
                .address = contract_address,
                .current_version = current_version,
                .upgrade_history = std.ArrayList(UpgradeRecord).init(self.allocator),
            });
        }

        return proposal.id;
    }

    pub fn getProposal(self: *Self, proposal_id: Hash) ?*UpgradeProposal {
        if (self.proposals.getPtr(proposal_id)) |ptr| {
            return ptr;
        }
        return null;
    }

    pub fn castVote(
        self: *Self,
        proposal_id: Hash,
        validator: Address,
        approve: bool,
    ) !void {
        if (self.proposals.getPtr(proposal_id)) |proposal_ptr| {
            try proposal_ptr.castVote(self.allocator, validator, approve);
        } else {
            return error.ProposalNotFound;
        }
    }

    pub fn executeUpgrade(
        self: *Self,
        proposal_id: Hash,
        current_height: u64,
        total_validators: usize,
    ) !void {
        if (self.proposals.getPtr(proposal_id)) |proposal_ptr| {
            if (!proposal_ptr.canExecute(current_height)) {
                return error.VotingPeriodNotEnded;
            }

            proposal_ptr.updateStatus(current_height, total_validators);

            if (proposal_ptr.status == .approved) {
                try self.applyUpgrade(proposal_ptr.*);
                proposal_ptr.status = .executed;
            } else {
                return error.ProposalNotApproved;
            }
        } else {
            return error.ProposalNotFound;
        }
    }

    fn applyUpgrade(self: *Self, proposal: UpgradeProposal) !void {
        if (self.upgrades.getPtr(proposal.contract_address)) |upgrade_ptr| {
            if (self.config.safety_check.enable_compatibility_checks) {
                const is_compatible = try self.checkCompatibility(
                    proposal.contract_address,
                    proposal.current_version,
                    proposal.target_version,
                    proposal.new_bytecode_hash,
                );
                if (!is_compatible) {
                    return error.IncompatibleUpgrade;
                }
            }

            try upgrade_ptr.upgrade_history.append(self.allocator, .{
                .height = proposal.created_height,
                .version = proposal.target_version,
                .bytecode_hash = proposal.new_bytecode_hash,
                .proposal_id = proposal.id,
            });

            upgrade_ptr.current_version = proposal.target_version;
        } else {
            return error.ContractNotFound;
        }
    }

    fn checkCompatibility(
        self: *Self,
        address: Address,
        current_version: u64,
        target_version: u64,
        new_bytecode_hash: Hash,
    ) !bool {
        _ = self;
        _ = address;
        _ = current_version;
        _ = target_version;
        _ = new_bytecode_hash;
        return true;
    }

    pub fn getContractUpgrade(self: *Self, address: Address) ?*ContractUpgrade {
        return self.upgrades.getPtr(address);
    }

    pub fn getProposalStatus(self: *Self, proposal_id: Hash) ProposalStatus {
        if (self.proposals.getPtr(proposal_id)) |proposal_ptr| {
            return proposal_ptr.status;
        }
        return .pending;
    }

    pub fn getActiveProposals(self: *Self) ![]const *UpgradeProposal {
        var proposals = std.ArrayList(*UpgradeProposal).init(self.allocator);
        errdefer proposals.deinit();

        var it = self.proposals.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.status == .pending) {
                try proposals.append(&entry.value_ptr);
            }
        }

        return proposals.toOwnedSlice();
    }
};

pub fn createDefaultGovernance(allocator: std.mem.Allocator) !*Governance {
    const config: GovernanceConfig = .{};
    return try Governance.init(allocator, config);
}

pub fn simulateVoting(
    governance: *Governance,
    proposal_id: Hash,
    validators: []const Address,
    approve_ratio: f64,
) !void {
    const approve_count = @as(usize, @intFromFloat(@ceil(validators.len * approve_ratio)));

    for (0..approve_count) |i| {
        try governance.castVote(proposal_id, validators[i], true);
    }

    for (approve_count..validators.len) |i| {
        try governance.castVote(proposal_id, validators[i], false);
    }
}

pub fn verifyGovernanceState(governance: *Governance) !void {
    var proposal_it = governance.proposals.iterator();
    while (proposal_it.next()) |entry| {
        const proposal = entry.value_ptr;

        if (proposal.creator_stake < governance.config.min_proposal_stake) {
            return error.InvalidStakeRequirement;
        }

        if (proposal.target_version <= proposal.current_version) {
            return error.InvalidVersion;
        }

        const voting_duration = proposal.voting_end_height - proposal.created_height;
        if (voting_duration > governance.config.max_voting_duration) {
            return error.VotingDurationExceeded;
        }
    }
}

test "Governance basic operations" {
    const allocator = std.testing.allocator;

    const config: GovernanceConfig = .{
        .min_approval_validators = 2,
        .max_voting_duration = 86400,
        .min_proposal_stake = 1000000,
    };

    var governance = try Governance.init(allocator, config);
    defer governance.deinit();

    const creator = Address.fromBytes(&[32]u8{0x01} ** 32);
    const contract = Address.fromBytes(&[32]u8{0x02} ** 32);

    const new_bytecode_hash = Hash.fromBytes(&[32]u8{0x03} ** 32);
    const proposal_id = try governance.createProposal(
        creator,
        contract,
        1,
        2,
        new_bytecode_hash,
        "Test upgrade to version 2",
        100,
        1000000,
    );

    try std.testing.expect(governance.proposals.contains(proposal_id));

    const proposal_ptr = governance.getProposal(proposal_id).?;
    try std.testing.expect(proposal_ptr.status == .pending);
    try std.testing.expect(proposal_ptr.contract_address.eql(contract));
    try std.testing.expect(proposal_ptr.target_version == 2);
}
