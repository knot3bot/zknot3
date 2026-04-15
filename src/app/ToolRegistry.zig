//! Tool Registry - On-chain Function Registry for AI Agents
//!
//! Provides a registry of callable functions/tools that AI agents
//! can discover and invoke on-chain. This enables:
//! - AI agent tool discovery
//! - Permissioned function calls
//! - Tool versioning and deprecation
//! - Attested tool execution

const std = @import("std");
const core = @import("../core.zig");
const ObjectID = core.ObjectID;

/// Tool parameter schema
pub const ToolParameter = struct {
    name: []const u8,
    description: []const u8,
    param_type: ParameterType,
    is_required: bool,
    default_value: ?[]const u8,
};

/// Parameter types supported
pub const ParameterType = enum(u8) {
    String = 0,
    Number = 1,
    Boolean = 2,
    Object = 3,
    Array = 4,
    Address = 5,
    ObjectID = 6,
};

/// Tool visibility
pub const ToolVisibility = enum(u8) {
    Private = 0,    // Only owner can call
    Restricted = 1,  // Whitelist allowed callers
    Public = 2,      // Anyone can call
};

/// Tool category for organization
pub const ToolCategory = enum(u8) {
    Financial = 0,
    Governance = 1,
    Storage = 2,
    Communication = 3,
    Computation = 4,
    Identity = 5,
    Custom = 6,
};

/// Registered tool/function
pub const Tool = struct {
    const Self = @This();

    /// Unique tool ID
    id: ObjectID,
    /// Tool name (unique per namespace)
    name: []const u8,
    /// Namespace (package/module)
    namespace: []const u8,
    /// Description
    description: []const u8,
    /// Category
    category: ToolCategory,
    /// Parameter schema (JSON)
    parameters: []const ToolParameter,
    /// Return type schema (JSON)
    return_schema: []const u8,
    /// Who can call this tool
    visibility: ToolVisibility,
    /// Tool owner
    owner: [32]u8,
    /// Allowed callers for Restricted visibility (max 16)
    allowed_callers: [16][32]u8,
    allowed_count: u8,
    /// Gas budget required
    gas_budget: u64,
    /// Is deprecated
    is_deprecated: bool,
    /// Deprecation message
    deprecation_message: ?[]const u8,
    /// Version
    version: u32,
    /// Created at
    created_at: i64,
    /// Updated at
    updated_at: i64,

    /// Create a new tool registration
    pub fn register(
        name: []const u8,
        namespace: []const u8,
        description: []const u8,
        category: ToolCategory,
        owner: [32]u8,
    ) Self {
        const now = std.time.timestamp();
        return .{
            .id = ObjectID.hash(name),
            .name = name,
            .namespace = namespace,
            .description = description,
            .category = category,
            .parameters = &.{},
            .return_schema = "{}",
            .visibility = .Private,
            .owner = owner,
            .gas_budget = 1000,
            .is_deprecated = false,
            .deprecation_message = null,
            .version = 1,
            .created_at = now,
            .updated_at = now,
        };
    }

    /// Full qualified name
    pub fn fullName(self: Self) []const u8 {
        return std.fmt.comptimePrint("{s}.{s}", .{ self.namespace, self.name });
    }

    /// Check if caller is on the whitelist
    fn isCallerAllowed(self: Self, caller: [32]u8) bool {
        // Owner is always allowed
        if (std.mem.eql(u8, &self.owner, &caller)) return true;
        // Check whitelist
        var j: u8 = 0;
        while (j < self.allowed_count) : (j += 1) {
            if (std.mem.eql(u8, &self.allowed_callers[j], &caller)) return true;
        }
        return false;
    }

    /// Add caller to whitelist (for Restricted tools)
    pub fn addAllowedCaller(self: *Self, caller: [32]u8) void {
        if (self.allowed_count >= 16) return; // Max 16 allowed
        // Check if already in whitelist
        var j: u8 = 0;
        while (j < self.allowed_count) : (j += 1) {
            if (std.mem.eql(u8, &self.allowed_callers[j], &caller)) return;
        }
        self.allowed_callers[self.allowed_count] = caller;
        self.allowed_count += 1;
    }

    /// Check if caller can invoke
    pub fn canInvoke(self: Self, caller: [32]u8) bool {
        if (self.is_deprecated) return false;
        
        return switch (self.visibility) {
            .Public => true,
            .Private => std.mem.eql(u8, &self.owner, &caller),
            .Restricted => self.isCallerAllowed(caller),
        };
    }
};

/// Tool invocation request
pub const ToolInvocation = struct {
    const Self = @This();

    /// Invocation ID
    id: ObjectID,
    /// Tool being invoked
    tool_id: ObjectID,
    /// Caller (agent or user)
    caller: [32]u8,
    /// Session ID (if agent)
    session_id: ?[32]u8,
    /// Parameters (JSON encoded)
    parameters: []const u8,
    /// Expected gas
    gas_offered: u64,
    /// Timestamp
    timestamp: i64,
    /// Result (filled after execution)
    result: ?ToolResult,

    /// Check if invocation is valid
    pub fn isValid(self: Self) bool {
        return self.parameters.len > 0 and self.gas_offered > 0;
    }
};

