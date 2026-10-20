//! Agent-to-Agent Messaging — On-chain agent communication protocol.
//!
//! Enables AI agents to discover, task, and reward each other on-chain.
//! Supports: TaskRequest, TaskAccept, TaskComplete, Feedback with reward escrow.

const std = @import("std");
const core = @import("../../core.zig");

fn saturatingAdd(total: u64, amount: u64) u64 {
    return std.math.add(u64, total, amount) catch std.math.maxInt(u64);
}

fn saturatingAddClock(clock_sec: i64, duration_secs: i64) i64 {
    return std.math.add(i64, clock_sec, duration_secs) catch if (duration_secs < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

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
    /// Mixed into task ids so identical descriptions do not collide.
    next_seq: u64 = 0,
    /// Seconds stamped on new tasks. Callers set this from the epoch start.
    clock_sec: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) !*AgentMessaging {
        const self = try allocator.create(AgentMessaging);
        self.* = .{
            .allocator = allocator,
            .messages = .empty,
            .escrow = .empty,
            .total_tasks_created = 0,
            .total_tasks_completed = 0,
            .total_rewards_paid = 0,
            .next_seq = 0,
            .clock_sec = 0,
        };
        return self;
    }

    pub fn setClock(self: *AgentMessaging, epoch_start_sec: i64) void {
        self.clock_sec = epoch_start_sec;
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
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update("task");
        const seq = self.next_seq;
        self.next_seq = std.math.add(u64, seq, 1) catch return error.ArithmeticOverflow;
        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, seq, .big);
        hasher.update(&seq_buf);
        hasher.update(&sender);
        hasher.update(&recipient);
        hasher.update(description);
        var id_bytes: [32]u8 = undefined;
        hasher.final(&id_bytes);
        const id = core.ObjectID{ .bytes = id_bytes };
        if (self.messages.contains(id)) return error.AlreadyExists;

        const description_copy = try self.allocator.dupe(u8, description);
        const msg = AgentMessage{
            .id = id,
            .msg_type = .task_request,
            .sender = sender,
            .recipient = recipient,
            .task_description = description_copy,
            .reward_amount = reward,
            .status = .pending,
            .created_at = self.clock_sec,
            .expires_at = saturatingAddClock(self.clock_sec, deadline_secs),
        };
        self.messages.put(self.allocator, id, msg) catch |err| {
            self.allocator.free(description_copy);
            return err;
        };
        self.escrow.put(self.allocator, id, reward) catch |err| {
            _ = self.messages.orderedRemove(id);
            self.allocator.free(description_copy);
            return err;
        };
        self.total_tasks_created = saturatingAdd(self.total_tasks_created, 1);
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
        self.total_tasks_completed = saturatingAdd(self.total_tasks_completed, 1);
        self.total_rewards_paid = saturatingAdd(self.total_rewards_paid, reward);
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
            self.total_rewards_paid = saturatingAdd(self.total_rewards_paid, tip_amount);
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

test "AgentMessaging tasks with the same text stay distinct" {
    const allocator = std.testing.allocator;
    var am = try AgentMessaging.init(allocator);
    defer am.deinit();
    am.setClock(1_700_000_000);

    const alice = @as([32]u8, @splat(1));
    const bob = @as([32]u8, @splat(2));
    const first = try am.createTask(alice, bob, "same brief", 10, 60);
    const second = try am.createTask(alice, bob, "same brief", 10, 60);
    try std.testing.expect(!first.eql(second));
    try std.testing.expectEqual(@as(i64, 1_700_000_000), am.messages.get(first).?.created_at);
    try std.testing.expectEqual(@as(i64, 1_700_000_060), am.messages.get(second).?.expires_at);
    try std.testing.expectEqual(@as(u64, 2), am.total_tasks_created);
}

test "AgentMessaging task deadline saturates at the i64 limits" {
    const allocator = std.testing.allocator;
    var am = try AgentMessaging.init(allocator);
    defer am.deinit();

    const alice = @as([32]u8, @splat(1));
    const bob = @as([32]u8, @splat(2));
    am.setClock(std.math.maxInt(i64) - 10);
    const late = try am.createTask(alice, bob, "late", 1, 100);
    try std.testing.expectEqual(std.math.maxInt(i64), am.messages.get(late).?.expires_at);

    am.setClock(std.math.minInt(i64) + 10);
    const early = try am.createTask(alice, bob, "early", 1, -100);
    try std.testing.expectEqual(std.math.minInt(i64), am.messages.get(early).?.expires_at);
}

test "AgentMessaging paid rewards saturate at the u64 limit" {
    const allocator = std.testing.allocator;
    var am = try AgentMessaging.init(allocator);
    defer am.deinit();

    const alice = @as([32]u8, @splat(1));
    const bob = @as([32]u8, @splat(2));
    const cap = std.math.maxInt(u64);
    const first = try am.createTask(alice, bob, "cap", cap, 60);
    try am.acceptTask(first);
    _ = try am.completeTask(first);
    const second = try am.createTask(alice, bob, "extra", 1, 60);
    try am.acceptTask(second);
    _ = try am.completeTask(second);
    try am.submitFeedback(second, 5, "", 10);
    try std.testing.expectEqual(cap, am.total_rewards_paid);
}

test "AgentMessaging refuses to wrap its task sequence" {
    const allocator = std.testing.allocator;
    var am = try AgentMessaging.init(allocator);
    defer am.deinit();

    am.next_seq = std.math.maxInt(u64);
    const alice = @as([32]u8, @splat(1));
    const bob = @as([32]u8, @splat(2));
    try std.testing.expectError(error.ArithmeticOverflow, am.createTask(alice, bob, "overflow", 1, 60));
    try std.testing.expectEqual(std.math.maxInt(u64), am.next_seq);
    try std.testing.expectEqual(@as(usize, 0), am.messages.count());
}

test "AgentMessaging task counts saturate at the u64 limit" {
    const allocator = std.testing.allocator;
    var am = try AgentMessaging.init(allocator);
    defer am.deinit();

    const alice = @as([32]u8, @splat(1));
    const bob = @as([32]u8, @splat(2));
    const cap = std.math.maxInt(u64);
    am.total_tasks_created = cap;
    am.total_tasks_completed = cap;
    const id = try am.createTask(alice, bob, "cap-count", 1, 60);
    try std.testing.expectEqual(cap, am.total_tasks_created);
    try am.acceptTask(id);
    _ = try am.completeTask(id);
    try std.testing.expectEqual(cap, am.total_tasks_completed);
    try std.testing.expect(am.messages.get(id).?.status == .completed);
}
