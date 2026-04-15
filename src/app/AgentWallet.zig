//! Agent Wallet - Token-bound AI Account System
//!
//! Provides native token management for AI agents:
//! - Token-bound accounts linked to agent identity
//! - Spending limits and quotas
//! - Multi-sig authorization for large transactions
//! - Treasury management for agent collectives

const std = @import("std");
const core = @import("../core.zig");
const ObjectID = core.ObjectID;

/// Token type
pub const TokenType = enum(u8) {
    Native = 0,
    KNOT3 = 1,
    USDC = 2,
    Custom = 3,
};

/// Balance for a specific token type
pub const TokenBalance = struct {
    const Self = @This();

    token_type: TokenType,
    balance: u64,
    locked_balance: u64,
    updated_at: i64,

    /// Available balance (total - locked)
    pub fn available(self: Self) u64 {
        return self.balance - self.locked_balance;
    }

    /// Check if can spend amount
    pub fn canSpend(self: Self, amount: u64) bool {
        return self.available() >= amount;
    }

    /// Create zero balance
    pub fn zero(token_type: TokenType) Self {
        return .{
            .token_type = token_type,
            .balance = 0,
            .locked_balance = 0,
            .updated_at = std.time.timestamp(),
        };
    }
};

/// Spending limit configuration
pub const SpendingLimit = struct {
    const Self = @This();

    /// Maximum per transaction
    per_transaction: u64,
    /// Maximum per hour
    per_hour: u64,
    /// Maximum per day
    per_day: u64,
    /// Current hour spending
    hour_spent: u64,
    /// Current day spending
    day_spent: u64,
    /// Hour reset timestamp
    hour_reset: i64,
    /// Day reset timestamp
    day_reset: i64,

    /// Check if amount is within limit
    pub fn allows(self: *Self, amount: u64) bool {
        const now = std.time.timestamp();
        
        // Reset counters if needed
        if (now >= self.hour_reset) {
            self.hour_spent = 0;
            self.hour_reset = now + 3600;
        }
        if (now >= self.day_reset) {
            self.day_spent = 0;
            self.day_reset = now + 86400;
        }
        
        return amount <= self.per_transaction and
               (self.hour_spent + amount) <= self.per_hour and
               (self.day_spent + amount) <= self.per_day;
    }

    /// Record spending
    pub fn recordSpend(self: *Self, amount: u64) void {
        self.hour_spent += amount;
        self.day_spent += amount;
    }
};

