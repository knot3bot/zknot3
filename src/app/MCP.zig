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

    /// Resource URI
    uri: []const u8,
    /// Resource type
    resource_type: ResourceType,
    /// Display name
    name: []const u8,
    /// Description
    description: []const u8,
    /// MIME type
    mime_type: []const u8,
    /// Is sensitive (requires extra permissions)
    is_sensitive: bool,
    /// Last updated
    updated_at: i64,

    /// Create new resource
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
            .updated_at = std.time.timestamp(),
        };
    }

    /// Full URI with schema
    pub fn fullURI(self: Self) []const u8 {
        return std.fmt.comptimePrint("zknot3://{s}", .{self.uri});
    }
};

/// MCP Prompt template
pub const Prompt = struct {
    const Self = @This();

    /// Prompt ID
    id: ObjectID,
    /// Name
    name: []const u8,
    /// Description
    description: []const u8,
    /// Template arguments
    arguments: []const PromptArgument,
    /// Template text (with {placeholders})
    template: []const u8,
    /// Is system prompt
    is_system: bool,
    /// Created at
    created_at: i64,

    /// Prompt argument definition
    pub const PromptArgument = struct {
        name: []const u8,
        description: []const u8,
        is_required: bool,
    };

    /// Render prompt with arguments
    pub fn render(self: Self, args: *std.StringArrayHashMap([]const u8)) []const u8 {
        // Simplified - in production would use proper template engine
        return self.template;
    }
};

/// MCP Tool - wrapper around Tool for MCP protocol
pub const MCPTool = struct {
    const Self = @This();

    /// Tool ID
    id: ObjectID,
    /// Name
    name: []const u8,
    /// Description
    description: []const u8,
    /// Input schema (JSON Schema)
    input_schema: []const u8,
    /// Is async
    is_async: bool,
    /// Requires approval
    requires_approval: bool,

    /// Create from tool
    pub fn from(tool: *const anyopaque) Self {
        // In production, would extract from actual Tool struct
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

    /// Policy ID
    id: ObjectID,
    /// Policy name
    name: []const u8,
    /// Allowed tools (by ID)
    allowed_tools: std.ArrayList(ObjectID),
    /// Denied tools
    denied_tools: std.ArrayList(ObjectID),
    /// Max token budget per request
    max_tokens: u32,
    /// Rate limit (requests per minute)
    rate_limit: u32,
    /// Is active
    is_active: bool,

    /// Create new policy
    pub fn create(name: []const u8) Self {
        return .{
            .id = ObjectID.hash(name),
            .name = name,
            .allowed_tools = std.ArrayList(ObjectID).init(std.heap.page_allocator),
            .denied_tools = std.ArrayList(ObjectID).init(std.heap.page_allocator),
            .max_tokens = 8192,
            .rate_limit = 60,
            .is_active = true,
        };
    }

    /// Check if tool is allowed
    pub fn isToolAllowed(self: Self, tool_id: ObjectID) bool {
        // Check deny list first
        for (self.denied_tools.items) |denied| {
            if (denied.eql(tool_id)) return false;
        }
        
        // If allow list is empty, all non-denied are allowed
        if (self.allowed_tools.items.len == 0) return true;
        
        // Check allow list
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
    /// Registered resources
    resources: std.StringArrayHashMap(Resource),
    /// Registered prompts
    prompts: std.StringArrayHashMap(Prompt),
    /// Security policies
    policies: std.StringArrayHashMap(SecurityPolicy),
    /// Active sessions
    sessions: std.StringArrayHashMap(MCPSession),

    /// Create MCP server
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .resources = std.StringArrayHashMap(Resource).init(allocator),
            .prompts = std.StringArrayHashMap(Prompt).init(allocator),
            .policies = std.StringArrayHashMap(SecurityPolicy).init(allocator),
            .sessions = std.StringArrayHashMap(MCPSession).init(allocator),
        };
    }

    /// Register a resource
    pub fn registerResource(self: *Self, resource: Resource) !void {
        try self.resources.put(resource.uri, resource);
    }

    /// List resources by type
    pub fn listResources(self: *Self, resource_type: ?ResourceType) []const Resource {
        var results = std.ArrayList(Resource).init(self.allocator);
        for (self.resources.values()) |res| {
            if (resource_type == null or res.resource_type == resource_type.?) {
                results.append(res) catch continue;
            }
        }
        return results.items;
    }

    /// Register a prompt
    pub fn registerPrompt(self: *Self, prompt: Prompt) !void {
        try self.prompts.put(prompt.name, prompt);
    }

    /// Create session
    pub fn createSession(self: *Self, agent_id: ObjectID, policy_id: ObjectID) !MCPSession {
        var session = MCPSession{
            .id = ObjectID.hash(agent_id.asBytes()),
            .agent_id = agent_id,
            .policy_id = policy_id,
            .created_at = std.time.timestamp(),
            .last_active = std.time.timestamp(),
            .request_count = 0,
            .is_active = true,
        };
        try self.sessions.put(session.id.asBytes(), session);
        return session;
    }

    /// Get active session
    pub fn getSession(self: *Self, session_id: ObjectID) ?*MCPSession {
        return self.sessions.getPtr(session_id.asBytes());
    }
};

