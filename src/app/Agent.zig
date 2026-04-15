//! Agent Identity - AI Agent Infrastructure
//!
//! Provides native support for AI agents on the blockchain:
//! - Agent identity with cryptographic verification
//! - Token-bound agent accounts
//! - Agent capability delegation
//! - Agent transaction signing

const std = @import("std");
const core = @import("../core.zig");
const ObjectID = core.ObjectID;
const Ownership = core.Ownership;

/// Agent type classification
pub const AgentType = enum(u8) {
    /// Autonomous AI agent
    Autonomous = 0,
    /// Human-controlled agent
    HumanControlled = 1,
    /// Multi-signature agent (human + AI)
    MultiSig = 2,
    /// Organization agent
    Organizational = 3,
};

/// Agent permissions/capabilities
pub const AgentPermission = struct {
    /// Can execute transactions
    can_transact: bool = true,
    /// Can own objects
    can_own_objects: bool = true,
    /// Can delegate permissions
    can_delegate: bool = false,
    /// Can create sub-agents
    can_create_subagents: bool = false,
    /// Can manage treasury
    can_manage_treasury: bool = false,
};

/// Agent metadata for on-chain discovery
pub const AgentMetadata = struct {
    name: []const u8,
    description: []const u8,
    version: []const u8,
    capabilities: []const u8, // JSON schema of supported capabilities
    endpoint: ?[]const u8, // Optional API endpoint for agent
};

/// Agent Identity - cryptographic identity for AI agents
pub const AgentId = struct {
    const Self = @This();

    /// Unique agent identifier (ObjectID-based)
    id: ObjectID,
    /// Agent type
    agent_type: AgentType,
    /// Owner address (human or organization)
    owner: [32]u8,
    /// Public key for verification
    public_key: [32]u8,
    /// Agent permissions
    permissions: AgentPermission,
    /// Creation timestamp
    created_at: i64,
    /// Is agent active
    is_active: bool,

    /// Create a new agent identity
    pub fn create(
        owner: [32]u8,
        agent_type: AgentType,
        public_key: [32]u8,
    ) Self {
        return .{
            .id = ObjectID.hash(owner[0..]),
            .agent_type = agent_type,
            .owner = owner,
            .public_key = public_key,
            .permissions = .{},
            .created_at = std.time.timestamp(),
            .is_active = true,
        };
    }

    /// Verify agent can perform action
    pub fn canPerform(self: Self, action: AgentAction) bool {
        if (!self.is_active) return false;

        return switch (action) {
            .transact => self.permissions.can_transact,
            .own_objects => self.permissions.can_own_objects,
            .delegate => self.permissions.can_delegate,
            .create_subagent => self.permissions.can_create_subagents,
            .manage_treasury => self.permissions.can_manage_treasury,
        };
    }

    /// Check if address is owner
    pub fn isOwner(self: Self, address: [32]u8) bool {
        return std.mem.eql(u8, &self.owner, &address);
    }
};

/// Actions an agent can perform
pub const AgentAction = enum {
    transact,
    own_objects,
    delegate,
    create_subagent,
    manage_treasury,
};

/// Agent session for temporary elevated permissions
pub const AgentSession = struct {
    const Self = @This();

    /// Session ID
    id: [32]u8,
    /// Agent that owns this session
    agent_id: ObjectID,
    /// Session owner (human who authorized)
    authorized_by: [32]u8,
    /// Granted permissions during session
    permissions: AgentPermission,
    /// Session start time
    started_at: i64,
    /// Session expiry
    expires_at: i64,
    /// Is session active
    is_active: bool,

    /// Check if session is valid
    pub fn isValid(self: Self) bool {
        if (!self.is_active) return false;
        const now = std.time.timestamp();
        return now < self.expires_at;
    }

    /// Check if action is allowed in session
    pub fn allows(self: Self, action: AgentAction) bool {
        if (!self.isValid()) return false;

        return switch (action) {
            .transact => self.permissions.can_transact,
            .own_objects => self.permissions.can_own_objects,
            .delegate => self.permissions.can_delegate,
            .create_subagent => self.permissions.can_create_subagents,
            .manage_treasury => self.permissions.can_manage_treasury,
        };
    }
};

