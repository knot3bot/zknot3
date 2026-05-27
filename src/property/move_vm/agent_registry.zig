//! AgentRegistry — On-chain Agent Discovery & Reputation
//!
//! Enables AI agents to register, be discovered by capability,
//! and build reputation through task completion and feedback.
//!
//! Move module: creator3::agent_registry

const std = @import("std");
const core = @import("../../core.zig");

pub const AgentCapability = enum(u8) {
    image_gen = 1,
    text_gen = 2,
    music_gen = 3,
    video_gen = 4,
    code_gen = 5,
    data_analysis = 6,
    design = 7,
    translation = 8,
    custom = 255,

    pub fn fromString(s: []const u8) AgentCapability {
        if (std.mem.eql(u8, s, "image-gen")) return .image_gen;
        if (std.mem.eql(u8, s, "text-gen")) return .text_gen;
        if (std.mem.eql(u8, s, "music-gen")) return .music_gen;
        if (std.mem.eql(u8, s, "video-gen")) return .video_gen;
        if (std.mem.eql(u8, s, "code-gen")) return .code_gen;
        if (std.mem.eql(u8, s, "data-analysis")) return .data_analysis;
        if (std.mem.eql(u8, s, "design")) return .design;
        if (std.mem.eql(u8, s, "translation")) return .translation;
        return .custom;
    }
};

pub const Agent = struct {
    id: core.ObjectID,
    owner: [32]u8,
    name: []const u8,
    capabilities: []const AgentCapability,
    endpoint_url: []const u8,
    reputation_score: i64,
    total_tasks_completed: u64,
    total_rewards_earned: u64,
    created_at: i64,
    is_active: bool,

    pub fn deinit(self: *Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.capabilities);
        allocator.free(self.endpoint_url);
    }
};

pub const AgentRegistry = struct {
    allocator: std.mem.Allocator,
    agents: std.AutoArrayHashMapUnmanaged(core.ObjectID, Agent),
    capability_index: std.AutoArrayHashMapUnmanaged(u8, std.ArrayList(core.ObjectID)),

    pub fn init(allocator: std.mem.Allocator) !*AgentRegistry {
        const self = try allocator.create(AgentRegistry);
        self.* = .{
            .allocator = allocator,
            .agents = .empty,
            .capability_index = .empty,
        };
        return self;
    }

    pub fn deinit(self: *AgentRegistry) void {
        var it = self.agents.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.agents.deinit(self.allocator);

        var ci = self.capability_index.iterator();
        while (ci.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.capability_index.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Register a new agent. Returns the agent's ObjectID.
    pub fn register(
        self: *AgentRegistry,
        owner: [32]u8,
        name: []const u8,
        capabilities: []const AgentCapability,
        endpoint_url: []const u8,
    ) !core.ObjectID {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);

        const id = core.ObjectID.hash(name);
        if (self.agents.contains(id)) return error.AlreadyRegistered;

        const agent = Agent{
            .id = id,
            .owner = owner,
            .name = try self.allocator.dupe(u8, name),
            .capabilities = try self.allocator.dupe(AgentCapability, capabilities),
            .endpoint_url = try self.allocator.dupe(u8, endpoint_url),
            .reputation_score = 100,
            .total_tasks_completed = 0,
            .total_rewards_earned = 0,
            .created_at = ts.sec,
            .is_active = true,
        };

        try self.agents.put(self.allocator, id, agent);

        // Index by capability for fast discovery
        for (capabilities) |cap| {
            const cap_byte: u8 = @intFromEnum(cap);
            const list = try self.capability_index.getOrPutValue(self.allocator, cap_byte, std.ArrayList(core.ObjectID).empty);
            try list.value_ptr.append(self.allocator, id);
        }

        return id;
    }

    /// Update an agent's reputation after task completion.
    /// Positive delta for successful tasks, negative for failures.
    pub fn updateReputation(self: *AgentRegistry, agent_id: core.ObjectID, score_delta: i64, reward_amount: u64) !void {
        const agent = self.agents.getPtr(agent_id) orelse return error.AgentNotFound;
        agent.reputation_score += score_delta;
        if (score_delta > 0) agent.total_tasks_completed += 1;
        agent.total_rewards_earned += reward_amount;
    }

    /// Discover agents by capability. Returns agents sorted by reputation (highest first).
    pub fn discoverByCapability(self: *AgentRegistry, capability: AgentCapability) ![]Agent {
        const cap_byte: u8 = @intFromEnum(capability);
        const agent_ids = self.capability_index.get(cap_byte) orelse return &.{};

        var results = std.ArrayList(Agent).empty;
        errdefer results.deinit(self.allocator);
        for (agent_ids.items) |id| {
            if (self.agents.get(id)) |agent| {
                if (agent.is_active) try results.append(self.allocator, agent);
            }
        }

        // Sort by reputation (highest first)
        std.mem.sort(Agent, results.items, {}, struct {
            fn lt(_: void, a: Agent, b: Agent) bool {
                return a.reputation_score > b.reputation_score;
            }
        }.lt);

        return results.toOwnedSlice(self.allocator);
    }

    /// Get all registered agents.
    pub fn listAll(self: *AgentRegistry) ![]Agent {
        var results = std.ArrayList(Agent).init(self.allocator);
        var it = self.agents.iterator();
        while (it.next()) |entry| {
            try results.append(entry.value_ptr.*);
        }
        return results.toOwnedSlice(self.allocator);
    }

    /// Deactivate an agent (temporary removal from discovery).
    pub fn deactivate(self: *AgentRegistry, agent_id: core.ObjectID) !void {
        const agent = self.agents.getPtr(agent_id) orelse return error.AgentNotFound;
        agent.is_active = false;
    }
};

test "AgentRegistry register and discover" {
    const allocator = std.testing.allocator;
    var reg = try AgentRegistry.init(allocator);
    defer reg.deinit();

    const owner = @as([32]u8, @splat(1));
    const caps = [_]AgentCapability{.image_gen, .text_gen};

    const id = try reg.register(owner, "ArtBot-3000", &caps, "https://artbot.example.com/api");
    try std.testing.expect(!id.eql(core.ObjectID.zero));

    const discovered = try reg.discoverByCapability(.image_gen);
    defer allocator.free(discovered);
    try std.testing.expect(discovered.len >= 1);
}

test "AgentRegistry reputation update" {
    const allocator = std.testing.allocator;
    var reg = try AgentRegistry.init(allocator);
    defer reg.deinit();

    const owner = @as([32]u8, @splat(1));
    const caps = [_]AgentCapability{.code_gen};
    const id = try reg.register(owner, "CodeBot", &caps, "https://codebot.example.com");

    try reg.updateReputation(id, 10, 1000);
    const agent = reg.agents.get(id).?;
    try std.testing.expectEqual(@as(i64, 110), agent.reputation_score);
    try std.testing.expectEqual(@as(u64, 1000), agent.total_rewards_earned);
}
