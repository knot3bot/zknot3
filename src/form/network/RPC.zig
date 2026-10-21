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
const JsonRpc = @import("JsonRpc.zig");
const Indexer = @import("../../app/Indexer.zig");

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
    knot3_hardened_checkpoint_unavailable = -32011,
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

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.result) |r| {
            if (r == .success) {
                allocator.free(r.success);
            }
        }
    }
};

/// RPC context for handlers - uses interface-based access
pub const RPCContext = struct {
    allocator: std.mem.Allocator,
    checkpoint_sequence: u64,
    user_data: ?*anyopaque = null,
};

/// One handler shape for the builtin table and `register`.
const HandlerFn = fn (ctx: *RPCContext, params: ?std.json.Value) anyerror!RPCResponse;

const BuiltinMethod = struct {
    name: []const u8,
    /// Write methods require `X-Zknot3-Admin-Token` at the HTTP layer.
    write: bool,
    handler: *const HandlerFn,
};

const builtin_methods = [_]BuiltinMethod{
    .{ .name = "knot3_getObject", .write = false, .handler = handleGetObject },
    .{ .name = "knot3_getCheckpoint", .write = false, .handler = handleGetCheckpoint },
    .{ .name = "knot3_getHardenedCheckpoint", .write = false, .handler = handleGetHardenedCheckpoint },
    .{ .name = "knot3_getCoins", .write = false, .handler = handleGetCoins },
    .{ .name = "knot3_getLatestCheckpointSequenceNumber", .write = false, .handler = handleGetLatestCheckpointSequence },
    .{ .name = "knot3_getTransactionBlock", .write = false, .handler = handleGetTransactionBlock },
    .{ .name = "knot3_executeTransactionBlock", .write = false, .handler = handleExecuteTransaction },
    .{ .name = "knot3_getEvents", .write = false, .handler = handleQueryEvents },
    .{ .name = "knot3_queryEvents", .write = false, .handler = handleQueryEvents },
    .{ .name = "knot3_getOwnedObjects", .write = false, .handler = handleGetOwnedObjects },
    .{ .name = "knot3_dryRunTransactionBlock", .write = false, .handler = handleDryRunTransaction },
    .{ .name = "knot3_syncEpochState", .write = false, .handler = handleSyncEpochState },
    .{ .name = "knot3_getEpochs", .write = false, .handler = handleGetEpochs },
    .{ .name = "knot3_getEpochInfo", .write = false, .handler = handleGetEpochInfo },
    .{ .name = "knot3_submitStakeOperation", .write = true, .handler = handleSubmitStakeOperation },
    .{ .name = "knot3_submitGovernanceProposal", .write = true, .handler = handleSubmitGovernanceProposal },
    .{ .name = "knot3_getCheckpointProof", .write = false, .handler = handleGetCheckpointProof },
    .{ .name = "knot3_creditGas", .write = true, .handler = handleCreditGas },
    .{ .name = "knot3_getGasBalance", .write = false, .handler = handleGetGasBalance },
};

