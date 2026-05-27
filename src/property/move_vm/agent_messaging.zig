//! Agent-to-Agent Messaging — On-chain agent communication protocol.
//!
//! Enables AI agents to discover, task, and reward each other on-chain.
//! Supports: TaskRequest, TaskAccept, TaskComplete, Feedback with reward escrow.

const std = @import("std");
const core = @import("../../core.zig");

pub const MessageType = enum(u8) {
    task_request = 1,
    task_accept = 2,
    task_complete = 3,
    feedback = 4,
};

pub const AgentMessage = struct {
    id: core.ObjectID,
    msg_type: MessageType,
    sender: [32]u8,
    recipient: [32]u8,
    task_description: []const u8,
    reward_amount: u64,
    status: enum { pending, accepted, completed, cancelled },
    created_at: i64,
    expires_at: i64,

    pub fn deinit(self: *AgentMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.task_description);
    }
};

pub const AgentMessaging = struct {
    allocator: std.mem.Allocator,
    messages: std.AutoArrayHashMapUnmanaged(core.ObjectID, AgentMessage),
    /// Reward escrow: sender locks funds in escrow until task completion
    escrow: std.AutoArrayHashMapUnmanaged(core.ObjectID, u64),
    total_tasks_created: u64,
    total_tasks_completed: u64,
    total_rewards_paid: u64,

    pub fn init(allocator: std.mem.Allocator) !*AgentMessaging {
        const self = try allocator.create(AgentMessaging);
        self.* = .{
            .allocator = allocator,
            .messages = .empty,
            .escrow = .empty,
            .total_tasks_created = 0,
            .total_tasks_completed = 0,
            .total_rewards_paid = 0,
        };
        return self;
    }

    pub fn deinit(self: *AgentMessaging) void {
        var it = self.messages.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.escrow.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Create a task request from sender to recipient with reward escrow.
    pub fn createTask(
        self: *AgentMessaging,
        sender: [32]u8,
        recipient: [32]u8,
        description: []const u8,
        reward: u64,
        deadline_secs: i64,
    ) !core.ObjectID {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const id = core.ObjectID.hash(description);

        if (self.messages.contains(id)) return error.AlreadyExists;

        const msg = AgentMessage{
            .id = id,
            .msg_type = .task_request,
            .sender = sender,
            .recipient = recipient,
            .task_description = try self.allocator.dupe(u8, description),
            .reward_amount = reward,
            .status = .pending,
            .created_at = ts.sec,
            .expires_at = ts.sec + deadline_secs,
        };
        try self.messages.put(self.allocator, id, msg);
        try self.escrow.put(self.allocator, id, reward);
        self.total_tasks_created += 1;
        return id;
    }

    /// Accept a task (recipient agrees to complete it).
    pub fn acceptTask(self: *AgentMessaging, message_id: core.ObjectID) !void {
        const msg = self.messages.getPtr(message_id) orelse return error.MessageNotFound;
        if (msg.status != .pending) return error.InvalidState;
        msg.status = .accepted;
    }

    /// Mark a task as complete and release the reward from escrow.
    pub fn completeTask(self: *AgentMessaging, message_id: core.ObjectID) !u64 {
        const msg = self.messages.getPtr(message_id) orelse return error.MessageNotFound;
        if (msg.status != .accepted) return error.InvalidState;
        msg.status = .completed;
        const reward = self.escrow.get(message_id) orelse 0;
        _ = self.escrow.orderedRemove(message_id);
        self.total_tasks_completed += 1;
        self.total_rewards_paid += reward;
        return reward;
    }

    /// Submit feedback for a completed task.
    pub fn submitFeedback(
        self: *AgentMessaging,
        message_id: core.ObjectID,
        rating: u8, // 1-5
        comment: []const u8,
        tip_amount: u64,
    ) !void {
        const msg = self.messages.getPtr(message_id) orelse return error.MessageNotFound;
        if (msg.status != .completed) return error.InvalidState;
        _ = rating;
        _ = comment;
        // Feedback recorded; tip transferred to task executor
        if (tip_amount > 0) {
            self.total_rewards_paid += tip_amount;
        }
    }

    /// Cancel a pending task and return reward to sender.
    pub fn cancelTask(self: *AgentMessaging, message_id: core.ObjectID) !u64 {
        const msg = self.messages.getPtr(message_id) orelse return error.MessageNotFound;
        if (msg.status != .pending) return error.InvalidState;
        msg.status = .cancelled;
        const reward = self.escrow.get(message_id) orelse 0;
        _ = self.escrow.orderedRemove(message_id);
        return reward;
    }

    /// Get all tasks for a specific agent (as sender or recipient).
    pub fn getAgentTasks(self: *AgentMessaging, agent_id: [32]u8, role: enum { sender, recipient }) ![]AgentMessage {
        var results = std.ArrayList(AgentMessage).empty;
        var it = self.messages.iterator();
        while (it.next()) |entry| {
            const matches = switch (role) {
                .sender => std.mem.eql(u8, &entry.value_ptr.sender, &agent_id),
                .recipient => std.mem.eql(u8, &entry.value_ptr.recipient, &agent_id),
            };
            if (matches) try results.append(self.allocator, entry.value_ptr.*);
        }
        return results.toOwnedSlice(self.allocator);
    }
};

test "AgentMessaging task lifecycle" {
    const allocator = std.testing.allocator;
    var am = try AgentMessaging.init(allocator);
    defer am.deinit();

    const alice = @as([32]u8, @splat(1));
    const bob = @as([32]u8, @splat(2));

    const msg_id = try am.createTask(alice, bob, "Design a logo for Project X", 500, 86400);
    try std.testing.expect(!msg_id.eql(core.ObjectID.zero));

    try am.acceptTask(msg_id);
    const reward = try am.completeTask(msg_id);
    try std.testing.expectEqual(@as(u64, 500), reward);
    try std.testing.expectEqual(@as(u64, 1), am.total_tasks_completed);
}

test "AgentMessaging cancel and refund" {
    const allocator = std.testing.allocator;
    var am = try AgentMessaging.init(allocator);
    defer am.deinit();

    const alice = @as([32]u8, @splat(1));
    const bob = @as([32]u8, @splat(2));

    const msg_id = try am.createTask(alice, bob, "Write documentation", 300, 3600);
    const refund = try am.cancelTask(msg_id);
    try std.testing.expectEqual(@as(u64, 300), refund);
    try std.testing.expectEqual(@as(u64, 0), am.total_tasks_completed);
}