/// Tool execution result
pub const ToolResult = struct {
    const Self = @This();

    /// Success flag
    success: bool,
    /// Return value (JSON)
    return_value: []const u8,
    /// Gas used
    gas_used: u64,
    /// Error message if failed
    error_message: ?[]const u8,
    /// Attestation signature
    attestation: ?[64]u8,

    /// Create success result
    pub fn success(return_value: []const u8, gas_used: u64) Self {
        return .{
            .success = true,
            .return_value = return_value,
            .gas_used = gas_used,
            .error_message = null,
            .attestation = null,
        };
    }

    /// Create error result
    pub fn error(message: []const u8, gas_used: u64) Self {
        return .{
            .success = false,
            .return_value = "",
            .gas_used = gas_used,
            .error_message = message,
            .attestation = null,
        };
    }
};

/// Tool permission grant
pub const ToolPermission = struct {
    const Self = @This();

    /// Permission ID
    id: ObjectID,
    /// Tool being permitted
    tool_id: ObjectID,
    /// Granted to (agent or user)
    grantee: [32]u8,
    /// Grantor (tool owner)
    granted_by: [32]u8,
    /// Max gas per invocation
    max_gas: u64,
    /// Rate limit (calls per hour)
    rate_limit: u32,
    /// Is revoked
    is_revoked: bool,
    /// Expires at (0 = never)
    expires_at: i64,

    /// Create new permission
    pub fn grant(
        tool_id: ObjectID,
        grantee: [32]u8,
        granted_by: [32]u8,
        max_gas: u64,
    ) Self {
        return .{
            .id = ObjectID.hash(tool_id.asBytes()),
            .tool_id = tool_id,
            .grantee = grantee,
            .granted_by = granted_by,
            .max_gas = max_gas,
            .rate_limit = 100,
            .is_revoked = false,
            .expires_at = 0,
        };
    }

    /// Check if valid
    pub fn isValid(self: Self) bool {
        if (self.is_revoked) return false;
        if (self.expires_at > 0 and std.time.timestamp() > self.expires_at) {
            return false;
        }
        return true;
    }
};

/// Tool version for upgrade tracking
pub const ToolVersion = struct {
    const Self = @This();

    /// Version number
    version: u32,
    /// Tool ID this belongs to
    tool_id: ObjectID,
    /// Schema hash
    schema_hash: [32]u8,
    /// Migration instructions
    migration: ?[]const u8,
    /// Is mandatory upgrade
    is_mandatory: bool,
    /// Release notes
    release_notes: []const u8,
    /// Release date
    released_at: i64,

    /// Check if schema is compatible
    pub fn isCompatible(self: Self, other_schema_hash: [32]u8) bool {
        return std.mem.eql(u8, &self.schema_hash, &other_schema_hash);
    }
};

/// Tool registry manager
pub const ToolRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    tools: std.StringArrayHashMap(Tool),
    invocations: std.StringArrayHashMap(ToolInvocation),

    /// Initialize registry
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tools = std.StringArrayHashMap(Tool).init(allocator),
            .invocations = std.StringArrayHashMap(ToolInvocation).init(allocator),
        };
    }

    /// Register a new tool
    pub fn registerTool(self: *Self, tool: Tool) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{
            tool.namespace, tool.name,
        });
        try self.tools.put(key, tool);
    }

    /// Find tool by name
    pub fn findTool(self: *Self, namespace: []const u8, name: []const u8) ?Tool {
        const key = std.fmt.comptimePrint("{s}.{s}", .{ namespace, name });
        return self.tools.get(key);
    }

    /// List tools by category
    pub fn listByCategory(self: *Self, category: ToolCategory) ![]const Tool {
        var results = std.ArrayList(Tool).init(self.allocator);
        for (self.tools.values()) |tool| {
            if (tool.category == category) {
                try results.append(tool);
            }
        }
        return results.toOwnedSlice();
    }

    /// Record invocation
    pub fn recordInvocation(self: *Self, invocation: ToolInvocation) !void {
        const key = invocation.id.asBytes();
        try self.invocations.put(key, invocation);
    }
};

test "Tool registration" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer _ = registry.deinit();
    
    const owner = [_]u8{0x42} ** 32;
    var tool = Tool.register(
        "transfer",
        "sui",
        "Transfer tokens",
        .Financial,
        owner,
    );
    
    try registry.registerTool(tool);
    
    const found = registry.findTool("sui", "transfer");
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.category == .Financial);
}

test "Tool invocation validity" {
    const tool_id = ObjectID.hash("tool");
    
    var invocation = ToolInvocation{
        .id = ObjectID.hash("inv"),
        .tool_id = tool_id,
        .caller = [_]u8{0x55} ** 32,
        .session_id = null,
        .parameters = "{\"amount\": 100}",
        .gas_offered = 1000,
        .timestamp = std.time.timestamp(),
        .result = null,
    };
    
    try std.testing.expect(invocation.isValid());
}

test "Tool result creation" {
    const result = ToolResult.success("{\"status\": \"ok\"}", 500);
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_used == 500);
}

test "ToolPermission validity" {
    const tool_id = ObjectID.hash("tool");
    const grantee = [_]u8{0x55} ** 32;
    const granted_by = [_]u8{0x42} ** 32;
    
    var perm = ToolPermission.grant(tool_id, grantee, granted_by, 5000);
    try std.testing.expect(perm.isValid());
    
    perm.is_revoked = true;
    try std.testing.expect(!perm.isValid());
}