fn findBuiltin(name: []const u8) ?BuiltinMethod {
    for (builtin_methods) |method| {
        if (std.mem.eql(u8, method.name, name)) return method;
    }
    return null;
}

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

    /// JSON-RPC body for one request. Client errors come back as a JSON-RPC
    /// error object; the caller owns the returned bytes.
    pub fn handleHTTPRequest(self: *@This(), body: []const u8) ![]u8 {
        return respond(self.context, body);
    }

    /// Single external entry for both HTTP transports.
    pub fn dispatch(allocator: std.mem.Allocator, node: ?*Node, body: []const u8) ![]u8 {
        var ctx = RPCContext{
            .allocator = allocator,
            .checkpoint_sequence = if (node) |n| n.getNodeInfo().checkpoint_sequence else 0,
            .user_data = if (node) |n| @ptrCast(n) else null,
        };
        return respond(&ctx, body);
    }

    fn respond(ctx: *RPCContext, body: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return ctx.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid request\"},\"id\":null}");
        };
        defer parsed.deinit();
        const value = parsed.value;
        const object = switch (value) {
            .object => |o| o,
            else => return ctx.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid request\"},\"id\":null}"),
        };

        const id_json = try JsonRpc.formatJsonRpcId(ctx.allocator, object.get("id"));
        defer ctx.allocator.free(id_json);
        const method = object.get("method") orelse {
            return formatRpcError(ctx.allocator, @backingInt(ErrorCode.invalid_request), "Missing method", id_json);
        };
        const method_str = switch (method) {
            .string => |s| s,
            else => return formatRpcError(ctx.allocator, @backingInt(ErrorCode.invalid_request), "Missing method", id_json),
        };
        const params = object.get("params");

        const response = routeRequest(ctx, method_str, params) catch |err| {
            return formatRpcError(ctx.allocator, @backingInt(ErrorCode.internal_error), @errorName(err), id_json);
        };
        defer response.deinit(ctx.allocator);

        if (response.err) |e| {
            return formatRpcError(ctx.allocator, @backingInt(e.code), e.message, id_json);
        }

        if (response.result) |r| if (r == .success) {
            return ctx.allocator.print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}",
                .{ r.success, id_json },
            );
        };

        var out: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer out.deinit();
        try std.json.Stringify.value(response, .{}, &out.writer);
        const raw = try out.toOwnedSlice();
        return patchJsonRpcId(ctx.allocator, raw, id_json);
    }

    fn formatRpcError(allocator: std.mem.Allocator, code: i32, message: []const u8, id_json: []const u8) ![]u8 {
        const message_json = try JsonRpc.formatJsonString(allocator, message);
        defer allocator.free(message_json);
        return allocator.print(
            "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{d},\"message\":{s}}},\"id\":{s}}}",
            .{ code, message_json, id_json },
        );
    }

    fn patchJsonRpcId(allocator: std.mem.Allocator, raw: []u8, id_json: []const u8) ![]u8 {
        const needle = "\"id\":null";
        const at = std.mem.indexOf(u8, raw, needle) orelse return raw;
        errdefer allocator.free(raw);
        const patched = try std.mem.concat(allocator, u8, &.{
            raw[0..at],
            "\"id\":",
            id_json,
            raw[at + needle.len ..],
        });
        allocator.free(raw);
        return patched;
    }

    /// True when the JSON-RPC body must be treated as an admin write.
    /// Parse failures and missing methods fail closed.
    pub fn bodyRequiresAdmin(allocator: std.mem.Allocator, body: []const u8) bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .ignore_unknown_fields = true }) catch return true;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return true,
        };
        const method_val = object.get("method") orelse return true;
        if (method_val != .string) return true;
        const method = findBuiltin(method_val.string) orelse return false;
        return method.write;
    }

    /// Route request to the builtin method table.
    fn routeRequest(ctx: *RPCContext, method: []const u8, params: ?std.json.Value) !RPCResponse {
        const spec = findBuiltin(method) orelse {
            return RPCResponse.makeError(null, .method_not_found, "Method not found");
        };
        return spec.handler(ctx, params);
    }

    /// Handle raw JSON request string (legacy compatibility)
    pub fn handleJSON(self: *@This(), json: []const u8) ![]u8 {
        return self.handleHTTPRequest(json);
    }

    /// Handle a builtin or registered method. The success body is owned by the
    /// caller and must be released with `RPCResponse.deinit`.
    pub fn handle(self: *@This(), request: RPCRequest) !RPCResponse {
        const handler: *const HandlerFn = if (findBuiltin(request.method)) |method|
            method.handler
        else
            self.handlers.get(request.method) orelse return RPCResponse.makeError(request.id, .method_not_found, "Method not found");

        var parsed: ?std.json.Parsed(std.json.Value) = null;
        defer if (parsed) |*item| item.deinit();
        if (request.params) |p| if (p.data) |raw| if (raw.len != 0) {
            parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{ .ignore_unknown_fields = true }) catch {
                return RPCResponse.makeError(request.id, .invalid_params, "invalid params");
            };
        };
        const params_value: ?std.json.Value = if (parsed) |*item| item.value else null;
        var resp = try handler(self.context, params_value);
        resp.id = request.id;
        return resp;
    }

    /// Handle batch requests. Caller frees the slice and deinits each response.
    pub fn handleBatch(self: *@This(), requests: []const RPCRequest) ![]RPCResponse {
        var responses = try std.ArrayList(RPCResponse).initCapacity(self.allocator, requests.len);
        errdefer {
            for (responses.items) |resp| resp.deinit(self.allocator);
            responses.deinit(self.allocator);
        }

        for (requests) |req| {
            const resp = self.handle(req) catch |err| {
                responses.append(self.allocator, RPCResponse.makeError(req.id, .internal_error, @errorName(err))) catch |append_err| return append_err;
                continue;
            };
            responses.append(self.allocator, resp) catch |err| {
                resp.deinit(self.allocator);
                return err;
            };
        }

        return responses.toOwnedSlice(self.allocator);
    }
};

// Standard RPC method handlers - use context.user_data via interfaces

