//! AgentRegistry — On-chain Agent Discovery & Reputation
//!
//! Enables AI agents to register, be discovered by capability,
//! and build reputation through task completion and feedback.
//!
//! Move module: creator3::agent_registry

const std = @import("std");
const core = @import("../../core.zig");

fn saturatingAddI64(total: i64, delta: i64) i64 {
    return std.math.add(i64, total, delta) catch if (delta < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

fn saturatingAddU64(total: u64, amount: u64) u64 {
    return std.math.add(u64, total, amount) catch std.math.maxInt(u64);
}

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
    /// Seconds stamped on new agents. Callers set this from the epoch start.
    clock_sec: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) !*AgentRegistry {
        const self = try allocator.create(AgentRegistry);
        self.* = .{
            .allocator = allocator,
            .agents = .empty,
            .capability_index = .empty,
            .clock_sec = 0,
        };
        return self;
    }

    pub fn setClock(self: *AgentRegistry, epoch_start_sec: i64) void {
        self.clock_sec = epoch_start_sec;
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
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update("agent");
        hasher.update(&owner);
        hasher.update(name);
        var id_bytes: [32]u8 = undefined;
        hasher.final(&id_bytes);
        const id = core.ObjectID{ .bytes = id_bytes };
        if (self.agents.contains(id)) return error.AlreadyRegistered;

        var stored = false;
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer if (!stored) self.allocator.free(name_copy);
        const caps_copy = try self.allocator.dupe(AgentCapability, capabilities);
        errdefer if (!stored) self.allocator.free(caps_copy);
        const url_copy = try self.allocator.dupe(u8, endpoint_url);
        errdefer if (!stored) self.allocator.free(url_copy);

        const agent = Agent{
            .id = id,
            .owner = owner,
            .name = name_copy,
            .capabilities = caps_copy,
            .endpoint_url = url_copy,
            .reputation_score = 100,
            .total_tasks_completed = 0,
            .total_rewards_earned = 0,
            .created_at = self.clock_sec,
            .is_active = true,
        };

        try self.agents.put(self.allocator, id, agent);
        stored = true;

        // Index by capability for fast discovery
        for (capabilities) |cap| {
            const cap_byte: u8 = @backingInt(cap);
            const list = try self.capability_index.getOrPutValue(self.allocator, cap_byte, std.ArrayList(core.ObjectID).empty);
            try list.value_ptr.append(self.allocator, id);
        }

        return id;
    }

    /// Update an agent's reputation after task completion.
    /// Positive delta for successful tasks, negative for failures.
    pub fn updateReputation(self: *AgentRegistry, agent_id: core.ObjectID, score_delta: i64, reward_amount: u64) !void {
        const agent = self.agents.getPtr(agent_id) orelse return error.AgentNotFound;
        agent.reputation_score = saturatingAddI64(agent.reputation_score, score_delta);
        if (score_delta > 0) agent.total_tasks_completed = saturatingAddU64(agent.total_tasks_completed, 1);
        agent.total_rewards_earned = saturatingAddU64(agent.total_rewards_earned, reward_amount);
    }

    /// Discover agents by capability. Returns agents sorted by reputation (highest first).
    pub fn discoverByCapability(self: *AgentRegistry, capability: AgentCapability) ![]Agent {
        const cap_byte: u8 = @backingInt(capability);
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
    const caps = [_]AgentCapability{ .image_gen, .text_gen };

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

test "AgentRegistry reputation and rewards saturate at the integer limits" {
    const allocator = std.testing.allocator;
    var reg = try AgentRegistry.init(allocator);
    defer reg.deinit();

    const owner = @as([32]u8, @splat(1));
    const caps = [_]AgentCapability{.code_gen};
    const id = try reg.register(owner, "CapBot", &caps, "https://cap.example");

    try reg.updateReputation(id, std.math.maxInt(i64), std.math.maxInt(u64));
    try reg.updateReputation(id, 1, 1);
    const high = reg.agents.get(id).?;
    try std.testing.expectEqual(std.math.maxInt(i64), high.reputation_score);
    try std.testing.expectEqual(std.math.maxInt(u64), high.total_rewards_earned);

    const low_id = try reg.register(owner, "FloorBot", &caps, "https://floor.example");
    try reg.updateReputation(low_id, std.math.minInt(i64), 0);
    try reg.updateReputation(low_id, -101, 0);
    try std.testing.expectEqual(std.math.minInt(i64), reg.agents.get(low_id).?.reputation_score);
}

test "AgentRegistry ids include the owner and use the epoch clock" {
    const allocator = std.testing.allocator;
    var reg = try AgentRegistry.init(allocator);
    defer reg.deinit();
    reg.setClock(1_700_000_000);

    const caps = [_]AgentCapability{.text_gen};
    const first = try reg.register(@as([32]u8, @splat(1)), "Bot", &caps, "https://a.example");
    const second = try reg.register(@as([32]u8, @splat(2)), "Bot", &caps, "https://b.example");
    try std.testing.expect(!first.eql(second));
    try std.testing.expectEqual(@as(i64, 1_700_000_000), reg.agents.get(first).?.created_at);
    try std.testing.expectError(error.AlreadyRegistered, reg.register(@as([32]u8, @splat(1)), "Bot", &caps, "https://a.example"));
}
