//! Governance Vote Test - stake-weighted proposal voting, tally, and execution

const std = @import("std");
const MainnetExtensionHooks = @import("../../src/app/MainnetExtensionHooks.zig");
const Manager = MainnetExtensionHooks.Manager;
const GovernanceProposalInput = MainnetExtensionHooks.GovernanceProposalInput;
const GovernanceStatus = MainnetExtensionHooks.GovernanceStatus;
const GovernanceKind = MainnetExtensionHooks.GovernanceKind;

fn makeValidator(id: u8) [32]u8 {
    return [_]u8{id} ** 32;
}

test "governance: submit proposal and vote to approval" {
    const allocator = std.testing.allocator;
    var manager = try Manager.init(allocator);
    defer manager.deinit();

    // Seed validator stakes: total = 3000
    try manager.validator_stake.put(allocator, makeValidator(1), 1500);
    try manager.validator_stake.put(allocator, makeValidator(2), 1000);
    try manager.validator_stake.put(allocator, makeValidator(3), 500);

    const proposal_id = try manager.submitGovernanceProposal(.{
        .proposer = makeValidator(1),
        .title = "increase epoch duration",
        .description = "extend epoch from 1h to 2h",
        .kind = .parameter_change,
        .activation_epoch = 10,
    });

    // Vote: validator 1 (1500) yes, validator 2 (1000) yes
    // Total = 3000, approve threshold = 2000
    try manager.voteOnProposal(proposal_id, makeValidator(1), true);
    try manager.voteOnProposal(proposal_id, makeValidator(2), true);

    const status = manager.proposals.items[0].status;
    try std.testing.expectEqual(GovernanceStatus.approved, status);
}

test "governance: vote to rejection" {
    const allocator = std.testing.allocator;
    var manager = try Manager.init(allocator);
    defer manager.deinit();

    try manager.validator_stake.put(allocator, makeValidator(1), 1000);
    try manager.validator_stake.put(allocator, makeValidator(2), 1000);
    try manager.validator_stake.put(allocator, makeValidator(3), 1000);

    const proposal_id = try manager.submitGovernanceProposal(.{
        .proposer = makeValidator(1),
        .title = "reject me",
        .description = "should be rejected",
        .kind = .treasury_action,
    });

    // validator 1 yes, validator 2 no, validator 3 no
    // no_stake = 2000, reject_threshold = 1000 -> rejected
    try manager.voteOnProposal(proposal_id, makeValidator(1), true);
    try manager.voteOnProposal(proposal_id, makeValidator(2), false);
    try manager.voteOnProposal(proposal_id, makeValidator(3), false);

    const status = manager.proposals.items[0].status;
    try std.testing.expectEqual(GovernanceStatus.rejected, status);
}

test "governance: double vote rejected" {
    const allocator = std.testing.allocator;
    var manager = try Manager.init(allocator);
    defer manager.deinit();

    try manager.validator_stake.put(allocator, makeValidator(1), 1000);

    const proposal_id = try manager.submitGovernanceProposal(.{
        .proposer = makeValidator(1),
        .title = "test",
        .description = "double vote",
        .kind = .parameter_change,
    });

    try manager.voteOnProposal(proposal_id, makeValidator(1), true);
    try std.testing.expectError(error.InvalidGovernanceTransition, manager.voteOnProposal(proposal_id, makeValidator(1), false));
}

test "governance: zero-stake voter rejected" {
    const allocator = std.testing.allocator;
    var manager = try Manager.init(allocator);
    defer manager.deinit();

    const proposal_id = try manager.submitGovernanceProposal(.{
        .proposer = makeValidator(1),
        .title = "test",
        .description = "zero stake",
        .kind = .parameter_change,
    });

    try std.testing.expectError(error.InsufficientStake, manager.voteOnProposal(proposal_id, makeValidator(9), true));
}

test "governance: execute approved proposal" {
    const allocator = std.testing.allocator;
    var manager = try Manager.init(allocator);
    defer manager.deinit();

    try manager.validator_stake.put(allocator, makeValidator(1), 2000);
    try manager.validator_stake.put(allocator, makeValidator(2), 1000);

    const proposal_id = try manager.submitGovernanceProposal(.{
        .proposer = makeValidator(1),
        .title = "upgrade",
        .description = "v1 to v2",
        .kind = .chain_upgrade,
    });

    try manager.voteOnProposal(proposal_id, makeValidator(1), true);
    try std.testing.expectEqual(GovernanceStatus.approved, manager.proposals.items[0].status);

    try manager.executeProposal(proposal_id);
    try std.testing.expectEqual(GovernanceStatus.executed, manager.proposals.items[0].status);
}

test "governance: execute non-approved proposal fails" {
    const allocator = std.testing.allocator;
    var manager = try Manager.init(allocator);
    defer manager.deinit();

    try manager.validator_stake.put(allocator, makeValidator(1), 1000);

    const proposal_id = try manager.submitGovernanceProposal(.{
        .proposer = makeValidator(1),
        .title = "pending",
        .description = "not approved",
        .kind = .parameter_change,
    });

    try std.testing.expectError(error.InvalidGovernanceTransition, manager.executeProposal(proposal_id));
}