fn nodeFrom(ctx: *RPCContext) ?*Node {
    const ptr = ctx.user_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn jsonObject(params: ?std.json.Value) ?std.json.ObjectMap {
    const root = params orelse return null;
    return switch (root) {
        .object => |o| o,
        else => null,
    };
}

fn parseLimit(params: ?std.json.Value) usize {
    const o = jsonObject(params) orelse return 50;
    const field = o.get("limit") orelse o.get("first") orelse return 50;
    return switch (field) {
        .integer => |n| blk: {
            if (n <= 0) break :blk 50;
            const wide: u64 = @intCast(n);
            if (wide > 100) break :blk 100;
            break :blk @intCast(wide);
        },
        else => 50,
    };
}

fn parseCursor(params: ?std.json.Value) ?u64 {
    const o = jsonObject(params) orelse return null;
    const field = o.get("cursor") orelse return null;
    return switch (field) {
        .integer => |n| if (n < 0) null else @intCast(n),
        else => null,
    };
}

fn parseEventQuery(params: ?std.json.Value) !Indexer.EventQuery {
    var query = Indexer.EventQuery{};
    const root = params orelse return query;
    switch (root) {
        .string => |s| {
            if (s.len != 0) query.event_type = s;
            return query;
        },
        .object => |o| {
            if (o.get("query")) |field| switch (field) {
                .string => |s| {
                    if (s.len != 0) query.event_type = s;
                },
                else => return error.InvalidParams,
            };
            if (o.get("eventType")) |field| switch (field) {
                .string => |s| {
                    if (s.len != 0) query.event_type = s;
                },
                else => return error.InvalidParams,
            };
            if (o.get("digest")) |field| switch (field) {
                .string => |s| query.transaction_digest = M4RpcParams.parseHex32Str(s) catch return error.InvalidParams,
                else => return error.InvalidParams,
            };
            return query;
        },
        else => return error.InvalidParams,
    }
}

fn parseOwnerParam(params: ?std.json.Value) !?[32]u8 {
    const root = params orelse return null;
    switch (root) {
        .string => |s| return M4RpcParams.parseHex32Str(s) catch error.InvalidParams,
        .object => |o| {
            const field = o.get("owner") orelse return null;
            switch (field) {
                .string => |s| return M4RpcParams.parseHex32Str(s) catch error.InvalidParams,
                else => return error.InvalidParams,
            }
        },
        else => return error.InvalidParams,
    }
}

fn objectField(params: ?std.json.Value, name: []const u8) ?[]const u8 {
    const o = jsonObject(params) orelse return null;
    const field = o.get(name) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn parseDigestParam(params: ?std.json.Value) !?[32]u8 {
    const root = params orelse return null;
    const hex = switch (root) {
        .string => |s| s,
        .object => |o| blk: {
            const field = o.get("digest") orelse return error.InvalidParams;
            break :blk switch (field) {
                .string => |s| s,
                else => return error.InvalidParams,
            };
        },
        else => return error.InvalidParams,
    };
    return M4RpcParams.parseHex32Str(hex) catch error.InvalidParams;
}

fn ownedJsonSuccess(ctx: *RPCContext, literal: []const u8) !RPCResponse {
    const body = try ctx.allocator.dupe(u8, literal);
    return RPCResponse.success(null, body);
}

fn parseIdParam(params: ?std.json.Value) !?[32]u8 {
    const root = params orelse return null;
    const hex = switch (root) {
        .string => |s| s,
        .object => |o| blk: {
            const field = o.get("id") orelse return null;
            break :blk switch (field) {
                .string => |s| s,
                else => return error.InvalidParams,
            };
        },
        else => return error.InvalidParams,
    };
    return M4RpcParams.parseHex32Str(hex) catch error.InvalidParams;
}

fn handleGetObject(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node = nodeFrom(ctx) orelse {
        return RPCResponse.makeError(null, .knot3_object_not_found, "Object not found");
    };
    const id_bytes = parseIdParam(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getObject params");
    } orelse {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getObject params");
    };
    const id = core.ObjectID.fromBytes(&id_bytes) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getObject params");
    };
    const object = node.getObject(id) catch {
        return RPCResponse.makeError(null, .internal_error, "Object store unavailable");
    } orelse {
        return RPCResponse.makeError(null, .knot3_object_not_found, "Object not found");
    };
    const hash = std.fmt.bytesToHex(id.bytes, .lower);
    const body = try ctx.allocator.print(
        "{{\"object_id\":\"{s}\",\"version\":{d},\"type_tag\":{d}}}",
        .{ hash[0..], object.version.seq, object.type_tag },
    );
    return RPCResponse.success(null, body);
}

fn parseCheckpointId(params: ?std.json.Value) !?u64 {
    const root = params orelse return null;
    const raw = switch (root) {
        .object => |o| blk: {
            const field = o.get("id") orelse return null;
            break :blk switch (field) {
                .integer => |n| n,
                else => return error.InvalidParams,
            };
        },
        else => return error.InvalidParams,
    };
    if (raw < 0) return error.InvalidParams;
    return @intCast(raw);
}

fn unixSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

fn checkpointJson(ctx: *RPCContext, sequence: u64, digest: ?[32]u8) !RPCResponse {
    const ts = unixSeconds();
    if (digest) |d| {
        const hex = std.fmt.bytesToHex(d, .lower);
        const body = try ctx.allocator.print(
            "{{\"sequence\":{d},\"digest\":\"{s}\",\"timestamp\":{d}}}",
            .{ sequence, hex[0..], ts },
        );
        return RPCResponse.success(null, body);
    }
    const body = try ctx.allocator.print(
        "{{\"sequence\":{d},\"digest\":null,\"timestamp\":{d}}}",
        .{ sequence, ts },
    );
    return RPCResponse.success(null, body);
}

fn handleGetCheckpoint(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const requested = parseCheckpointId(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getCheckpoint params");
    };
    const node = nodeFrom(ctx) orelse {
        return checkpointJson(ctx, requested orelse ctx.checkpoint_sequence, null);
    };
    const sequence = requested orelse node.getNodeInfo().checkpoint_sequence;
    return checkpointJson(ctx, sequence, node.checkpoint_store.storedDigest(sequence));
}

fn handleGetCoins(ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    return ownedJsonSuccess(ctx, "{\"data\":[]}");
}

fn handleGetLatestCheckpointSequence(ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    const sequence = if (nodeFrom(ctx)) |node| node.getNodeInfo().checkpoint_sequence else 0;
    const body = try ctx.allocator.print("{d}", .{sequence});
    return RPCResponse.success(null, body);
}

fn handleGetTransactionBlock(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node = nodeFrom(ctx) orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const digest = parseDigestParam(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getTransactionBlock params");
    } orelse {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getTransactionBlock params");
    };
    const receipt = node.getTransactionReceipt(digest) orelse {
        return RPCResponse.makeError(null, .knot3_object_not_found, "Transaction not found");
    };
    const hash = std.fmt.bytesToHex(digest, .lower);
    const sender = std.fmt.bytesToHex(receipt.sender, .lower);
    const body = try ctx.allocator.print(
        "{{\"digest\":\"{s}\",\"status\":\"{s}\",\"gasUsed\":{d},\"sender\":\"{s}\"}}",
        .{ hash[0..], @tagName(receipt.status), receipt.gas_used, sender[0..] },
    );
    return RPCResponse.success(null, body);
}

fn handleExecuteTransaction(_ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    _ = _ctx;
    return RPCResponse.makeError(null, .internal_error, "Node not initialized");
}

fn handleQueryEvents(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const query = parseEventQuery(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_queryEvents params");
    };
    const indexer = if (nodeFrom(ctx)) |node| node.indexer else null;
    const idx = indexer orelse return ownedJsonSuccess(ctx, "{\"data\":[],\"hasNextPage\":false}");
    var page = try idx.queryEvents(ctx.allocator, query, parseCursor(params), parseLimit(params));
    defer page.deinit(ctx.allocator);
    const body = try Indexer.formatEventsJson(ctx.allocator, page);
    return RPCResponse.success(null, body);
}

fn handleGetOwnedObjects(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const owner = parseOwnerParam(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getOwnedObjects params");
    };
    const indexer = if (nodeFrom(ctx)) |node| node.indexer else null;
    const idx = indexer orelse return ownedJsonSuccess(ctx, "{\"data\":[],\"hasNextPage\":false}");
    const owner_filter = owner orelse {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getOwnedObjects params");
    };
    var query = Indexer.ObjectQuery{ .owner = owner_filter };
    if (objectField(params, "query")) |type_name| {
        if (type_name.len != 0) query.object_type = type_name;
    }
    var page = try idx.queryObjects(ctx.allocator, query, null, parseLimit(params));
    defer page.deinit(ctx.allocator);
    const body = try Indexer.formatObjectIdsJson(ctx.allocator, page);
    return RPCResponse.success(null, body);
}

fn handleDryRunTransaction(_: *RPCContext, _: ?std.json.Value) !RPCResponse {
    return RPCResponse.makeError(null, .internal_error, "dry run is not available");
}

fn handleSyncEpochState(ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    const epoch = if (nodeFrom(ctx)) |node| node.getEpochInfo().epoch_number else 0;
    const body = try ctx.allocator.print("{{\"epoch\":{d},\"protocolVersion\":1}}", .{epoch});
    return RPCResponse.success(null, body);
}

fn handleGetEpochs(ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    return ownedJsonSuccess(ctx, "{\"data\":[]}");
}

fn handleGetEpochInfo(ctx: *RPCContext, _: ?std.json.Value) !RPCResponse {
    const EpochInfo = @import("../../metric/EpochConsensusBridge.zig").ConsensusEpochInfo;
    const info: EpochInfo = if (nodeFrom(ctx)) |node| node.getEpochInfo() else .{
        .epoch_number = 0,
        .total_stake = 0,
        .validator_count = 0,
        .quorum_threshold = 0,
    };
    const body = try ctx.allocator.print(
        "{{\"epoch\":{d},\"total_stake\":{d},\"validator_count\":{d},\"quorum_threshold\":{d},\"validators\":{{\"active_validators\":{{\"data\":[]}}}},\"initial_epoch_version\":0}}",
        .{ info.epoch_number, info.total_stake, info.validator_count, info.quorum_threshold },
    );
    return RPCResponse.success(null, body);
}

fn handleSubmitStakeOperation(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node = nodeFrom(ctx) orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const input = M4RpcParams.parseStakeOperationInput(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_submitStakeOperation params");
    };
    const operation_id = node.submitStakeOperation(input) catch |err| {
        return RPCResponse.makeError(null, .internal_error, @errorName(err));
    };
    const body = try ctx.allocator.print("{{\"status\":\"accepted\",\"operationId\":{d}}}", .{operation_id});
    return RPCResponse.success(null, body);
}

fn handleSubmitGovernanceProposal(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node = nodeFrom(ctx) orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const input = M4RpcParams.parseGovernanceProposalInput(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_submitGovernanceProposal params");
    };
    const proposal_id = node.submitGovernanceProposal(input) catch |err| {
        return RPCResponse.makeError(null, .internal_error, @errorName(err));
    };
    const body = try ctx.allocator.print("{{\"status\":\"accepted\",\"proposalId\":{d}}}", .{proposal_id});
    return RPCResponse.success(null, body);
}

fn handleCreditGas(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node = nodeFrom(ctx) orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const input = M4RpcParams.parseCreditGasParams(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_creditGas params");
    };
    const balance = node.creditGas(input.address, input.amount) catch |err| {
        return RPCResponse.makeError(null, .internal_error, @errorName(err));
    };
    const body = try ctx.allocator.print("{{\"balance\":{d}}}", .{balance});
    return RPCResponse.success(null, body);
}

fn handleGetHardenedCheckpoint(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node = nodeFrom(ctx) orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const sequence = M4RpcParams.parseOptionalHardenedSequence(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getHardenedCheckpoint params");
    };
    const body = (try node.formatHardenedCheckpointFor(ctx.allocator, sequence)) orelse {
        return RPCResponse.makeError(null, .knot3_hardened_checkpoint_unavailable, "hardened checkpoint unavailable");
    };
    return RPCResponse.success(null, body);
}

fn handleGetGasBalance(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node = nodeFrom(ctx) orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
    const input = M4RpcParams.parseGetGasBalanceParams(params) catch {
        return RPCResponse.makeError(null, .invalid_params, "invalid knot3_getGasBalance params");
    };
    const balance = node.getGasBalance(input.address);
    const body = try ctx.allocator.print("{{\"balance\":{d}}}", .{balance});
    return RPCResponse.success(null, body);
}

fn handleGetCheckpointProof(ctx: *RPCContext, params: ?std.json.Value) !RPCResponse {
    const node = nodeFrom(ctx) orelse {
        return RPCResponse.makeError(null, .internal_error, "Node not initialized");
    };
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
    const body = try ctx.allocator.print(
        "{{\"sequence\":{d},\"stateRoot\":\"{x}\",\"proof\":\"{s}\",\"signatures\":\"{s}\",\"bls_signature\":\"{s}\",\"bls_signer_bitmap\":\"{s}\"}}",
        .{ proof.sequence, proof.state_root, proof_hex, sig_hex, bls_sig_hex, bls_bitmap_hex },
    );
    return RPCResponse.success(null, body);
}

fn demoOwnedHandler(ctx: *RPCContext, params: ?std.json.Value) anyerror!RPCResponse {
    _ = params;
    return ownedJsonSuccess(ctx, "{\"ok\":true}");
}

test "RPC handle returns the registered body" {
    const allocator = std.testing.allocator;
    var server = try RPCServer.init(allocator);
    defer server.deinit();
    try server.register("demo", demoOwnedHandler);

    var demo_method: [4]u8 = "demo".*;
    const one = try server.handle(.{
        .method = &demo_method,
        .params = null,
        .id = .{ .number = 3 },
    });
    defer one.deinit(allocator);
    switch (one.id.?) {
        .number => |n| try std.testing.expectEqual(@as(i64, 3), n),
        .string => return error.TestUnexpectedResult,
    }
    try std.testing.expect(one.result != null and one.result.? == .success);
    try std.testing.expectEqualStrings("{\"ok\":true}", one.result.?.success);

    var missing_method: [4]u8 = "nope".*;
    const missing = try server.handle(.{
        .method = &missing_method,
        .params = null,
        .id = null,
    });
    defer missing.deinit(allocator);
    try std.testing.expect(missing.err != null);

    const batch = try server.handleBatch(&.{
        .{ .method = &demo_method, .params = null, .id = .{ .number = 1 } },
        .{ .method = &missing_method, .params = null, .id = .{ .number = 2 } },
    });
    defer {
        for (batch) |item| item.deinit(allocator);
        allocator.free(batch);
    }
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expectEqualStrings("{\"ok\":true}", batch[0].result.?.success);
    try std.testing.expect(batch[1].err != null);
}

test "RPC error message is json-escaped" {
    const allocator = std.testing.allocator;
    const json = try RPCServer.formatRpcError(allocator, -32603, "bad \"req\"\n", "9");
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"bad \\\"req\\\"\\n\"},\"id\":9}", json);
}

