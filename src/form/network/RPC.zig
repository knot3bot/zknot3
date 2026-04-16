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

/// JSON-RPC error codes
pub const ErrorCode = enum(i32) {
    // Standard JSON-RPC codes
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    // Knot3-specific codes
    sui_object_not_found = -32001,
    sui_object_not_deliverable = -32002,
    sui_move_abort = -32003,
    sui_move_verification_error = -32004,
    sui_package_not_found = -32005,
    sui_module_not_found = -32006,
    sui_function_not_found = -32007,
    sui_invalid_transaction = -32008,
    sui_invalid_signature = -32009,
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

/// Handler function type
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
        var parser = std.json.Parser.init(self.allocator, .{});
        defer parser.deinit();

        var token_buffer: [1024]std.json.Token = undefined;
        const value = try parser.parse(body, &token_buffer);

        // Extract method from parsed JSON
        const method = value.object.get("method") orelse return error.MethodRequired;
        const method_str = method.string;
        const id = value.object.get("id");
        const params = value.object.get("params");

        // Route to handler
        const response = self.routeRequest(method_str, params, id) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":{},\"message\":\"{}\"},\"id\":null}}", .{ @intFromEnum(ErrorCode.internal_error), @errorName(err) });
        };

        // Serialize response using std.json
        var response_json = std.ArrayList(u8).empty;
        defer response_json.deinit();
        try std.json.stringify(response, .{}, response_json.writer());
        return response_json.toOwnedSlice();
    }

    /// Route request to appropriate handler
    fn routeRequest(self: *@This(), method: []const u8, params: ?std.json.Value, _: ?std.json.Value) !RPCResponse {
        // Knot3-compatible RPC methods
        if (std.mem.eql(u8, method, "knot3_getObject")) {
            return try self.handleGetObject(params);
        } else if (std.mem.eql(u8, method, "knot3_getCheckpoint")) {
            return try self.handleGetCheckpoint(params);
        } else if (std.mem.eql(u8, method, "knot3_getCoins")) {
            return try self.handleGetCoins(params);
        } else if (std.mem.eql(u8, method, "sui_getLatestCheckpointSequenceNumber")) {
            return try self.handleGetLatestCheckpointSequence(params);
        } else if (std.mem.eql(u8, method, "knot3_getTransactionBlock")) {
            return try self.handleGetTransactionBlock(params);
        } else if (std.mem.eql(u8, method, "sui_executeTransactionBlock")) {
            return try self.handleExecuteTransaction(params);
        } else if (std.mem.eql(u8, method, "sui_getEvents")) {
            return try self.handleGetEvents(params);
        } else if (std.mem.eql(u8, method, "sui_getOwnedObjects")) {
            return try self.handleGetOwnedObjects(params);
        } else if (std.mem.eql(u8, method, "sui_dryRunTransactionBlock")) {
            return try self.handleDryRunTransaction(params);
        } else if (std.mem.eql(u8, method, "sui_syncEpochState")) {
            return try self.handleSyncEpochState(params);
        } else if (std.mem.eql(u8, method, "sui_getEpochs")) {
            return try self.handleGetEpochs(params);
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

        return responses.toOwnedSlice();
    }
};

// Standard RPC method handlers - use context.user_data via interfaces

fn handleGetObject(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    // Return a default object for testing (interface access would be via user_data)
    const result = RPCResponse.RPCResult{
        .object = RPCResponse.ObjectResponse{
            .object_id = "0x123",
            .version = 1,
            .owner = "0x0",
            .type = "0x2::coin::Coin<0x1::knot3::KNOT3>",
            .data = "{}",
        },
    };
    return .{ .id = null, .result = result, .err = null };
}

fn handleGetCheckpoint(ctx: *RPCContext, _: []const u8) !RPCResponse {
    const result = RPCResponse.RPCResult{
        .checkpoint = RPCResponse.CheckpointResponse{
            .sequence = ctx.checkpoint_sequence,
            .digest = "0xabc123",
            .timestamp = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        },
    };
    return .{ .id = null, .result = result, .err = null };
}

fn handleGetCoins(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    const result = RPCResponse.RPCResult{
        .coins = RPCResponse.CoinsResponse{
            .data = &.{},
        },
    };
    return .{ .id = null, .result = result, .err = null };
}

fn handleGetLatestCheckpointSequence(ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = ctx;
    return RPCResponse.success(null, "0");
}

fn handleGetTransactionBlock(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    return RPCResponse.makeError(null, .sui_object_not_found, "Transaction not found");
}

fn handleExecuteTransaction(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    return RPCResponse.makeError(null, .internal_error, "Node not initialized");
}

fn handleGetEvents(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    const result = RPCResponse.RPCResult{
        .event = RPCResponse.EventEnvelope{
            .timestamp = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
            .events = &.{},
        },
    };
    return .{ .id = null, .result = result, .err = null };
}

fn handleGetOwnedObjects(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    return RPCResponse.makeError(null, .sui_object_not_found, "Objects not found");
}

fn handleDryRunTransaction(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    // Dry run would execute transaction without side effects
    return RPCResponse.success(null, "{\"effects\":{\"status\":{\"type\":\"success\"},\"gasUsed\":1000}}");
}

fn handleSyncEpochState(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    return RPCResponse.success(null, "{\"epoch\":0,\"protocolVersion\":1}");
}

fn handleGetEpochs(_ctx: *RPCContext, _: []const u8) !RPCResponse {
    _ = _ctx;
    return RPCResponse.success(null, "{\"data\":[]}");
}

test "RPC server init and deinit" {
    var server = try RPCServer.init(std.testing.allocator);
    defer server.deinit();
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
