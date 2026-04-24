//! ClientSDK - Multi-language bindings generator for zknot3
//!
//! Generates SDK bindings for multiple languages based on the Knot3 RPC API.
//! Supports TypeScript, Python, Go, and Rust.

const std = @import("std");
const core = @import("../core.zig");

const CompatList = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .list = .empty,
        };
    }

    fn appendSlice(self: *@This(), bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    fn append(self: *@This(), byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    fn toOwnedSlice(self: *@This()) ![]u8 {
        return self.list.toOwnedSlice(self.allocator);
    }
};

/// SDK generation target language
pub const TargetLanguage = enum {
    typescript,
    python,
    go,
    rust,
    zig,
};

/// SDK configuration
pub const SDKConfig = struct {
    language: TargetLanguage,
    output_dir: []const u8,
    package_name: []const u8,
    rpc_url: []const u8 = "http://localhost:9000",
};

/// JSON encoding for each RPC parameter (M4 object bodies must match server).
pub const RpcParamJsonKind = enum {
    string,
    integer,
    /// Omitted from JSON when null / undefined / None.
    optional_integer,
};

/// Knot3 RPC method definitions
pub const RPCMethod = struct {
    name: []const u8,
    params: []const []const u8,
    return_type: []const u8,
    /// When true, JSON-RPC `params` is sent as a single object (M4 v2 strict).
    object_params: bool = false,
    /// When `object_params`, must match `params.len`.
    param_json: ?[]const RpcParamJsonKind = null,
};

/// Supported RPC methods
pub const KNOT3_RPC_METHODS = &[_]RPCMethod{
    .{ .name = "knot3_getObject", .params = &.{"id"}, .return_type = "Knot3Object" },
    .{ .name = "knot3_getCheckpoint", .params = &.{"id"}, .return_type = "Checkpoint" },
    .{ .name = "knot3_getCoins", .params = &.{ "owner", "coinType" }, .return_type = "Coin[]" },
    .{ .name = "knot3_getTransactionBlock", .params = &.{"digest"}, .return_type = "TransactionBlock" },
    .{ .name = "knot3_getLatestCheckpointSequenceNumber", .params = &.{}, .return_type = "number" },
    .{ .name = "knot3_queryEvents", .params = &.{"query"}, .return_type = "Event[]" },
    .{ .name = "knot3_dryRunTransactionBlock", .params = &.{"txBytes"}, .return_type = "DryRunResult" },
    .{ .name = "knot3_executeTransactionBlock", .params = &.{ "txBytes", "signature" }, .return_type = "ExecuteResult" },
    .{ .name = "knot3_getOwnedObjects", .params = &.{ "owner", "query" }, .return_type = "Object[]" },
    .{ .name = "knot3_syncEpochState", .params = &.{}, .return_type = "EpochInfo" },
    .{ .name = "knot3_getEpochs", .params = &.{ "first", "cursor" }, .return_type = "Epoch[]" },
    // M4 executable hooks (typed interfaces)
    .{ .name = "knot3_submitStakeOperation", .params = &.{ "validator", "delegator", "amount", "action", "metadata" }, .return_type = "StakeOperationReceipt", .object_params = true, .param_json = &.{ .string, .string, .integer, .string, .string } },
    .{ .name = "knot3_submitGovernanceProposal", .params = &.{ "proposer", "title", "description", "kind", "activation_epoch" }, .return_type = "GovernanceProposalReceipt", .object_params = true, .param_json = &.{ .string, .string, .string, .string, .optional_integer } },
    .{ .name = "knot3_getCheckpointProof", .params = &.{ "sequence", "objectId" }, .return_type = "CheckpointProof", .object_params = true, .param_json = &.{ .integer, .string } },
};

comptime {
    for (KNOT3_RPC_METHODS) |m| {
        if (m.object_params) {
            std.debug.assert(m.param_json != null and m.param_json.?.len == m.params.len);
        }
    }
}

/// Code generator for SDK bindings
pub const ClientSDK = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: SDKConfig,

    pub fn init(allocator: std.mem.Allocator, config: SDKConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Generate SDK for configured language
    pub fn generate(self: *Self) !void {
        switch (self.config.language) {
            .typescript => _ = try generateTypeScript(self),
            .python => _ = try generatePython(self),
            .go => _ = try generateGo(self),
            .rust => _ = try generateRust(self),
            .zig => _ = try generateZig(self),
        }
    }

    /// Get SDK code as string
    pub fn generateCode(self: *Self) ![]const u8 {
        switch (self.config.language) {
            .typescript => return try generateTypeScript(self),
            .python => return try generatePython(self),
            .go => return try generateGo(self),
            .rust => return try generateRust(self),
            .zig => return try generateZig(self),
        }
    }
};

/// Generate TypeScript SDK
fn generateTypeScript(sdk: *ClientSDK) ![]const u8 {
    var buf = CompatList.init(sdk.allocator);

    // Header
    try buf.appendSlice("// Auto-generated zknot3 SDK for TypeScript\n");
    try buf.appendSlice("// Do not edit manually\n\n");

    // RPC client class
    try buf.appendSlice("export class Knot3Client {\n");
    try buf.appendSlice("    private rpcUrl: string;\n");
    try buf.appendSlice("    \n");
    try buf.appendSlice("    constructor(rpcUrl: string = 'http://localhost:9000') {\n");
    try buf.appendSlice("        this.rpcUrl = rpcUrl;\n");
    try buf.appendSlice("    }\n");
    try buf.appendSlice("    \n");
    try buf.appendSlice("    private async rpcCall<T>(method: string, params: unknown): Promise<T> {\n");
    try buf.appendSlice("        const response = await fetch(this.rpcUrl, {\n");
    try buf.appendSlice("            method: 'POST',\n");
    try buf.appendSlice("            headers: { 'Content-Type': 'application/json' },\n");
    try buf.appendSlice("            body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),\n");
    try buf.appendSlice("        });\n");
    try buf.appendSlice("        const result = await response.json();\n");
    try buf.appendSlice("        return result.result;\n");
    try buf.appendSlice("    }\n\n");

    // Generate methods
    for (KNOT3_RPC_METHODS) |method| {
        try buf.appendSlice("    async ");
        try buf.appendSlice(method.name["knot3_".len..]);
        try buf.appendSlice("(");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param);
            const kind = if (method.param_json) |p| p[i] else RpcParamJsonKind.string;
            switch (kind) {
                .string => try buf.appendSlice(": string"),
                .integer => try buf.appendSlice(": number"),
                .optional_integer => try buf.appendSlice("?: number | null"),
            }
        }
        try buf.appendSlice("): Promise<");
        try buf.appendSlice(method.return_type);
        try buf.appendSlice("> {\n");
        try buf.appendSlice("        return this.rpcCall('");
        try buf.appendSlice(method.name);
        try buf.appendSlice("', ");
        if (method.object_params) {
            const pjson = method.param_json.?;
            try buf.appendSlice("{ ");
            var need_comma = false;
            for (method.params, 0..) |param, i| {
                if (pjson[i] == .optional_integer) continue;
                if (need_comma) try buf.appendSlice(", ");
                need_comma = true;
                try buf.appendSlice(param);
                try buf.appendSlice(": ");
                try buf.appendSlice(param);
            }
            for (method.params, 0..) |param, i| {
                if (pjson[i] != .optional_integer) continue;
                if (need_comma) try buf.appendSlice(", ");
                need_comma = true;
                try buf.appendSlice("...(");
                try buf.appendSlice(param);
                try buf.appendSlice(" !== undefined && ");
                try buf.appendSlice(param);
                try buf.appendSlice(" !== null ? { ");
                try buf.appendSlice(param);
                try buf.appendSlice(": ");
                try buf.appendSlice(param);
                try buf.appendSlice(" } : {})");
            }
            try buf.appendSlice(" });\n");
        } else {
            try buf.appendSlice("[");
            for (method.params, 0..) |param, i| {
                if (i > 0) try buf.appendSlice(", ");
                try buf.appendSlice(param);
            }
            try buf.appendSlice("]);\n");
        }
        try buf.appendSlice("    }\n\n");
    }

    try buf.appendSlice("}\n\n");

    // Types
    try buf.appendSlice("// Type definitions\n");
    try buf.appendSlice("export interface Knot3Object {\n");
    try buf.appendSlice("    id: string;\n");
    try buf.appendSlice("    version: number;\n");
    try buf.appendSlice("    owner: string;\n");
    try buf.appendSlice("    type: string;\n");
    try buf.appendSlice("    data: string;\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("export interface Checkpoint {\n");
    try buf.appendSlice("    sequence: number;\n");
    try buf.appendSlice("    digest: string;\n");
    try buf.appendSlice("    timestamp: number;\n");
    try buf.appendSlice("    transactions: string[];\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("export interface Coin {\n");
    try buf.appendSlice("    coinObjectId: string;\n");
    try buf.appendSlice("    coinType: string;\n");
    try buf.appendSlice("    balance: number;\n");
    try buf.appendSlice("    previousTransaction: string;\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("export interface TransactionBlock {\n");
    try buf.appendSlice("    digest: string;\n");
    try buf.appendSlice("    sender: string;\n");
    try buf.appendSlice("    gasBudget: number;\n");
    try buf.appendSlice("    gasPrice: number;\n");
    try buf.appendSlice("    status: string;\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("export interface Event {\n");
    try buf.appendSlice("    id: string;\n");
    try buf.appendSlice("    type: string;\n");
    try buf.appendSlice("    contents: string;\n");
    try buf.appendSlice("    timestamp: number;\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("// M4 v2: `proof` / `signatures` are lowercase hex; signatures payload is k3s1||u32le(count)||(validator_id32||sig64)*\n");
    try buf.appendSlice("export interface StakeOperationReceipt {\n");
    try buf.appendSlice("    status: string;\n");
    try buf.appendSlice("    operationId: number;\n");
    try buf.appendSlice("}\n\n");
    try buf.appendSlice("export interface GovernanceProposalReceipt {\n");
    try buf.appendSlice("    status: string;\n");
    try buf.appendSlice("    proposalId: number;\n");
    try buf.appendSlice("}\n\n");
    try buf.appendSlice("export interface CheckpointProof {\n");
    try buf.appendSlice("    sequence: number;\n");
    try buf.appendSlice("    stateRoot: string;\n");
    try buf.appendSlice("    proof: string;\n");
    try buf.appendSlice("    signatures: string;\n");
    try buf.appendSlice("    blsSignature: string;\n");
    try buf.appendSlice("    blsSignerBitmap: string;\n");
    try buf.appendSlice("}\n\n");

    return buf.toOwnedSlice();
}

/// Generate Python SDK
fn generatePython(sdk: *ClientSDK) ![]const u8 {
    var buf = CompatList.init(sdk.allocator);

    // Header
    try buf.appendSlice("# Auto-generated zknot3 SDK for Python\n");
    try buf.appendSlice("# Do not edit manually\n\n");

    try buf.appendSlice("from typing import Any, List, Optional\n");
    try buf.appendSlice("from dataclasses import dataclass\n");
    try buf.appendSlice("import requests\n\n\n");

    // M4 + core result types (before client so annotations resolve)
    try buf.appendSlice("@dataclass\n");
    try buf.appendSlice("class Knot3Object:\n");
    try buf.appendSlice("    id: str\n");
    try buf.appendSlice("    version: int\n");
    try buf.appendSlice("    owner: str\n");
    try buf.appendSlice("    type: str\n");
    try buf.appendSlice("    data: str\n\n");

    try buf.appendSlice("@dataclass\n");
    try buf.appendSlice("class Checkpoint:\n");
    try buf.appendSlice("    sequence: int\n");
    try buf.appendSlice("    digest: str\n");
    try buf.appendSlice("    timestamp: int\n");
    try buf.appendSlice("    transactions: List[str]\n\n");

    try buf.appendSlice("@dataclass\n");
    try buf.appendSlice("class Coin:\n");
    try buf.appendSlice("    coin_object_id: str\n");
    try buf.appendSlice("    coin_type: str\n");
    try buf.appendSlice("    balance: int\n");
    try buf.appendSlice("    previous_transaction: str\n\n");

    try buf.appendSlice("@dataclass\n");
    try buf.appendSlice("class StakeOperationReceipt:\n");
    try buf.appendSlice("    status: str\n");
    try buf.appendSlice("    operationId: int\n\n");

    try buf.appendSlice("@dataclass\n");
    try buf.appendSlice("class GovernanceProposalReceipt:\n");
    try buf.appendSlice("    status: str\n");
    try buf.appendSlice("    proposalId: int\n\n");

    try buf.appendSlice("@dataclass\n");
    try buf.appendSlice("class CheckpointProof:\n");
    try buf.appendSlice("    sequence: int\n");
    try buf.appendSlice("    stateRoot: str\n");
    try buf.appendSlice("    proof: str\n");
    try buf.appendSlice("    signatures: str\n\n");
    try buf.appendSlice("    blsSignature: str\n");
    try buf.appendSlice("    blsSignerBitmap: str\n\n");

    // Client class
    try buf.appendSlice("class Knot3Client:\n");
    try buf.appendSlice("    def __init__(self, rpc_url: str = 'http://localhost:9000'):\n");
    try buf.appendSlice("        self.rpc_url = rpc_url\n");
    try buf.appendSlice("    \n");
    try buf.appendSlice("    def _rpc_call(self, method: str, params: Any) -> Any:\n");
    try buf.appendSlice("        response = requests.post(\n");
    try buf.appendSlice("            self.rpc_url,\n");
    try buf.appendSlice("            json={'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params},\n");
    try buf.appendSlice("            headers={'Content-Type': 'application/json'},\n");
    try buf.appendSlice("        )\n");
    try buf.appendSlice("        result = response.json()\n");
    try buf.appendSlice("        return result.get('result')\n\n");

    // Generate methods
    for (KNOT3_RPC_METHODS) |method| {
        const method_name = method.name["knot3_".len..];
        var snake_buf: [256]u8 = undefined;
        const snake_name = convertToSnakeCase(method_name, &snake_buf);
        try buf.appendSlice("    def ");
        try buf.appendSlice(snake_name);
        try buf.appendSlice("(");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param);
            const kind = if (method.param_json) |p| p[i] else RpcParamJsonKind.string;
            switch (kind) {
                .string => try buf.appendSlice(": str"),
                .integer => try buf.appendSlice(": int"),
                .optional_integer => try buf.appendSlice(": Optional[int] = None"),
            }
        }
        try buf.appendSlice(") -> ");
        try buf.appendSlice(method.return_type);
        try buf.appendSlice(":\n");
        try buf.appendSlice("        \"\"\"");
        try buf.appendSlice(method.name);
        try buf.appendSlice(" RPC call\"\"\"\n");
        if (method.object_params) {
            const pjson = method.param_json.?;
            try buf.appendSlice("        _p: dict[str, Any] = {\n");
            for (method.params, 0..) |param, i| {
                if (pjson[i] == .optional_integer) continue;
                try buf.appendSlice("            \"");
                try buf.appendSlice(param);
                try buf.appendSlice("\": ");
                try buf.appendSlice(param);
                try buf.appendSlice(",\n");
            }
            try buf.appendSlice("        }\n");
            for (method.params, 0..) |param, i| {
                if (pjson[i] != .optional_integer) continue;
                try buf.appendSlice("        if ");
                try buf.appendSlice(param);
                try buf.appendSlice(" is not None:\n            _p[\"");
                try buf.appendSlice(param);
                try buf.appendSlice("\"] = ");
                try buf.appendSlice(param);
                try buf.appendSlice("\n");
            }
            try buf.appendSlice("        return self._rpc_call('");
            try buf.appendSlice(method.name);
            try buf.appendSlice("', _p)\n\n");
        } else {
            try buf.appendSlice("        return self._rpc_call('");
            try buf.appendSlice(method.name);
            try buf.appendSlice("', [");
            for (method.params, 0..) |param, i| {
                if (i > 0) try buf.appendSlice(", ");
                try buf.appendSlice(param);
            }
            try buf.appendSlice("])\n\n");
        }
    }

    return buf.toOwnedSlice();
}

/// Generate Go SDK
fn generateGo(sdk: *ClientSDK) ![]const u8 {
    var buf = CompatList.init(sdk.allocator);

    // Header
    try buf.appendSlice("// Auto-generated zknot3 SDK for Go\n");
    try buf.appendSlice("// Do not edit manually\n\n");

    try buf.appendSlice("package zknot3\n\n");
    try buf.appendSlice("import (\n");
    try buf.appendSlice("    \"encoding/json\"\n");
    try buf.appendSlice("    \"net/http\"\n");
    try buf.appendSlice("    \"strings\"\n");
    try buf.appendSlice(")\n\n");

    // Client struct
    try buf.appendSlice("type Client struct {\n");
    try buf.appendSlice("    RPCURL string\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("func NewClient(rpcURL string) *Client {\n");
    try buf.appendSlice("    return &Client{RPCURL: rpcURL}\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("type RPCRequest struct {\n");
    try buf.appendSlice("    JSONRPC string      `json:\"jsonrpc\"`\n");
    try buf.appendSlice("    ID      int         `json:\"id\"`\n");
    try buf.appendSlice("    Method  string      `json:\"method\"`\n");
    try buf.appendSlice("    Params  interface{} `json:\"params\"`\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("func (c *Client) rpcCall(method string, params interface{}) (interface{}, error) {\n");
    try buf.appendSlice("    reqBody, _ := json.Marshal(RPCRequest{\n");
    try buf.appendSlice("        JSONRPC: \"2.0\",\n");
    try buf.appendSlice("        ID: 1,\n");
    try buf.appendSlice("        Method: method,\n");
    try buf.appendSlice("        Params: params,\n");
    try buf.appendSlice("    })\n\n");
    try buf.appendSlice("    resp, err := http.Post(c.RPCURL, \"application/json\", strings.NewReader(string(reqBody)))\n");
    try buf.appendSlice("    if err != nil {\n");
    try buf.appendSlice("        return nil, err\n");
    try buf.appendSlice("    }\n");
    try buf.appendSlice("    defer resp.Body.Close()\n\n");
    try buf.appendSlice("    var result map[string]interface{}\n");
    try buf.appendSlice("    json.NewDecoder(resp.Body).Decode(&result)\n");
    try buf.appendSlice("    return result[\"result\"], nil\n");
    try buf.appendSlice("}\n\n");

    // Generate methods
    for (KNOT3_RPC_METHODS) |method| {
        try buf.appendSlice("func (c *Client) ");
        try buf.appendSlice(method.name["knot3_".len..]);
        try buf.appendSlice("(");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            const kind = if (method.param_json) |p| p[i] else RpcParamJsonKind.string;
            const temp = switch (kind) {
                .string => try std.fmt.allocPrint(sdk.allocator, "{s} string", .{param}),
                .integer => try std.fmt.allocPrint(sdk.allocator, "{s} int64", .{param}),
                .optional_integer => try std.fmt.allocPrint(sdk.allocator, "{s} *int64", .{param}),
            };
            defer sdk.allocator.free(temp);
            try buf.appendSlice(temp);
        }
        try buf.appendSlice(") (interface{}, error) {\n");
        if (method.object_params) {
            const pjson = method.param_json.?;
            try buf.appendSlice("    p := map[string]interface{}{\n");
            for (method.params, 0..) |param, i| {
                if (pjson[i] == .optional_integer) continue;
                try buf.appendSlice("        \"");
                try buf.appendSlice(param);
                try buf.appendSlice("\": ");
                try buf.appendSlice(param);
                try buf.appendSlice(",\n");
            }
            try buf.appendSlice("    }\n");
            for (method.params, 0..) |param, i| {
                if (pjson[i] != .optional_integer) continue;
                try buf.appendSlice("    if ");
                try buf.appendSlice(param);
                try buf.appendSlice(" != nil {\n        p[\"");
                try buf.appendSlice(param);
                try buf.appendSlice("\"] = *");
                try buf.appendSlice(param);
                try buf.appendSlice("\n    }\n");
            }
            try buf.appendSlice("    return c.rpcCall(\"");
            try buf.appendSlice(method.name);
            try buf.appendSlice("\", p)\n");
        } else {
            try buf.appendSlice("    return c.rpcCall(\"");
            try buf.appendSlice(method.name);
            try buf.appendSlice("\", []interface{}{");
            for (method.params, 0..) |param, i| {
                if (i > 0) try buf.appendSlice(", ");
                try buf.appendSlice(param);
            }
            try buf.appendSlice("})\n");
        }
        try buf.appendSlice("}\n\n");
    }

    // Types
    try buf.appendSlice("type Knot3Object struct {\n");
    try buf.appendSlice("    ID      string `json:\"id\"`\n");
    try buf.appendSlice("    Version uint64 `json:\"version\"`\n");
    try buf.appendSlice("    Owner   string `json:\"owner\"`\n");
    try buf.appendSlice("    Type    string `json:\"type\"`\n");
    try buf.appendSlice("    Data    string `json:\"data\"`\n");
    try buf.appendSlice("}\n\n");

    return buf.toOwnedSlice();
}

/// Generate Rust SDK
fn generateRust(sdk: *ClientSDK) ![]const u8 {
    var buf = CompatList.init(sdk.allocator);

    // Header
    try buf.appendSlice("// Auto-generated zknot3 SDK for Rust\n");
    try buf.appendSlice("// Do not edit manually\n\n");

    try buf.appendSlice("use serde::{Deserialize, Serialize};\n");
    try buf.appendSlice("use reqwest;\n\n");

    // Client struct
    try buf.appendSlice("pub struct Knot3Client {\n");
    try buf.appendSlice("    rpc_url: String,\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("impl Knot3Client {\n");
    try buf.appendSlice("    pub fn new(rpc_url: &str) -> Self {\n");
    try buf.appendSlice("        Self { rpc_url: rpc_url.to_string() }\n");
    try buf.appendSlice("    }\n\n");

    try buf.appendSlice("    async fn rpc_call(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value, reqwest::Error> {\n");
    try buf.appendSlice("        let client = reqwest::Client::new();\n");
    try buf.appendSlice("        let body = serde_json::json!({\n");
    try buf.appendSlice("            \"jsonrpc\": \"2.0\",\n");
    try buf.appendSlice("            \"id\": 1,\n");
    try buf.appendSlice("            \"method\": method,\n");
    try buf.appendSlice("            \"params\": params,\n");
    try buf.appendSlice("        });\n\n");
    try buf.appendSlice("        client.post(&self.rpc_url)\n");
    try buf.appendSlice("            .json(&body)\n");
    try buf.appendSlice("            .send()\n");
    try buf.appendSlice("            .await?\n");
    try buf.appendSlice("            .json()\n");
    try buf.appendSlice("            .await\n");
    try buf.appendSlice("    }\n\n");

    // Generate methods
    for (KNOT3_RPC_METHODS) |method| {
        const method_name = method.name["knot3_".len..];
        var snake_buf: [256]u8 = undefined;
        const snake_name = convertToSnakeCase(method_name, &snake_buf);

        try buf.appendSlice("    pub async fn ");
        try buf.appendSlice(snake_name);
        try buf.appendSlice("(&self, ");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            const kind = if (method.param_json) |p| p[i] else RpcParamJsonKind.string;
            switch (kind) {
                .string => {
                    try buf.appendSlice(param);
                    try buf.appendSlice(": &str");
                },
                .integer => {
                    try buf.appendSlice(param);
                    try buf.appendSlice(": u64");
                },
                .optional_integer => {
                    try buf.appendSlice(param);
                    try buf.appendSlice(": Option<u64>");
                },
            }
        }
        try buf.appendSlice(") -> Result<serde_json::Value, reqwest::Error> {\n");
        if (method.object_params) {
            const pjson = method.param_json.?;
            var has_opt = false;
            for (pjson) |k| {
                if (k == .optional_integer) has_opt = true;
            }
            if (has_opt) {
                try buf.appendSlice("        let mut p = serde_json::json!({\n");
                for (method.params, 0..) |param, i| {
                    if (pjson[i] == .optional_integer) continue;
                    try buf.appendSlice("            \"");
                    try buf.appendSlice(param);
                    try buf.appendSlice("\": ");
                    if (pjson[i] == .integer) {
                        try buf.appendSlice(param);
                    } else {
                        try buf.appendSlice(param);
                    }
                    try buf.appendSlice(",\n");
                }
                try buf.appendSlice("        });\n");
                for (method.params, 0..) |param, i| {
                    if (pjson[i] != .optional_integer) continue;
                    try buf.appendSlice("        if let Some(v) = ");
                    try buf.appendSlice(param);
                    try buf.appendSlice(" {\n            p[\"");
                    try buf.appendSlice(param);
                    try buf.appendSlice("\"] = serde_json::json!(v);\n        }\n");
                }
                try buf.appendSlice("        self.rpc_call(\"");
                try buf.appendSlice(method.name);
                try buf.appendSlice("\", p).await\n");
            } else {
                try buf.appendSlice("        self.rpc_call(\"");
                try buf.appendSlice(method.name);
                try buf.appendSlice("\", serde_json::json!({\n");
                for (method.params, 0..) |param, i| {
                    try buf.appendSlice("            \"");
                    try buf.appendSlice(param);
                    try buf.appendSlice("\": ");
                    if (pjson[i] == .integer) {
                        try buf.appendSlice(param);
                    } else {
                        try buf.appendSlice(param);
                    }
                    try buf.appendSlice(",\n");
                }
                try buf.appendSlice("        })).await\n");
            }
        } else {
            try buf.appendSlice("        self.rpc_call(\"");
            try buf.appendSlice(method.name);
            try buf.appendSlice("\", serde_json::json!(vec![");
            for (method.params, 0..) |param, i| {
                if (i > 0) try buf.appendSlice(", ");
                try buf.appendSlice(param);
            }
            try buf.appendSlice("])).await\n");
        }
        try buf.appendSlice("    }\n\n");
    }

    try buf.appendSlice("}\n\n");

    // Types
    try buf.appendSlice("#[derive(Serialize, Deserialize)]\n");
    try buf.appendSlice("pub struct Knot3Object {\n");
    try buf.appendSlice("    pub id: String,\n");
    try buf.appendSlice("    pub version: u64,\n");
    try buf.appendSlice("    pub owner: String,\n");
    try buf.appendSlice("    #[serde(rename = \"type\")]\n");
    try buf.appendSlice("    pub obj_type: String,\n");
    try buf.appendSlice("    pub data: String,\n");
    try buf.appendSlice("}\n\n");

    return buf.toOwnedSlice();
}

/// Generate Zig SDK
fn generateZig(sdk: *ClientSDK) ![]const u8 {
    var buf = CompatList.init(sdk.allocator);

    // Header
    try buf.appendSlice("// Auto-generated zknot3 SDK for Zig\n");
    try buf.appendSlice("// Do not edit manually\n\n");

    try buf.appendSlice("const std = @import(\"std\");\n\n");
    try buf.appendSlice("pub const Knot3Client = struct {\n");
    try buf.appendSlice("    allocator: std.mem.Allocator,\n");
    try buf.appendSlice("    rpc_url: []const u8,\n\n");
    try buf.appendSlice("    pub fn init(allocator: std.mem.Allocator, rpc_url: []const u8) Knot3Client {\n");
    try buf.appendSlice("        return .{ .allocator = allocator, .rpc_url = rpc_url };\n");
    try buf.appendSlice("    }\n\n");
    try buf.appendSlice("    fn rpcCall(self: *const Knot3Client, method: []const u8, params_json: []const u8) ![]u8 {\n");
    try buf.appendSlice("        const body = try std.fmt.allocPrint(self.allocator,\n");
    try buf.appendSlice("            \"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":1,\\\"method\\\":\\\"{s}\\\",\\\"params\\\":{s}}\",\n");
    try buf.appendSlice("            .{ method, params_json },\n");
    try buf.appendSlice("        );\n");
    try buf.appendSlice("        defer self.allocator.free(body);\n\n");
    try buf.appendSlice("        var client = std.http.Client{ .allocator = self.allocator };\n");
    try buf.appendSlice("        defer client.deinit();\n");
    try buf.appendSlice("        const uri = try std.Uri.parse(self.rpc_url);\n\n");
    try buf.appendSlice("        var response_body = std.ArrayList(u8).empty;\n");
    try buf.appendSlice("        defer response_body.deinit(self.allocator);\n\n");
    try buf.appendSlice("        const fetch_result = try client.fetch(.{\n");
    try buf.appendSlice("            .method = .POST,\n");
    try buf.appendSlice("            .location = .{ .uri = uri },\n");
    try buf.appendSlice("            .extra_headers = &.{\n");
    try buf.appendSlice("                .{ .name = \"content-type\", .value = \"application/json\" },\n");
    try buf.appendSlice("            },\n");
    try buf.appendSlice("            .payload = body,\n");
    try buf.appendSlice("            .response_storage = .{ .dynamic = &response_body },\n");
    try buf.appendSlice("        });\n");
    try buf.appendSlice("        if (fetch_result.status != .ok) return error.RpcHttpStatus;\n");
    try buf.appendSlice("        return response_body.toOwnedSlice(self.allocator);\n");
    try buf.appendSlice("    }\n\n");

    // Generate methods
    for (KNOT3_RPC_METHODS) |method| {
        try buf.appendSlice("    pub fn ");
        try buf.appendSlice(method.name["knot3_".len..]);
        try buf.appendSlice("(self: *const Knot3Client");
        if (method.object_params) {
            const pjson = method.param_json.?;
            for (method.params, 0..) |param, i| {
                try buf.appendSlice(", ");
                try buf.appendSlice(param);
                switch (pjson[i]) {
                    .string => try buf.appendSlice(": []const u8"),
                    .integer => try buf.appendSlice(": u64"),
                    .optional_integer => try buf.appendSlice(": ?u64"),
                }
            }
        } else {
            for (method.params) |param| {
                try buf.appendSlice(", ");
                try buf.appendSlice(param);
                try buf.appendSlice(": []const u8");
            }
        }
        try buf.appendSlice(") ![]u8 {\n");
        if (method.object_params) {
            const pjson = method.param_json.?;
            try buf.appendSlice("        var params_buf = std.ArrayList(u8).empty;\n");
            try buf.appendSlice("        defer params_buf.deinit(self.allocator);\n");
            try buf.appendSlice("        const w = params_buf.writer(self.allocator);\n");
            try buf.appendSlice("        try params_buf.appendSlice(self.allocator, \"{\");\n");
            try buf.appendSlice("        var __first: bool = true;\n");
            for (method.params, 0..) |param, i| {
                if (pjson[i] == .optional_integer) continue;
                try buf.appendSlice("        if (!__first) try params_buf.appendSlice(self.allocator, \",\");\n");
                try buf.appendSlice("        __first = false;\n");
                const key_ln = try std.fmt.allocPrint(sdk.allocator, "        try params_buf.appendSlice(self.allocator, \"\\\"{s}\\\":\\\");\n", .{param});
                defer sdk.allocator.free(key_ln);
                try buf.appendSlice(key_ln);
                try buf.appendSlice("        try std.json.stringify(");
                try buf.appendSlice(param);
                try buf.appendSlice(", .{}, w);\n");
            }
            for (method.params, 0..) |param, i| {
                if (pjson[i] != .optional_integer) continue;
                try buf.appendSlice("        if (");
                try buf.appendSlice(param);
                try buf.appendSlice(") |__v| {\n");
                try buf.appendSlice("            if (!__first) try params_buf.appendSlice(self.allocator, \",\");\n");
                try buf.appendSlice("            __first = false;\n");
                const ok_ln = try std.fmt.allocPrint(sdk.allocator, "            try params_buf.appendSlice(self.allocator, \"\\\"{s}\\\":\\\");\n", .{param});
                defer sdk.allocator.free(ok_ln);
                try buf.appendSlice(ok_ln);
                try buf.appendSlice("            try std.json.stringify(__v, .{}, w);\n");
                try buf.appendSlice("        }\n");
            }
            try buf.appendSlice("        try params_buf.appendSlice(self.allocator, \"}\");\n");
        } else {
            try buf.appendSlice("        var params_buf = std.ArrayList(u8).empty;\n");
            try buf.appendSlice("        defer params_buf.deinit(self.allocator);\n");
            try buf.appendSlice("        const w = params_buf.writer(self.allocator);\n");
            try buf.appendSlice("        try params_buf.appendSlice(self.allocator, \"[\");\n");
            if (method.params.len > 0) {
                for (method.params, 0..) |param, i| {
                    if (i > 0) try buf.appendSlice("        try params_buf.appendSlice(self.allocator, \",\");\n");
                    try buf.appendSlice("        try std.json.stringify(");
                    try buf.appendSlice(param);
                    try buf.appendSlice(", .{}, w);\n");
                }
            }
            try buf.appendSlice("        try params_buf.appendSlice(self.allocator, \"]\");\n");
        }
        try buf.appendSlice("        return self.rpcCall(\"");
        try buf.appendSlice(method.name);
        try buf.appendSlice("\", params_buf.items);\n");
        try buf.appendSlice("    }\n\n");
    }

    try buf.appendSlice("};\n\n");
    try buf.appendSlice("pub const Knot3Object = struct {\n");
    try buf.appendSlice("    id: []const u8,\n");
    try buf.appendSlice("    version: u64,\n");
    try buf.appendSlice("    owner: []const u8,\n");
    try buf.appendSlice("    obj_type: []const u8,\n");
    try buf.appendSlice("    data: []const u8,\n");
    try buf.appendSlice("};\n\n");

    try buf.appendSlice("pub const Checkpoint = struct {\n");
    try buf.appendSlice("    sequence: u64,\n");
    try buf.appendSlice("    digest: []const u8,\n");
    try buf.appendSlice("    timestamp: u64,\n");
    try buf.appendSlice("};\n");

    return buf.toOwnedSlice();
}

/// Convert CamelCase to snake_case into caller-provided buffer.
fn convertToSnakeCase(name: []const u8, out: []u8) []const u8 {
    var j: usize = 0;
    for (name, 0..) |c, i| {
        if (i > 0 and c >= 'A' and c <= 'Z') {
            out[j] = '_';
            j += 1;
        }
        out[j] = std.ascii.toLower(c);
        j += 1;
    }
    return out[0..j];
}

test "ClientSDK TypeScript generation" {
    const allocator = std.testing.allocator;
    const config = SDKConfig{
        .language = .typescript,
        .output_dir = "/tmp/sdk",
        .package_name = "zknot3-ts",
    };

    var sdk = try ClientSDK.init(allocator, config);
    defer sdk.deinit();

    const code = try sdk.generateCode();
    defer allocator.free(code);
    try std.testing.expect(code.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, code, "knot3_getObject") != null);
}

test "ClientSDK methods count" {
    // Verify all RPC methods are defined
    try std.testing.expect(KNOT3_RPC_METHODS.len >= 10);
}

test "ClientSDK Zig generation" {
    const allocator = std.testing.allocator;
    const config = SDKConfig{
        .language = .zig,
        .output_dir = "/tmp/sdk",
        .package_name = "zknot3-zig",
    };

    var sdk = try ClientSDK.init(allocator, config);
    defer sdk.deinit();

    const code = try sdk.generateCode();
    defer allocator.free(code);
    try std.testing.expect(code.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const Knot3Client") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub fn getObject") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "std.http.Client") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\\\"jsonrpc\\\":\\\"2.0\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "std.ArrayList(u8).empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "std.ArrayList(u8).init(") == null);
    // M4 v2 Zig SDK: object params + typed integers
    try std.testing.expect(std.mem.indexOf(u8, code, "pub fn submitStakeOperation") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "amount: u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub fn getCheckpointProof") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "sequence: u64") != null);
}

test "ClientSDK multi-language smoke generation" {
    const allocator = std.testing.allocator;

    const langs = [_]TargetLanguage{ .typescript, .python, .go };
    for (langs) |lang| {
        const config = SDKConfig{
            .language = lang,
            .output_dir = "/tmp/sdk",
            .package_name = "zknot3-smoke",
        };
        var sdk = try ClientSDK.init(allocator, config);
        defer sdk.deinit();
        const code = try sdk.generateCode();
        defer allocator.free(code);
        try std.testing.expect(code.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, code, "knot3_getObject") != null);
    }
}

test "ClientSDK Python M4 receipt dataclasses and return hints" {
    const allocator = std.testing.allocator;
    const config = SDKConfig{
        .language = .python,
        .output_dir = "/tmp/sdk",
        .package_name = "zknot3-py",
    };
    var sdk = try ClientSDK.init(allocator, config);
    defer sdk.deinit();
    const code = try sdk.generateCode();
    defer allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "class StakeOperationReceipt:") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "class GovernanceProposalReceipt:") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "class CheckpointProof:") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "def submit_stake_operation(") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, ") -> StakeOperationReceipt:") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, ") -> CheckpointProof:") != null);
}