test "dispatch is the shared JSON-RPC path" {
    const allocator = std.testing.allocator;
    const missing = try RPCServer.dispatch(allocator, null, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"no_such\"}");
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "Method not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"id\":1") != null);

    const info = try RPCServer.dispatch(allocator, null, "{\"jsonrpc\":\"2.0\",\"id\":\"q\\\"\",\"method\":\"knot3_getEpochInfo\"}");
    defer allocator.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "initial_epoch_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "\"id\":\"q\\\"\"") != null);

    const bad = try RPCServer.dispatch(allocator, null, "not-json");
    defer allocator.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "Invalid request") != null);

    try std.testing.expect(RPCServer.bodyRequiresAdmin(allocator, "{\"method\":\"knot3_creditGas\"}"));
    try std.testing.expect(RPCServer.bodyRequiresAdmin(allocator, "{\"method\":\"knot3_submitStakeOperation\"}"));
    try std.testing.expect(!RPCServer.bodyRequiresAdmin(allocator, "{\"method\":\"knot3_getGasBalance\"}"));
    try std.testing.expect(!RPCServer.bodyRequiresAdmin(allocator, "{\"method\":\"no_such\"}"));
    try std.testing.expect(RPCServer.bodyRequiresAdmin(allocator, "not-json"));

    const dry = try RPCServer.dispatch(allocator, null, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"knot3_dryRunTransactionBlock\"}");
    defer allocator.free(dry);
    try std.testing.expect(std.mem.indexOf(u8, dry, "dry run is not available") != null);

    const missing_object = try RPCServer.dispatch(allocator, null, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"knot3_getObject\"}");
    defer allocator.free(missing_object);
    try std.testing.expect(std.mem.indexOf(u8, missing_object, "Object not found") != null);

    const checkpoint = try RPCServer.dispatch(allocator, null, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"knot3_getCheckpoint\"}");
    defer allocator.free(checkpoint);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"digest\":null") != null);
}