/// Agent wallet - token-bound account
pub const AgentWallet = struct {
    const Self = @This();

    /// Wallet ID (derived from agent ID)
    id: ObjectID,
    /// Associated agent ID
    agent_id: ObjectID,
    /// Owner (human) address
    owner: [32]u8,
    /// Token balances
    balances: std.ArrayList(TokenBalance),
    /// Spending limits
    spending_limit: SpendingLimit,
    /// Is frozen (no transactions)
    is_frozen: bool,
    /// Created at
    created_at: i64,

    /// Create new agent wallet
    pub fn create(agent_id: ObjectID, owner: [32]u8) Self {
        return .{
            .id = ObjectID.hash(agent_id.asBytes()),
            .agent_id = agent_id,
            .owner = owner,
            .balances = std.ArrayList(TokenBalance).init(std.heap.page_allocator),
            .spending_limit = .{
                .per_transaction = 1_000_000,
                .per_hour = 10_000_000,
                .per_day = 100_000_000,
                .hour_spent = 0,
                .day_spent = 0,
                .hour_reset = std.time.timestamp() + 3600,
                .day_reset = std.time.timestamp() + 86400,
            },
            .is_frozen = false,
            .created_at = std.time.timestamp(),
        };
	    /// Deinitialize wallet and free resources
	    pub fn deinit(self: *Self) void {
	        self.balances.deinit();
	    }

	    /// Check if can transact
    /// Get balance for token type
    pub fn getBalance(self: *Self, token_type: TokenType) ?u64 {
        for (self.balances.items) |balance| {
            if (balance.token_type == token_type) {
                return balance.available();
            }
        }
        return null;
    }

    /// Add balance
    pub fn deposit(self: *Self, token_type: TokenType, amount: u64) !void {
        if (self.is_frozen) return error.WalletFrozen;
        
        for (self.balances.items) |*balance| {
            if (balance.token_type == token_type) {
                balance.balance += amount;
                balance.updated_at = std.time.timestamp();
                return;
            }
        }
        
        // New token type
        var new_balance = TokenBalance.zero(token_type);
        new_balance.balance = amount;
        try self.balances.append(new_balance);
    }

    /// Withdraw balance
    pub fn withdraw(self: *Self, token_type: TokenType, amount: u64) !void {
        if (self.is_frozen) return error.WalletFrozen;
        
        for (self.balances.items) |*balance| {
            if (balance.token_type == token_type) {
                if (balance.available() < amount) {
                    return error.InsufficientBalance;
                }
                if (!self.spending_limit.allows(amount)) {
                    return error.SpendingLimitExceeded;
                }
                balance.balance -= amount;
                balance.updated_at = std.time.timestamp();
                self.spending_limit.recordSpend(amount);
                return;
            }
        }
        
        return error.TokenNotFound;
    }

    /// Freeze wallet
    pub fn freeze(self: *Self) void {
        self.is_frozen = true;
    }

    /// Unfreeze wallet
    pub fn unfreeze(self: *Self) void {
        self.is_frozen = false;
    }
};

/// Treasury for agent collectives
pub const AgentTreasury = struct {
    const Self = @This();

    /// Treasury ID
    id: ObjectID,
    /// Name
    name: []const u8,
    /// Member agent IDs
    members: std.ArrayList(ObjectID),
    /// Required signatures for action
    required_signatures: u32,
    /// Total balance across all tokens
    total_balance: u64,
    /// Created at
    created_at: i64,
    /// Is active
    is_active: bool,

    /// Create new treasury
    pub fn create(
        name: []const u8,
        required_signatures: u32,
    ) Self {
        return .{
            .id = ObjectID.hash(name),
            .name = name,
            .members = std.ArrayList(ObjectID).init(std.heap.page_allocator),
            .required_signatures = required_signatures,
            .total_balance = 0,
            .created_at = std.time.timestamp(),
            .is_active = true,
        };
    }

    /// Add member
    pub fn addMember(self: *Self, agent_id: ObjectID) !void {
        try self.members.append(agent_id);
    }

    /// Remove member
    pub fn removeMember(self: *Self, agent_id: ObjectID) void {
        for (self.members.items) |mid, i| {
            if (mid.eql(agent_id)) {
                _ = self.members.orderedRemove(i);
                return;
            }
        }
	    }
	
	    /// Deinitialize treasury and free resources
	    pub fn deinit(self: *Self) void {
	        self.members.deinit();
	    }
	
	    /// Check if quorum reached
    pub fn hasQuorum(self: Self, signatures: u32) bool {
        return signatures >= self.required_signatures;
    }
};

/// Transaction authorization request
pub const AuthRequest = struct {
    const Self = @This();

    /// Request ID
    id: ObjectID,
    /// Wallet to authorize
    wallet_id: ObjectID,
    /// Transaction amount
    amount: u64,
    /// Recipient
    recipient: [32]u8,
    /// Human owner who must approve
    owner: [32]u8,
    /// Is approved
    is_approved: bool,
    /// Created at
    created_at: i64,
    /// Expires at
    expires_at: i64,

    /// Check if valid
    pub fn isValid(self: Self) bool {
        const now = std.time.timestamp();
        return !self.is_approved and now < self.expires_at;
    }

    /// Approve request
    pub fn approve(self: *Self) void {
        self.is_approved = true;
    }
};

test "TokenBalance available" {
    var balance = TokenBalance.zero(.Native);
    balance.balance = 1000;
    balance.locked_balance = 300;
    
    try std.testing.expect(balance.available() == 700);
    try std.testing.expect(balance.canSpend(500));
    try std.testing.expect(!balance.canSpend(800));
}

test "AgentWallet create" {
    const agent_id = ObjectID.hash("agent");
    const owner = [_]u8{0x42} ** 32;
    
    var wallet = AgentWallet.create(agent_id, owner);
    
    try std.testing.expect(!wallet.is_frozen);
    try std.testing.expect(wallet.canTransact());
}

test "AgentWallet deposit and withdraw" {
    const agent_id = ObjectID.hash("agent");
    const owner = [_]u8{0x42} ** 32;
    
    var wallet = AgentWallet.create(agent_id, owner);
    
    try wallet.deposit(.KNOT3, 1000);
    try std.testing.expect((try wallet.getBalance(.KNOT3)) == 1000);
    
    try wallet.withdraw(.KNOT3, 500);
    try std.testing.expect((try wallet.getBalance(.KNOT3)) == 500);
}

test "AgentWallet freeze" {
    const agent_id = ObjectID.hash("agent");
    const owner = [_]u8{0x42} ** 32;
    
    var wallet = AgentWallet.create(agent_id, owner);
    
    try wallet.deposit(.KNOT3, 1000);
    wallet.freeze();
    
    try std.testing.expect(!wallet.canTransact());
}

test "SpendingLimit" {
    var limit = SpendingLimit{
        .per_transaction = 100,
        .per_hour = 500,
        .per_day = 1000,
        .hour_spent = 0,
        .day_spent = 0,
        .hour_reset = std.time.timestamp() + 3600,
        .day_reset = std.time.timestamp() + 86400,
    };
    
    try std.testing.expect(limit.allows(50));
    try std.testing.expect(limit.allows(100));
    try std.testing.expect(!limit.allows(200)); // per transaction
    
    limit.recordSpend(100);
    try std.testing.expect(!limit.allows(500)); // would exceed hourly
}

test "AgentTreasury quorum" {
    var treasury = AgentTreasury.create("Test Treasury", 2);
    
    try treasury.addMember(ObjectID.hash("agent1"));
    try treasury.addMember(ObjectID.hash("agent2"));
    try treasury.addMember(ObjectID.hash("agent3"));
    
    try std.testing.expect(!treasury.hasQuorum(1)); // need 2
    try std.testing.expect(treasury.hasQuorum(2));
    try std.testing.expect(treasury.hasQuorum(3));
}

test "AuthRequest validity" {
    const req = AuthRequest{
        .id = ObjectID.hash("req"),
        .wallet_id = ObjectID.hash("wallet"),
        .amount = 1000,
        .recipient = [_]u8{0x55} ** 32,
        .owner = [_]u8{0x42} ** 32,
        .is_approved = false,
        .created_at = std.time.timestamp(),
        .expires_at = std.time.timestamp() + 3600,
    };
    
    try std.testing.expect(req.isValid());
}
