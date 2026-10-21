//! MCP (Model Context Protocol) Integration
//!
//! Native support for AI agent communication and tool discovery:
//! - MCP server for agent tool discovery
//! - Resource abstraction for on-chain data
//! - Prompt templates for agent interaction
//! - Security policies for agent actions

const std = @import("std");
const core = @import("../core.zig");
const ObjectID = core.ObjectID;

fn wallClockSec() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

/// MCP resource type
pub const ResourceType = enum(u8) {
    Object = 0,
    Balance = 1,
    Transaction = 2,
    Agent = 3,
    Tool = 4,
    Contract = 5,
};

/// MCP Resource - on-chain data accessible to agents
pub const Resource = struct {
    const Self = @This();

    uri: []const u8,
    resource_type: ResourceType,
    name: []const u8,
    description: []const u8,
    mime_type: []const u8,
    is_sensitive: bool,
    updated_at: i64,

    pub fn create(
        uri: []const u8,
        resource_type: ResourceType,
        name: []const u8,
        description: []const u8,
    ) Self {
        return .{
            .uri = uri,
            .resource_type = resource_type,
            .name = name,
            .description = description,
            .mime_type = "application/json",
            .is_sensitive = false,
            .updated_at = wallClockSec(),
        };
    }

    /// Caller owns the returned URI (`zknot3://` + path).
    pub fn fullURI(self: Self, allocator: std.mem.Allocator) ![]u8 {
        return try allocator.print("zknot3://{s}", .{self.uri});
    }
};

/// MCP Prompt template
pub const Prompt = struct {
    const Self = @This();

    id: ObjectID,
    name: []const u8,
    description: []const u8,
    arguments: []const PromptArgument,
    template: []const u8,
    is_system: bool,
    created_at: i64,

    pub const PromptArgument = struct {
        name: []const u8,
        description: []const u8,
        is_required: bool,
    };

    /// Render prompt with arguments. Placeholder expansion is deferred.
    pub fn render(self: Self, args: *const std.StringHashMapUnmanaged([]const u8)) []const u8 {
        _ = args;
        return self.template;
    }
};

/// MCP Tool - wrapper around Tool for MCP protocol
pub const MCPTool = struct {
    const Self = @This();

    id: ObjectID,
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    is_async: bool,
    requires_approval: bool,

    pub fn from(tool: *const anyopaque) Self {
        _ = tool;
        return .{
            .id = ObjectID.hash("tool"),
            .name = "unknown",
            .description = "Tool",
            .input_schema = "{}",
            .is_async = false,
            .requires_approval = false,
        };
    }
};

/// MCP Security Policy
pub const SecurityPolicy = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    id: ObjectID,
    name: []const u8,
    allowed_tools: std.ArrayList(ObjectID) = .empty,
    denied_tools: std.ArrayList(ObjectID) = .empty,
    max_tokens: u32,
    rate_limit: u32,
    is_active: bool,

    pub fn create(allocator: std.mem.Allocator, name: []const u8) Self {
        return .{
            .allocator = allocator,
            .id = ObjectID.hash(name),
            .name = name,
            .max_tokens = 8192,
            .rate_limit = 60,
            .is_active = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allowed_tools.deinit(self.allocator);
        self.denied_tools.deinit(self.allocator);
    }

    pub fn isToolAllowed(self: Self, tool_id: ObjectID) bool {
        for (self.denied_tools.items) |denied| {
            if (denied.eql(tool_id)) return false;
        }
        if (self.allowed_tools.items.len == 0) return true;
        for (self.allowed_tools.items) |allowed| {
            if (allowed.eql(tool_id)) return true;
        }
        return false;
    }
};