test "dispatch reads checkpoint sequence and a stored receipt" {
    const Config = @import("../../app/Config.zig").Config;
    const NodeDependencies = @import("../../app/Node.zig").NodeDependencies;
    const allocator = std.testing.allocator;
    const config = try allocator.create(Config);
    defer allocator.destroy(config);
    config.* = Config.default();
    config.authority.signing_key = @as([32]u8, @splat(0x22));
    config.authority.stake = 1;
    const node = try Node.init(allocator, config, NodeDependencies{});
    defer node.deinit();

    const seq = try RPCServer.dispatch(allocator, node, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"knot3_getLatestCheckpointSequenceNumber\"}");
    defer allocator.free(seq);
    try std.testing.expect(std.mem.indexOf(u8, seq, "\"result\":0") != null);

    const epoch = try RPCServer.dispatch(allocator, node, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"knot3_getEpochInfo\"}");
    defer allocator.free(epoch);
    try std.testing.expect(std.mem.indexOf(u8, epoch, "\"validator_count\":0") != null);

    const digest: [32]u8 = @splat(0xAB);
    const sender: [32]u8 = @splat(0xCD);
    try node.txn_history.put(allocator, digest, .{
        .digest = digest,
        .status = .committed,
        .gas_used = 3,
        .sender = sender,
    });
    const hash = std.fmt.bytesToHex(digest, .lower);
    const request = try allocator.print("{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"knot3_getTransactionBlock\",\"params\":{{\"digest\":\"{s}\"}}}}", .{hash[0..]});
    defer allocator.free(request);
    const tx = try RPCServer.dispatch(allocator, node, request);
    defer allocator.free(tx);
    const sender_hex = std.fmt.bytesToHex(sender, .lower);
    try std.testing.expect(std.mem.indexOf(u8, tx, "\"status\":\"committed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tx, &sender_hex) != null);

    const missing = try RPCServer.dispatch(allocator, null, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"knot3_getTransactionBlock\"}");
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "Node not initialized") != null);

    const empty_cp = try RPCServer.dispatch(allocator, node, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"knot3_getCheckpoint\"}");
    defer allocator.free(empty_cp);
    try std.testing.expect(std.mem.indexOf(u8, empty_cp, "\"digest\":null") != null);

    node.hardened_digest_archive.clearRetainingCapacity();
    node.checkpoint_store = @TypeOf(node.checkpoint_store).init();
    node.checkpoint_store.bindDigestArchive(&node.hardened_digest_archive);
    const tip: [32]u8 = @splat(0x11);
    node.checkpoint_store.hardenThrough(4, tip);
    const cp = try RPCServer.dispatch(allocator, node, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"knot3_getCheckpoint\",\"params\":{\"id\":4}}");
    defer allocator.free(cp);
    const tip_hex = std.fmt.bytesToHex(tip, .lower);
    try std.testing.expect(std.mem.indexOf(u8, cp, "\"sequence\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, cp, tip_hex[0..]) != null);

    const indexer = node.indexer orelse return error.TestUnexpectedResult;
    try indexer.indexEvent(.{
        .transaction_digest = digest,
        .event_type = "Coin\"Transfer",
        .contents = "a\nb",
        .timestamp = 9,
        .event_index = 2,
    });
    const events = try RPCServer.dispatch(allocator, node, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"knot3_queryEvents\",\"params\":{\"eventType\":\"Coin\\\"Transfer\"}}");
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "Coin\\\"Transfer") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "a\\nb") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"hasNextPage\":false") != null);

    var coin_type: [4]u8 = "Coin".*;
    var coin_data: [0]u8 = .{};
    try indexer.indexObject(.{
        .id = try core.ObjectID.fromBytes(&sender),
        .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
        .type = &coin_type,
        .owner = sender,
        .data = &coin_data,
        .timestamp = 1,
    });
    const owner_hex = std.fmt.bytesToHex(sender, .lower);
    const owned_req = try allocator.print("{{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"knot3_getOwnedObjects\",\"params\":{{\"owner\":\"{s}\"}}}}", .{owner_hex[0..]});
    defer allocator.free(owned_req);
    const owned = try RPCServer.dispatch(allocator, node, owned_req);
    defer allocator.free(owned);
    try std.testing.expect(std.mem.indexOf(u8, owned, owner_hex[0..]) != null);
}

