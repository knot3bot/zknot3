//! RPC - JSON-RPC 2.0 interface with Knot3-compatible methods
//!
//! Implements the core RPC methods needed for a Knot3-like blockchain.
//! Uses std.json for JSON parsing and std.http for HTTP server.
//!
//! Architecture: Handlers access node capabilities via RPCContext.user_data
//! which is typed as *anyopaque and should be cast to the appropriate interface.

const std = @import("std");
const core = @import("../../core.zig");
const pipeline = @import("../../pipeline.zig");
const Node = @import("../../app/Node.zig").Node;
const MainnetExtensionHooks = @import("../../app/MainnetExtensionHooks.zig");
const M4RpcParams = @import("M4RpcParams.zig");

/// JSON-RPC error codes
pub const ErrorCode = enum(i32) {
    // Standard JSON-RPC codes
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    // Knot3-specific codes
    knot3_object_not_found = -32001,
    knot3_object_not_deliverable = -32002,
    knot3_move_abort = -32003,
    knot3_move_verification_error = -32004,
    knot3_package_not_found = -32005,
    knot3_module_not_found = -32006,
    knot3_function_not_found = -32007,
    knot3_invalid_transaction = -32008,
    knot3_invalid_signature = -32010,
};

/// JSON-RPC request
pub const RPCRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RPCID,
    method: []u8,
    params: ?RPCParams,

    pub const RPCID = union(enum) {
        number: i64,
        string: []u8,
    };

    pub const RPCParams = struct {
        data: ?[]const u8,
    };
};

/// JSON-RPC response
pub const RPCResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RPCRequest.RPCID,
    result: ?RPCResult,
    err: ?RPCError,

    pub const RPCResult = union(enum) {
        success: []const u8,
        event: ?EventEnvelope,
        object: ?ObjectResponse,
        checkpoint: ?CheckpointResponse,
        coins: ?CoinsResponse,
    };

    pub const EventEnvelope = struct {
        timestamp: i64,
        events: []const EventData,
    };

    pub const EventData = struct {
        type: []u8,
        contents: []u8,
    };

    pub const ObjectResponse = struct {
        object_id: []u8,
        version: u64,
        owner: []u8,
        type: []u8,
        data: []u8,
    };

    pub const CheckpointResponse = struct {
        sequence: u64,
        digest: []u8,
        timestamp: i64,
    };

    pub const CoinsResponse = struct {
        data: []const CoinInfo,
    };

    pub const CoinInfo = struct {
        coin_object_id: []u8,
        version: u64,
        coin_type: []u8,
        balance: u64,
    };

    pub const RPCError = struct {
        code: ErrorCode,
        message: []const u8,
        data: ?[]u8 = null,
    };

    pub fn success(id: ?RPCRequest.RPCID, result: []const u8) @This() {
        return .{
            .id = id,
            .result = .{ .success = result },
            .err = null,
        };
    }

    pub fn makeError(id: ?RPCRequest.RPCID, code: ErrorCode, message: []const u8) @This() {
        return .{
            .id = id,
            .result = null,
            .err = .{ .code = code, .message = message },
        };
    }
};

/// RPC context for handlers - uses interface-based access
pub const RPCContext = struct {
    allocator: std.mem.Allocator,
    checkpoint_sequence: u64,
    user_data: ?*anyopaque = null,
};

/// Handler function type (legacy register path; uses opaque param bytes)
const HandlerFn = fn (ctx: *RPCContext, params: []const u8) anyerror!RPCResponse;