/// MCP Session state
pub const MCPSession = struct {
    const Self = @This();

    /// Session ID
    id: ObjectID,
    /// Agent ID
    agent_id: ObjectID,
    /// Applied policy
    policy_id: ObjectID,
    /// Created at
    created_at: i64,
    /// Last activity
    last_active: i64,
    /// Request count
    request_count: u32,
    /// Is active
    is_active: bool,

    /// Check rate limit
    pub fn checkRateLimit(self: Self, rate_limit: u32) bool {
        _ = rate_limit;
        // Simplified - would track requests per minute
        return self.is_active;
    }

    /// Record activity
    pub fn recordActivity(self: *Self) void {
        self.last_active = std.time.timestamp();
        self.request_count += 1;
    }
};

/// MCP Request from AI agent
pub const MCPRequest = struct {
    const Self = @This();

    /// Request ID
    id: ObjectID,
    /// Session ID
    session_id: ObjectID,
    /// Request type
    request_type: RequestType,
    /// Method/endpoint
    method: []const u8,
    /// Parameters
    params: []const u8,
    /// Timestamp
    timestamp: i64,

    /// Request types
    pub const RequestType = enum {
        tools_list,
        tools_call,
        resources_list,
        resources_read,
        prompts_get,
        prompts_render,
    };

    /// Validate request
    pub fn isValid(self: Self) bool {
        return self.method.len > 0 and self.params.len >= 0;
    }
};

/// MCP Response
pub const MCPResponse = struct {
    const Self = @This();

    /// Response ID (matches request)
    id: ObjectID,
    /// Is success
    success: bool,
    /// Result data (JSON)
    result: []const u8,
    /// Error message
    error: ?[]const u8,
    /// Execution time in ms
    execution_time_ms: u64,

    /// Create success response
    pub fn success(id: ObjectID, result: []const u8, exec_time: u64) Self {
        return .{
            .id = id,
            .success = true,
            .result = result,
            .error = null,
            .execution_time_ms = exec_time,
        };
    }

    /// Create error response
    pub fn error(id: ObjectID, err: []const u8, exec_time: u64) Self {
        return .{
            .id = id,
            .success = false,
            .result = "",
            .error = err,
            .execution_time_ms = exec_time,
        };
    }
};

test "Resource creation" {
    var resource = Resource.create(
        "wallet/balance",
        .Balance,
        "Wallet Balance",
        "Current token balance",
    );
    
    try std.testing.expectEqualStrings("zknot3://wallet/balance", resource.fullURI());
    try std.testing.expect(!resource.is_sensitive);
}

test "MCPServer resource registration" {
    const allocator = std.testing.allocator;
    var server = MCPServer.init(allocator);
    
    var resource = Resource.create(
        "object/123",
        .Object,
        "Test Object",
        "A test object",
    );
    
    try server.registerResource(resource);
    
    const found = server.resources.get("object/123");
    try std.testing.expect(found != null);
}

test "SecurityPolicy tool check" {
    var policy = SecurityPolicy.create("test_policy");
    
    const allowed_tool = ObjectID.hash("allowed");
    const denied_tool = ObjectID.hash("denied");
    
    try policy.allowed_tools.append(allowed_tool);
    try policy.denied_tools.append(denied_tool);
    
    try std.testing.expect(policy.isToolAllowed(allowed_tool));
    try std.testing.expect(!policy.isToolAllowed(denied_tool));
    
    // Unknown tool should be denied when allow list is populated
    const unknown = ObjectID.hash("unknown");
    try std.testing.expect(!policy.isToolAllowed(unknown));
}

test "MCPSession activity" {
    var session = MCPSession{
        .id = ObjectID.hash("session"),
        .agent_id = ObjectID.hash("agent"),
        .policy_id = ObjectID.hash("policy"),
        .created_at = std.time.timestamp(),
        .last_active = std.time.timestamp(),
        .request_count = 0,
        .is_active = true,
    };
    
    try std.testing.expect(session.checkRateLimit(60));
    
    session.recordActivity();
    try std.testing.expect(session.request_count == 1);
}

test "MCPRequest validation" {
    var req = MCPRequest{
        .id = ObjectID.hash("req"),
        .session_id = ObjectID.hash("session"),
        .request_type = .tools_list,
        .method = "tools.list",
        .params = "{}",
        .timestamp = std.time.timestamp(),
    };
    
    try std.testing.expect(req.isValid());
}

test "MCPResponse success and error" {
    const id = ObjectID.hash("req");
    
    const success_resp = MCPResponse.success(id, "{\"tools\": []}", 100);
    try std.testing.expect(success_resp.success);
    try std.testing.expect(success_resp.error == null);
    
    const error_resp = MCPResponse.error(id, "Tool not found", 50);
    try std.testing.expect(!error_resp.success);
    try std.testing.expect(error_resp.error != null);
}