test "handleHTTPRequest echoes the request id" {
    const allocator = std.testing.allocator;
    var server = try RPCServer.init(allocator);
    defer server.deinit();

    const missing = try server.handleHTTPRequest("{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"no_such\"}");
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"id\":\"a\\\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "Method not found") != null);

    const epochs = try server.handleHTTPRequest("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"knot3_getEpochs\"}");
    defer allocator.free(epochs);
    try std.testing.expect(std.mem.indexOf(u8, epochs, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, epochs, "\"data\":[]") != null);
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
    config.authority.signing_key = @as([32]u8, @splat(0x22));
    config.authority.stake = 1_000_000_000;

    const node = try Node.init(allocator, config, NodeDependencies{});
    defer node.deinit();

    var ctx = RPCContext{
        .allocator = allocator,
        .checkpoint_sequence = 7,
        .user_data = @ptrCast(node),
    };

    const z64 = "0000000000000000000000000000000000000000000000000000000000000000";
    const stake_body = try allocator.print("{{\"validator\":\"0x{s}\",\"delegator\":\"0x{s}\",\"amount\":1,\"action\":\"stake\",\"metadata\":\"t\"}}", .{ z64, z64 });
    defer allocator.free(stake_body);
    var stake_params1 = try std.json.parseFromSlice(std.json.Value, allocator, stake_body, .{ .ignore_unknown_fields = true });
    defer stake_params1.deinit();
    const stake_1 = try handleSubmitStakeOperation(&ctx, stake_params1.value);
    defer if (stake_1.result) |r| allocator.free(r.success);
    var stake_params2 = try std.json.parseFromSlice(std.json.Value, allocator, stake_body, .{ .ignore_unknown_fields = true });
    defer stake_params2.deinit();
    const stake_2 = try handleSubmitStakeOperation(&ctx, stake_params2.value);
    defer if (stake_2.result) |r| allocator.free(r.success);
    try std.testing.expect(stake_1.result != null);
    try std.testing.expect(stake_2.result != null);
    try std.testing.expect(std.mem.indexOf(u8, stake_1.result.?.success, "\"operationId\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stake_2.result.?.success, "\"operationId\":2") != null);

    const gov_body = try allocator.print("{{\"proposer\":\"0x{s}\",\"title\":\"Proposal A\",\"description\":\"Body text\",\"kind\":\"parameter_change\"}}", .{z64});
    defer allocator.free(gov_body);
    var gov_params = try std.json.parseFromSlice(std.json.Value, allocator, gov_body, .{ .ignore_unknown_fields = true });
    defer gov_params.deinit();
    const proposal = try handleSubmitGovernanceProposal(&ctx, gov_params.value);
    defer if (proposal.result) |r| allocator.free(r.success);
    try std.testing.expect(proposal.result != null);
    try std.testing.expect(std.mem.indexOf(u8, proposal.result.?.success, "\"proposalId\":1") != null);

    const proof_body = try allocator.print("{{\"sequence\":7,\"objectId\":\"0x{s}\"}}", .{z64});
    defer allocator.free(proof_body);
    const proof_params = try std.json.parseFromSlice(std.json.Value, allocator, proof_body, .{ .ignore_unknown_fields = true });
    defer proof_params.deinit();
    const proof = try handleGetCheckpointProof(&ctx, proof_params.value);
    defer if (proof.result) |r| allocator.free(r.success);
    try std.testing.expect(proof.result != null);
    try std.testing.expect(std.mem.indexOf(u8, proof.result.?.success, "\"sequence\":7") != null);

    const gas_addr = "1111111111111111111111111111111111111111111111111111111111111111";
    const credit_body = try allocator.print("{{\"address\":\"0x{s}\",\"amount\":42}}", .{gas_addr});
    defer allocator.free(credit_body);
    var credit_params = try std.json.parseFromSlice(std.json.Value, allocator, credit_body, .{ .ignore_unknown_fields = true });
    defer credit_params.deinit();
    const credited = try handleCreditGas(&ctx, credit_params.value);
    defer if (credited.result) |r| allocator.free(r.success);
    try std.testing.expect(credited.result != null);
    try std.testing.expect(std.mem.indexOf(u8, credited.result.?.success, "\"balance\":42") != null);

    const bal_body = try allocator.print("{{\"address\":\"0x{s}\"}}", .{gas_addr});
    defer allocator.free(bal_body);
    var bal_params = try std.json.parseFromSlice(std.json.Value, allocator, bal_body, .{ .ignore_unknown_fields = true });
    defer bal_params.deinit();
    const bal = try handleGetGasBalance(&ctx, bal_params.value);
    defer if (bal.result) |r| allocator.free(r.success);
    try std.testing.expect(bal.result != null);
    try std.testing.expect(std.mem.indexOf(u8, bal.result.?.success, "\"balance\":42") != null);

    node.checkpoint_store = @TypeOf(node.checkpoint_store).init();
    const missing = try handleGetHardenedCheckpoint(&ctx, null);
    try std.testing.expect(missing.err != null);
    try std.testing.expectEqual(ErrorCode.knot3_hardened_checkpoint_unavailable, missing.err.?.code);
    try std.testing.expectEqualStrings("hardened checkpoint unavailable", missing.err.?.message);

    const tip_digest: [32]u8 = @splat(0x44);
    node.checkpoint_store.hardenThrough(9, tip_digest);
    const hardened = try handleGetHardenedCheckpoint(&ctx, null);
    defer if (hardened.result) |r| allocator.free(r.success);
    const tip_hex = std.fmt.bytesToHex(tip_digest, .lower);
    try std.testing.expect(hardened.err == null);
    try std.testing.expect(std.mem.indexOf(u8, hardened.result.?.success, "\"sequence\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, hardened.result.?.success, "\"history\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hardened.result.?.success, tip_hex[0..]) != null);

    node.hardened_digest_archive.clearRetainingCapacity();
    node.checkpoint_store = @TypeOf(node.checkpoint_store).init();
    node.checkpoint_store.bindDigestArchive(&node.hardened_digest_archive);
    var archived_n: u64 = 1;
    while (archived_n <= 9) : (archived_n += 1) {
        var archived_digest: [32]u8 = @splat(0);
        archived_digest[0] = @intCast(archived_n);
        node.checkpoint_store.hardenThrough(archived_n, archived_digest);
    }
    node.retainEvictedHardenedDigests();
    var old_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"sequence\":1}", .{ .ignore_unknown_fields = true });
    defer old_params.deinit();
    const archived = try handleGetHardenedCheckpoint(&ctx, old_params.value);
    defer if (archived.result) |r| allocator.free(r.success);
    var want: [32]u8 = @splat(0);
    want[0] = 1;
    const want_hex = std.fmt.bytesToHex(want, .lower);
    try std.testing.expect(archived.err == null);
    try std.testing.expect(std.mem.indexOf(u8, archived.result.?.success, "\"sequence\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, archived.result.?.success, want_hex[0..]) != null);
    try std.testing.expect(std.mem.indexOf(u8, archived.result.?.success, "\"history\"") == null);

    var bad_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"sequence\":\"nope\"}", .{ .ignore_unknown_fields = true });
    defer bad_params.deinit();
    const bad = try handleGetHardenedCheckpoint(&ctx, bad_params.value);
    try std.testing.expect(bad.err != null);
    try std.testing.expectEqual(ErrorCode.invalid_params, bad.err.?.code);
}