/// Agent transaction for signing by AI agents
pub const AgentTransaction = struct {
    const Self = @This();

    /// Transaction digest
    digest: [32]u8,
    /// Agent ID that signed
    agent_id: ObjectID,
    /// Session ID (if using session)
    session_id: ?[32]u8,
    /// Actions to perform
    actions: []const AgentActionItem,
    /// Agent signature
    signature: [64]u8,
    /// Timestamp
    timestamp: i64,

    /// Action item in agent transaction
    pub const AgentActionItem = struct {
        action_type: AgentActionType,
        target: ObjectID,
        arguments: []const u8,
    };

    /// Types of actions
    pub const AgentActionType = enum {
        call_function,
        transfer_object,
        publish_module,
        mint_nft,
        stake,
        delegate,
    },
};

/// Agent capability certificate
pub const AgentCapability = struct {
    const Self = @This();

    /// Capability ID
    id: ObjectID,
    /// Grantor agent
    grantor: ObjectID,
    /// Grantee agent or address
    grantee: [32]u8,
    /// Granted permissions
    permissions: AgentPermission,
    /// Conditions (JSON encoded)
    conditions: ?[]const u8,
    /// Expiry time (0 = never)
    expires_at: i64,
    /// Is revoked
    is_revoked: bool,

    /// Create a new capability
    pub fn create(
        grantor: ObjectID,
        grantee: [32]u8,
        permissions: AgentPermission,
    ) Self {
        return .{
            .id = ObjectID.hash(grantor.asBytes()),
            .grantor = grantor,
            .grantee = grantee,
            .permissions = permissions,
            .conditions = null,
            .expires_at = 0,
            .is_revoked = false,
        };
    }

    /// Check if capability is valid
    pub fn isValid(self: Self) bool {
        if (self.is_revoked) return false;
        if (self.expires_at > 0) {
            return std.time.timestamp() < self.expires_at;
        }
        return true;
    }
};

/// Agent delegation record
pub const AgentDelegation = struct {
    const Self = @This();

    /// Delegation ID
    id: ObjectID,
    /// Original agent
    from_agent: ObjectID,
    /// Delegated agent
    to_agent: ObjectID,
    /// Delegated permissions
    permissions: AgentPermission,
    /// Is active
    is_active: bool,
    /// Created at
    created_at: i64,

    /// Create new delegation
    pub fn create(from: ObjectID, to: ObjectID, permissions: AgentPermission) Self {
        return .{
            .id = ObjectID.hash(from.asBytes()),
            .from_agent = from,
            .to_agent = to,
            .permissions = permissions,
            .is_active = true,
            .created_at = std.time.timestamp(),
        };
    }
};

test "AgentId creation" {
    const owner = [_]u8{0x42} ** 32;
    const public_key = [_]u8{0xAB} ** 32;
    
    const agent = AgentId.create(owner, .Autonomous, public_key);
    
    try std.testing.expect(agent.is_active);
    try std.testing.expect(agent.agent_type == .Autonomous);
    try std.testing.expect(agent.canPerform(.transact));
}

test "AgentId owner verification" {
    const owner = [_]u8{0x42} ** 32;
    const other = [_]u8{0x99} ** 32;
    const public_key = [_]u8{0xAB} ** 32;
    
    const agent = AgentId.create(owner, .Autonomous, public_key);
    
    try std.testing.expect(agent.isOwner(owner));
    try std.testing.expect(!agent.isOwner(other));
}

test "AgentSession validity" {
    const agent_id = ObjectID.hash("agent");
    const owner = [_]u8{0x42} ** 32;
    
    var session = AgentSession{
        .id = [_]u8{0x01} ** 32,
        .agent_id = agent_id,
        .authorized_by = owner,
        .permissions = .{.can_transact = true},
        .started_at = std.time.timestamp(),
        .expires_at = std.time.timestamp() + 3600, // 1 hour
        .is_active = true,
    };
    
    try std.testing.expect(session.isValid());
    try std.testing.expect(session.allows(.transact));
}

test "AgentCapability validity" {
    const agent_id = ObjectID.hash("agent");
    const grantee = [_]u8{0x55} ** 32;
    
    var cap = AgentCapability.create(agent_id, grantee, .{.can_delegate = true});
    
    try std.testing.expect(cap.isValid());
    
    cap.is_revoked = true;
    try std.testing.expect(!cap.isValid());
}
