//! EpochConsensusBridge -连接 Epoch 管理器和共识协议
//!
//! 负责：
//! - Epoch 变更时更新共识的验证者集合
//! - 跟踪每个 epoch 的投票权重
//! - 处理 epoch 边界验证者集合变更

const std = @import("std");
const EpochManager = @import("Epoch.zig").EpochManager;
const Epoch = @import("Epoch.zig").Epoch;
const StakePool = @import("Stake.zig").StakePool;
const Quorum = @import("../form/consensus/Quorum.zig").Quorum;
const Mysticeti = @import("../form/consensus/Mysticeti.zig").Mysticeti;

/// Epoch 边界事件
pub const EpochBoundaryEvent = struct {
    epoch_number: u64,
    timestamp: i64,
    validator_count: usize,
    total_stake: u128,
};

/// Epoch 与共识之间的桥接器
pub const EpochConsensusBridge = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    epoch_manager: *EpochManager,
    stake_pool: *StakePool,
    quorum: *Quorum,
    consensus: ?*Mysticeti,

    /// 待处理的 epoch 边界事件队列
    pending_events: std.ArrayList(EpochBoundaryEvent),

    pub fn init(
        allocator: std.mem.Allocator,
        epoch_manager: *EpochManager,
        stake_pool: *StakePool,
        quorum: *Quorum,
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .epoch_manager = epoch_manager,
            .stake_pool = stake_pool,
            .quorum = quorum,
            .consensus = null,
            .pending_events = try std.ArrayList(EpochBoundaryEvent).initCapacity(allocator, 16),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.pending_events.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 连接共识协议
    pub fn setConsensus(self: *Self, consensus: *Mysticeti) void {
        self.consensus = consensus;
    }

    /// 注册验证者的 stake
    pub fn registerValidatorStake(self: *Self, validator_id: [32]u8, stake: u128) !void {
        try self.stake_pool.addStake(validator_id, stake, true);
    }

    /// 在 epoch 边界更新共识
    pub fn onEpochBoundary(self: *Self) !void {
        const epoch = self.epoch_manager.getCurrentEpoch();

        // 记录 epoch 边界事件
        const event = EpochBoundaryEvent{
            .epoch_number = epoch.number,
            .timestamp = epoch.end_time,
            .validator_count = epoch.validator_count,
            .total_stake = epoch.total_stake,
        };
        try self.pending_events.append(self.allocator, event);

        // 如果有共识协议，更新它
        if (self.consensus) |consensus| {
            const epoch_info = self.getConsensusEpochInfo();
            consensus.onEpochChange(epoch_info.total_stake, epoch_info.validator_count);
        }
    }

    /// 检查是否需要 reconfiguration
    pub fn checkReconfiguration(self: *Self) bool {
        return self.epoch_manager.needsReconfiguration();
    }

    /// 获取当前 epoch 信息用于共识
    pub fn getConsensusEpochInfo(self: Self) ConsensusEpochInfo {
        const epoch = self.epoch_manager.getCurrentEpoch();
        return ConsensusEpochInfo{
            .epoch_number = epoch.number,
            .total_stake = epoch.total_stake,
            .validator_count = epoch.validator_count,
            .quorum_threshold = self.stake_pool.quorumThreshold(),
        };
    }

    /// 获取验证者的 epoch 投票权重
    pub fn getValidatorVotingPower(self: Self, validator_id: [32]u8) u128 {
        return self.stake_pool.getVotingPower(validator_id);
    }

    /// 处理 epoch 变更 - 当 epoch 结束时调用
    pub fn handleEpochChange(self: *Self, new_total_stake: u128, new_validator_count: usize) !void {
        try self.epoch_manager.advanceEpoch(new_total_stake, new_validator_count);
        try self.onEpochBoundary();
    }
};

/// 共识协议需要的 epoch 信息
pub const ConsensusEpochInfo = struct {
    epoch_number: u64,
    total_stake: u128,
    validator_count: usize,
    quorum_threshold: u128,
};

test "EpochConsensusBridge initialization" {
    const allocator = std.testing.allocator;

    var epoch_manager = try EpochManager.init(allocator, .{}, 1000);
    defer epoch_manager.deinit();

    var stake_pool = try StakePool.init(allocator);
    defer stake_pool.deinit();

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    var bridge = try EpochConsensusBridge.init(allocator, epoch_manager, stake_pool, quorum);
    defer bridge.deinit();

    try std.testing.expect(bridge.pending_events.items.len == 0);
}

test "EpochConsensusBridge validator stake" {
    const allocator = std.testing.allocator;

    var epoch_manager = try EpochManager.init(allocator, .{}, 1000);
    defer epoch_manager.deinit();

    var stake_pool = try StakePool.init(allocator);
    defer stake_pool.deinit();

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    var bridge = try EpochConsensusBridge.init(allocator, epoch_manager, stake_pool, quorum);
    defer bridge.deinit();

    const validator_id = [_]u8{1} ** 32;
    try bridge.registerValidatorStake(validator_id, 1000);

    const power = bridge.getValidatorVotingPower(validator_id);
    try std.testing.expect(power == 1000);
}

test "EpochConsensusBridge epoch info" {
    const allocator = std.testing.allocator;

    var epoch_manager = try EpochManager.init(allocator, .{}, 1000);
    defer epoch_manager.deinit();

    var stake_pool = try StakePool.init(allocator);
    defer stake_pool.deinit();

    var quorum = try Quorum.init(allocator);
    defer quorum.deinit();

    var bridge = try EpochConsensusBridge.init(allocator, epoch_manager, stake_pool, quorum);
    defer bridge.deinit();

    const validator_id = [_]u8{1} ** 32;
    try bridge.registerValidatorStake(validator_id, 4000);

    const info = bridge.getConsensusEpochInfo();
    try std.testing.expect(info.epoch_number == 0);
    try std.testing.expect(info.total_stake == 4000);
    try std.testing.expect(info.quorum_threshold == 2667); // 4000 * 2/3 + 1
}