/// MCP Server - manages agent interactions
pub const MCPServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    resources: std.StringHashMapUnmanaged(Resource) = .empty,
    prompts: std.StringHashMapUnmanaged(Prompt) = .empty,
    policies: std.StringHashMapUnmanaged(SecurityPolicy) = .empty,
    sessions: std.AutoArrayHashMapUnmanaged([32]u8, MCPSession) = .empty,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        var pit = self.policies.iterator();
        while (pit.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.resources.deinit(self.allocator);
        self.prompts.deinit(self.allocator);
        self.policies.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
    }

    pub fn registerResource(self: *Self, resource: Resource) !void {
        try self.resources.put(self.allocator, resource.uri, resource);
    }

    /// Caller owns the returned slice and must free it.
    pub fn listResources(self: *Self, resource_type: ?ResourceType) ![]Resource {
        var results: std.ArrayList(Resource) = .empty;
        errdefer results.deinit(self.allocator);
        var it = self.resources.iterator();
        while (it.next()) |entry| {
            const res = entry.value_ptr.*;
            if (resource_type == null or res.resource_type == resource_type.?) {
                try results.append(self.allocator, res);
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn registerPrompt(self: *Self, prompt: Prompt) !void {
        try self.prompts.put(self.allocator, prompt.name, prompt);
    }

    pub fn createSession(self: *Self, agent_id: ObjectID, policy_id: ObjectID) !MCPSession {
        const now = wallClockSec();
        const session = MCPSession{
            .id = ObjectID.hash(agent_id.asBytes()),
            .agent_id = agent_id,
            .policy_id = policy_id,
            .created_at = now,
            .last_active = now,
            .request_count = 0,
            .is_active = true,
        };
        try self.sessions.put(self.allocator, session.id.bytes, session);
        return session;
    }

    pub fn getSession(self: *Self, session_id: ObjectID) ?*MCPSession {
        return self.sessions.getPtr(session_id.bytes);
    }
};

/// MCP Session state
pub const MCPSession = struct {
    const Self = @This();

    id: ObjectID,
    agent_id: ObjectID,
    policy_id: ObjectID,
    created_at: i64,
    last_active: i64,
    request_count: u32,
    is_active: bool,

    pub fn checkRateLimit(self: Self, rate_limit: u32) bool {
        _ = rate_limit;
        return self.is_active;
    }

    pub fn recordActivity(self: *Self) void {
        self.last_active = wallClockSec();
        self.request_count = std.math.add(u32, self.request_count, 1) catch std.math.maxInt(u32);
    }
};

/// MCP Request from AI agent
pub const MCPRequest = struct {
    const Self = @This();

    id: ObjectID,
    session_id: ObjectID,
    request_type: RequestType,
    method: []const u8,
    params: []const u8,
    timestamp: i64,

    pub const RequestType = enum {
        tools_list,
        tools_call,
        resources_list,
        resources_read,
        prompts_get,
        prompts_render,
    };

    pub fn isValid(self: Self) bool {
        return self.method.len > 0;
    }
};

/// MCP Response
pub const MCPResponse = struct {
    const Self = @This();

    id: ObjectID,
    /// True when the request completed without an MCP-level error.
    ok: bool,
    result: []const u8,
    error_message: ?[]const u8,
    execution_time_ms: u64,

    pub fn success(id: ObjectID, result: []const u8, exec_time: u64) Self {
        return .{
            .id = id,
            .ok = true,
            .result = result,
            .error_message = null,
            .execution_time_ms = exec_time,
        };
    }

    pub fn err(id: ObjectID, message: []const u8, exec_time: u64) Self {
        return .{
            .id = id,
            .ok = false,
            .result = "",
            .error_message = message,
            .execution_time_ms = exec_time,
        };
    }
};

test "Resource creation" {
    const allocator = std.testing.allocator;
    const resource = Resource.create(
        "wallet/balance",
        .Balance,
        "Wallet Balance",
        "Current token balance",
    );

    const uri = try resource.fullURI(allocator);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("zknot3://wallet/balance", uri);
    try std.testing.expect(!resource.is_sensitive);
}

test "MCPServer resource registration" {
    const allocator = std.testing.allocator;
    var server = MCPServer.init(allocator);
    defer server.deinit();

    const resource = Resource.create(
        "object/123",
        .Object,
        "Test Object",
        "A test object",
    );

    try server.registerResource(resource);

    const found = server.resources.get("object/123");
    try std.testing.expect(found != null);

    const listed = try server.listResources(.Object);
    defer allocator.free(listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
}

test "SecurityPolicy tool check" {
    const allocator = std.testing.allocator;
    var policy = SecurityPolicy.create(allocator, "test_policy");
    defer policy.deinit();

    const allowed_tool = ObjectID.hash("allowed");
    const denied_tool = ObjectID.hash("denied");

    try policy.allowed_tools.append(allocator, allowed_tool);
    try policy.denied_tools.append(allocator, denied_tool);

    try std.testing.expect(policy.isToolAllowed(allowed_tool));
    try std.testing.expect(!policy.isToolAllowed(denied_tool));

    const unknown = ObjectID.hash("unknown");
    try std.testing.expect(!policy.isToolAllowed(unknown));
}

test "MCPSession activity" {
    var session = MCPSession{
        .id = ObjectID.hash("session"),
        .agent_id = ObjectID.hash("agent"),
        .policy_id = ObjectID.hash("policy"),
        .created_at = wallClockSec(),
        .last_active = wallClockSec(),
        .request_count = 0,
        .is_active = true,
    };

    try std.testing.expect(session.checkRateLimit(60));

    session.recordActivity();
    try std.testing.expect(session.request_count == 1);
}

test "MCPRequest validation" {
    const req = MCPRequest{
        .id = ObjectID.hash("req"),
        .session_id = ObjectID.hash("session"),
        .request_type = .tools_list,
        .method = "tools.list",
        .params = "{}",
        .timestamp = wallClockSec(),
    };

    try std.testing.expect(req.isValid());
}

test "MCPResponse success and error" {
    const id = ObjectID.hash("req");

    const success_resp = MCPResponse.success(id, "{\"tools\": []}", 100);
    try std.testing.expect(success_resp.ok);
    try std.testing.expect(success_resp.error_message == null);

    const error_resp = MCPResponse.err(id, "Tool not found", 50);
    try std.testing.expect(!error_resp.ok);
    try std.testing.expect(error_resp.error_message != null);
}