/// RPC server
pub const RPCServer = struct {
    allocator: std.mem.Allocator,
    context: *RPCContext,

    // Store handlers as pointers to allow dynamic dispatch
    handlers: std.StringArrayHashMapUnmanaged(*const HandlerFn),

    pub fn init(allocator: std.mem.Allocator) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .handlers = std.StringArrayHashMapUnmanaged(*const HandlerFn).empty,
            .context = try allocator.create(RPCContext),
        };
        self.context.* = .{
            .allocator = allocator,
            .checkpoint_sequence = 0,
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.handlers.deinit(self.allocator);
        self.allocator.destroy(self.context);
        self.allocator.destroy(self);
    }

    /// Set checkpoint sequence
    pub fn setCheckpointSequence(self: *@This(), seq: u64) void {
        self.context.checkpoint_sequence = seq;
    }

    /// Set user data (e.g., *Node for transaction execution)
    pub fn setUserData(self: *@This(), data: *anyopaque) void {
        self.context.user_data = data;
    }

    /// Register a method handler
    pub fn register(self: *@This(), name: []const u8, handler: *const HandlerFn) !void {
        try self.handlers.put(self.allocator, name, handler);
    }

    /// Handle HTTP request (used by HTTPServer)
    pub fn handleHTTPRequest(self: *@This(), body: []const u8) ![]u8 {
        // Parse JSON-RPC request using std.json
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const value = parsed.value;

        // Extract method from parsed JSON
        const method = value.object.get("method") orelse return error.MethodRequired;
        const method_str = method.string;
        const id = value.object.get("id");
        const params = value.object.get("params");

        // Route to handler
        const response = self.routeRequest(method_str, params, id) catch |err| {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{},\"message\":\"{s}\"}},\"id\":null}}",
                .{ @intFromEnum(ErrorCode.internal_error), @errorName(err) },
            );
        };

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(response, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    /// Route request to appropriate handler
    fn routeRequest(self: *@This(), method: []const u8, params: ?std.json.Value, _: ?std.json.Value) !RPCResponse {
        // Knot3-compatible RPC methods
        if (std.mem.eql(u8, method, "knot3_getObject")) {
            return try handleGetObject(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_getCheckpoint")) {
            return try handleGetCheckpoint(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_getCoins")) {
            return try handleGetCoins(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_getLatestCheckpointSequenceNumber")) {
            return try handleGetLatestCheckpointSequence(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_getTransactionBlock")) {
            return try handleGetTransactionBlock(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_executeTransactionBlock")) {
            return try handleExecuteTransaction(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_getEvents")) {
            return try handleGetEvents(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_getOwnedObjects")) {
            return try handleGetOwnedObjects(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_dryRunTransactionBlock")) {
            return try handleDryRunTransaction(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_syncEpochState")) {
            return try handleSyncEpochState(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_getEpochs")) {
            return try handleGetEpochs(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_submitStakeOperation")) {
            return try handleSubmitStakeOperation(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_submitGovernanceProposal")) {
            return try handleSubmitGovernanceProposal(self.context, params);
        } else if (std.mem.eql(u8, method, "knot3_getCheckpointProof")) {
            return try handleGetCheckpointProof(self.context, params);
        } else {
            return RPCResponse.makeError(null, .method_not_found, "Method not found");
        }
    }

    /// Handle raw JSON request string (legacy compatibility)
    pub fn handleJSON(self: *@This(), json: []const u8) ![]u8 {
        return self.handleHTTPRequest(json);
    }

    /// Handle incoming request
    pub fn handle(self: *@This(), request: RPCRequest) !RPCResponse {
        if (self.handlers.get(request.method)) |handler| {
            const params = request.params orelse .{ .data = null };
            _ = try handler(self.context, params.data orelse &.{});
            return RPCResponse.success(request.id, "result");
        } else {
            return RPCResponse.makeError(request.id, .method_not_found, "Method not found");
        }
    }

    /// Handle batch requests
    pub fn handleBatch(self: *@This(), requests: []const RPCRequest) ![]RPCResponse {
        var responses = try std.ArrayList(RPCResponse).initCapacity(self.allocator, requests.len);
        errdefer responses.deinit(self.allocator);

        for (requests) |req| {
            const resp = self.handle(req) catch |err| {
                try responses.append(self.allocator, RPCResponse.makeError(req.id, .internal_error, @errorName(err)));
                continue;
            };
            try responses.append(self.allocator, resp);
        }

        return responses.toOwnedSlice(self.allocator);
    }
};

// Standard RPC method handlers - use context.user_data via interfaces

fn handleGetObject(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    // Return a default object for testing (interface access would be via user_data)
    const result = RPCResponse.RPCResult{
        .object = RPCResponse.ObjectResponse{
            .object_id = @as([]u8, @constCast("0x123")),
            .version = 1,
            .owner = @as([]u8, @constCast("0x0")),
            .type = @as([]u8, @constCast("0x2::coin::Coin<0x1::knot3::KNOT3>")),
            .data = @as([]u8, @constCast("{}")),
        },
    };
    return .{ .id = null, .result = result, .err = null };
}

fn handleGetCheckpoint(ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    const result = RPCResponse.RPCResult{
        .checkpoint = RPCResponse.CheckpointResponse{
            .sequence = ctx.checkpoint_sequence,
            .digest = @as([]u8, @constCast("0xabc123")),
            .timestamp = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        },
    };
    return .{ .id = null, .result = result, .err = null };
}

fn handleGetCoins(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    const result = RPCResponse.RPCResult{
        .coins = RPCResponse.CoinsResponse{
            .data = &.{},
        },
    };
    return .{ .id = null, .result = result, .err = null };
}

fn handleGetLatestCheckpointSequence(ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = ctx;
    return RPCResponse.success(null, "0");
}

fn handleGetTransactionBlock(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    return RPCResponse.makeError(null, .knot3_object_not_found, "Transaction not found");
}

fn handleExecuteTransaction(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    return RPCResponse.makeError(null, .internal_error, "Node not initialized");
}

fn handleGetEvents(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    const result = RPCResponse.RPCResult{
        .event = RPCResponse.EventEnvelope{
            .timestamp = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .events = &.{},
        },
    };
    return .{ .id = null, .result = result, .err = null };
}

fn handleGetOwnedObjects(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    return RPCResponse.makeError(null, .knot3_object_not_found, "Objects not found");
}

fn handleDryRunTransaction(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    // Dry run would execute transaction without side effects
    return RPCResponse.success(null, "{\"effects\":{\"status\":{\"type\":\"success\"},\"gasUsed\":1000}}");
}

fn handleSyncEpochState(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    return RPCResponse.success(null, "{\"epoch\":0,\"protocolVersion\":1}");
}

fn handleGetEpochs(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    return RPCResponse.success(null, "{\"data\":[]}");
}

fn handleSubmitStakeOperation(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node_ptr = ctx.user_data orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const node: *Node = @ptrCast(@alignCast(node_ptr));
    const input = M4RpcParams.parseStakeOperationInput(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_submitStakeOperation params");
    };
    const operation_id = node.submitStakeOperation(input) catch |err| {
        return RPCResponse.makeError(null, .internal_error, @errorName(err));
    };
    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"status\":\"accepted\",\"operationId\":{d}}}", .{operation_id});
    return RPCResponse.success(null, body);
}

fn handleSubmitGovernanceProposal(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node_ptr = ctx.user_data orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const node: *Node = @ptrCast(@alignCast(node_ptr));
    const input = M4RpcParams.parseGovernanceProposalInput(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_submitGovernanceProposal params");
    };
    const proposal_id = node.submitGovernanceProposal(input) catch |err| {
        return RPCResponse.makeError(null, .internal_error, @errorName(err));
    };
    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"status\":\"accepted\",\"proposalId\":{d}}}", .{proposal_id});
    return RPCResponse.success(null, body);
}

fn handleGetCheckpointProof(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node_ptr = ctx.user_data orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const node: *Node = @ptrCast(@alignCast(node_ptr));
    const req = M4RpcParams.parseCheckpointProofRequest(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getCheckpointProof params");
    };
    const proof = node.buildCheckpointProof(req) catch |err| {
        return RPCResponse.makeError(null, .internal_error, @errorName(err));
    };
    defer node.freeCheckpointProof(proof);
    const proof_hex = try MainnetExtensionHooks.allocHexLower(ctx.allocator, proof.proof_bytes);
    defer ctx.allocator.free(proof_hex);
    const sig_hex = try MainnetExtensionHooks.allocHexLower(ctx.allocator, proof.signatures);
    defer ctx.allocator.free(sig_hex);
    const bls_sig_hex = try MainnetExtensionHooks.allocHexLower(ctx.allocator, proof.bls_signature);
    defer ctx.allocator.free(bls_sig_hex);
    const bls_bitmap_hex = try MainnetExtensionHooks.allocHexLower(ctx.allocator, proof.bls_signer_bitmap);
    defer ctx.allocator.free(bls_bitmap_hex);
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"sequence\":{d},\"stateRoot\":\"{x}\",\"proof\":\"{s}\",\"signatures\":\"{s}\",\"bls_signature\":\"{s}\",\"bls_signer_bitmap\":\"{s}\"}}",
        .{ proof.sequence, proof.state_root, proof_hex, sig_hex, bls_sig_hex, bls_bitmap_hex },
    );
    return RPCResponse.success(null, body);
}

test "RPC server init and deinit" {
    var server = try RPCServer.init(std.testing.allocator);
    defer server.deinit();

    try std.testing.expect(server.handlers.count() == 0);
}

test "RPC error response" {
    const resp = RPCResponse.makeError(null, .method_not_found, "Method not found");
    try std.testing.expect(resp.err != null);
    try std.testing.expect(resp.err.?.code == .method_not_found);
}

test "RPC success response" {
    const resp = RPCResponse.success(null, "test result");
    try std.testing.expect(resp.result != null);
    try std.testing.expect(resp.err == null);
}

test "RPC context creation" {
    const allocator = std.testing.allocator;
    const ctx = RPCContext{
        .allocator = allocator,
        .checkpoint_sequence = 0,
    };

    try std.testing.expect(ctx.checkpoint_sequence == 0);
}

test "RPC m4 methods call node mainnet hooks" {
    const Config = @import("../../app/Config.zig").Config;
    const NodeDependencies = @import("../../app/Node.zig").NodeDependencies;
    const allocator = std.testing.allocator;

    const config = try allocator.create(Config);
    defer allocator.destroy(config);
    config.* = Config.default();
    config.authority.signing_key = [_]u8{0x22} ** 32;
    config.authority.stake = 1_000_000_000;

    const node = try Node.init(allocator, config, NodeDependencies{});
    defer node.deinit();

    var ctx = RPCContext{
        .allocator = allocator,
        .checkpoint_sequence = 7,
        .user_data = @ptrCast(node),
    };

    const z64 = "0000000000000000000000000000000000000000000000000000000000000000";
    const stake_body = try std.fmt.allocPrint(allocator, "{{\"validator\":\"0x{s}\",\"delegator\":\"0x{s}\",\"amount\":1,\"action\":\"stake\",\"metadata\":\"t\"}}", .{ z64, z64 });
    defer allocator.free(stake_body);
    var stake_params1 = try std.json.parseFromSlice(std.json.Value, allocator, stake_body, .{ .ignore_unknown_fields = true });
    defer stake_params1.deinit();
    const stake_1 = try handleSubmitStakeOperation(&ctx, stake_params1.value);
    var stake_params2 = try std.json.parseFromSlice(std.json.Value, allocator, stake_body, .{ .ignore_unknown_fields = true });
    defer stake_params2.deinit();
    const stake_2 = try handleSubmitStakeOperation(&ctx, stake_params2.value);
    try std.testing.expect(stake_1.result != null);
    try std.testing.expect(stake_2.result != null);
    try std.testing.expect(std.mem.indexOf(u8, stake_1.result.?.success, "\"operationId\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stake_2.result.?.success, "\"operationId\":2") != null);

    const gov_body = try std.fmt.allocPrint(allocator, "{{\"proposer\":\"0x{s}\",\"title\":\"Proposal A\",\"description\":\"Body text\",\"kind\":\"parameter_change\"}}", .{z64});
    defer allocator.free(gov_body);
    var gov_params = try std.json.parseFromSlice(std.json.Value, allocator, gov_body, .{ .ignore_unknown_fields = true });
    defer gov_params.deinit();
    const proposal = try handleSubmitGovernanceProposal(&ctx, gov_params.value);
    try std.testing.expect(proposal.result != null);
    try std.testing.expect(std.mem.indexOf(u8, proposal.result.?.success, "\"proposalId\":1") != null);

    const proof_body = try std.fmt.allocPrint(allocator, "{{\"sequence\":7,\"objectId\":\"0x{s}\"}}", .{z64});
    defer allocator.free(proof_body);
    const proof_params = try std.json.parseFromSlice(std.json.Value, allocator, proof_body, .{ .ignore_unknown_fields = true });
    defer proof_params.deinit();
    const proof = try handleGetCheckpointProof(&ctx, proof_params.value);
    try std.testing.expect(proof.result != null);
    try std.testing.expect(std.mem.indexOf(u8, proof.result.?.success, "\"sequence\":7") != null);
}
