//! ClientSDK - Multi-language bindings generator for zknot3
//!
//! Generates SDK bindings for multiple languages based on the Knot3 RPC API.
//! Supports TypeScript, Python, Go, and Rust.

const std = @import("std");
const core = @import("../core.zig");

/// SDK generation target language
pub const TargetLanguage = enum {
    typescript,
    python,
    go,
    rust,
};

/// SDK configuration
pub const SDKConfig = struct {
    language: TargetLanguage,
    output_dir: []const u8,
    package_name: []const u8,
    rpc_url: []const u8 = "http://localhost:9000",
};

/// Knot3 RPC method definitions
pub const RPCMethod = struct {
    name: []const u8,
    params: []const []const u8,
    return_type: []const u8,
};

/// Supported RPC methods
pub const SUi_RPC_METHODS = &[_]RPCMethod{
    .{ .name = "knot3_getObject", .params = &.{"id"}, .return_type = "SuiObject" },
    .{ .name = "knot3_getCheckpoint", .params = &.{"id"}, .return_type = "Checkpoint" },
    .{ .name = "knot3_getCoins", .params = &.{ "owner", "coinType" }, .return_type = "Coin[]" },
    .{ .name = "knot3_getTransactionBlock", .params = &.{"digest"}, .return_type = "TransactionBlock" },
    .{ .name = "sui_getLatestCheckpointSequenceNumber", .params = &.{}, .return_type = "number" },
    .{ .name = "sui_queryEvents", .params = &.{"query"}, .return_type = "Event[]" },
    .{ .name = "sui_dryRunTransactionBlock", .params = &.{"txBytes"}, .return_type = "DryRunResult" },
    .{ .name = "sui_executeTransactionBlock", .params = &.{ "txBytes", "signature" }, .return_type = "ExecuteResult" },
    .{ .name = "sui_getOwnedObjects", .params = &.{ "owner", "query" }, .return_type = "Object[]" },
    .{ .name = "sui_syncEpochState", .params = &.{}, .return_type = "EpochInfo" },
    .{ .name = "sui_getEpochs", .params = &.{ "first", "cursor" }, .return_type = "Epoch[]" },
};

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
            .typescript => _ = try self.generateTypeScript(),
            .python => _ = try self.generatePython(),
            .go => _ = try self.generateGo(),
            .rust => _ = try self.generateRust(),
        }
    }

    /// Get SDK code as string
    pub fn generateCode(self: *Self) ![]const u8 {
        switch (self.config.language) {
            .typescript => return try self.generateTypeScript(),
            .python => return try self.generatePython(),
            .go => return try self.generateGo(),
            .rust => return try self.generateRust(),
        }
    }
};

/// Generate TypeScript SDK
fn generateTypeScript(sdk: *ClientSDK) ![]const u8 {
    var buf = std.ArrayList(u8).init(sdk.allocator);

    // Header
    try buf.appendSlice("// Auto-generated zknot3 SDK for TypeScript\n");
    try buf.appendSlice("// Do not edit manually\n\n");

    // RPC client class
    try buf.appendSlice("export class SuiClient {\n");
    try buf.appendSlice("    private rpcUrl: string;\n");
    try buf.appendSlice("    \n");
    try buf.appendSlice("    constructor(rpcUrl: string = 'http://localhost:9000') {\n");
    try buf.appendSlice("        this.rpcUrl = rpcUrl;\n");
    try buf.appendSlice("    }\n");
    try buf.appendSlice("    \n");
    try buf.appendSlice("    private async rpcCall<T>(method: string, params: any[]): Promise<T> {\n");
    try buf.appendSlice("        const response = await fetch(this.rpcUrl, {\n");
    try buf.appendSlice("            method: 'POST',\n");
    try buf.appendSlice("            headers: { 'Content-Type': 'application/json' },\n");
    try buf.appendSlice("            body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),\n");
    try buf.appendSlice("        });\n");
    try buf.appendSlice("        const result = await response.json();\n");
    try buf.appendSlice("        return result.result;\n");
    try buf.appendSlice("    }\n\n");

    // Generate methods
    for (SUi_RPC_METHODS) |method| {
        try buf.appendSlice("    async ");
        try buf.appendSlice(method.name["sui_".len..]);
        try buf.appendSlice("(");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param);
            try buf.appendSlice(": string");
        }
        try buf.appendSlice("): Promise<");
        try buf.appendSlice(method.return_type);
        try buf.appendSlice("> {\n");
        try buf.appendSlice("        return this.rpcCall('");
        try buf.appendSlice(method.name);
        try buf.appendSlice("', [");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param);
        }
        try buf.appendSlice("]);\n");
        try buf.appendSlice("    }\n\n");
    }

    try buf.appendSlice("}\n\n");

    // Types
    try buf.appendSlice("// Type definitions\n");
    try buf.appendSlice("export interface SuiObject {\n");
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

    return buf.toOwnedSlice();
}

/// Generate Python SDK
fn generatePython(sdk: *ClientSDK) ![]const u8 {
    var buf = std.ArrayList(u8).init(sdk.allocator);

    // Header
    try buf.appendSlice("# Auto-generated zknot3 SDK for Python\n");
    try buf.appendSlice("# Do not edit manually\n\n");

    try buf.appendSlice("from typing import Any, List, Optional\n");
    try buf.appendSlice("import requests\n\n\n");

    // Client class
    try buf.appendSlice("class SuiClient:\n");
    try buf.appendSlice("    def __init__(self, rpc_url: str = 'http://localhost:9000'):\n");
    try buf.appendSlice("        self.rpc_url = rpc_url\n");
    try buf.appendSlice("    \n");
    try buf.appendSlice("    def _rpc_call(self, method: str, params: List[Any]) -> Any:\n");
    try buf.appendSlice("        response = requests.post(\n");
    try buf.appendSlice("            self.rpc_url,\n");
    try buf.appendSlice("            json={'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params},\n");
    try buf.appendSlice("            headers={'Content-Type': 'application/json'},\n");
    try buf.appendSlice("        )\n");
    try buf.appendSlice("        result = response.json()\n");
    try buf.appendSlice("        return result.get('result')\n\n");

    // Generate methods
    for (SUi_RPC_METHODS) |method| {
        try buf.appendSlice("    def ");
        try buf.appendSlice(method.name["sui_".len..]);
        try buf.appendSlice("(");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param);
            try buf.appendSlice(": str");
        }
        try buf.appendSlice(") -> ");
        try buf.appendSlice(method.return_type);
        try buf.appendSlice(":\n");
        try buf.appendSlice("        \"\"\"");
        try buf.appendSlice(method.name);
        try buf.appendSlice(" RPC call\"\"\"\n");
        try buf.appendSlice("        return self._rpc_call('");
        try buf.appendSlice(method.name);
        try buf.appendSlice("', [");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param);
        }
        try buf.appendSlice("])\n\n");
    }

    // Types as dataclasses
    try buf.appendSlice("from dataclasses import dataclass\n\n");
    try buf.appendSlice("@dataclass\n");
    try buf.appendSlice("class SuiObject:\n");
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

    return buf.toOwnedSlice();
}

/// Generate Go SDK
fn generateGo(sdk: *ClientSDK) ![]const u8 {
    var buf = std.ArrayList(u8).init(sdk.allocator);

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
    try buf.appendSlice("    JSONRPC string        `json:\"jsonrpc\"`\n");
    try buf.appendSlice("    ID      int           `json:\"id\"`\n");
    try buf.appendSlice("    Method  string        `json:\"method\"`\n");
    try buf.appendSlice("    Params  []interface{} `json:\"params\"`\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("func (c *Client) rpcCall(method string, params []interface{}) (interface{}, error) {\n");
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
    for (SUi_RPC_METHODS) |method| {
        try buf.appendSlice("func (c *Client) ");
        try buf.appendSlice(method.name["sui_".len..]);
        try buf.appendSlice("(");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(try std.fmt.allocPrint(sdk.allocator, "{s} string", .{param}));
        }
        try buf.appendSlice(") (interface{{}}, error) {{\n", .{});
        try buf.appendSlice("    return c.rpcCall(\"");
        try buf.appendSlice(method.name);
        try buf.appendSlice("\", []interface{}{");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param);
        }
        try buf.appendSlice("})\n");
        try buf.appendSlice("}\n\n");
    }

    // Types
    try buf.appendSlice("type SuiObject struct {\n");
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
    var buf = std.ArrayList(u8).init(sdk.allocator);

    // Header
    try buf.appendSlice("// Auto-generated zknot3 SDK for Rust\n");
    try buf.appendSlice("// Do not edit manually\n\n");

    try buf.appendSlice("use serde::{Deserialize, Serialize};\n");
    try buf.appendSlice("use reqwest;\n");
    try buf.appendSlice("use std::collections::HashMap;\n\n");

    // Client struct
    try buf.appendSlice("pub struct SuiClient {\n");
    try buf.appendSlice("    rpc_url: String,\n");
    try buf.appendSlice("}\n\n");

    try buf.appendSlice("impl SuiClient {\n");
    try buf.appendSlice("    pub fn new(rpc_url: &str) -> Self {\n");
    try buf.appendSlice("        Self { rpc_url: rpc_url.to_string() }\n");
    try buf.appendSlice("    }\n\n");

    try buf.appendSlice("    async fn rpc_call(&self, method: &str, params: Vec<String>) -> Result<serde_json::Value, reqwest::Error> {\n");
    try buf.appendSlice("        let client = reqwest::Client::new();\n");
    try buf.appendSlice("        let mut body = HashMap::new();\n");
    try buf.appendSlice("        body.insert(\"jsonrpc\", \"2.0\");\n");
    try buf.appendSlice("        body.insert(\"id\", \"1\");\n");
    try buf.appendSlice("        body.insert(\"method\", method);\n");
    try buf.appendSlice("        body.insert(\"params\", serde_json::json!(params));\n\n");
    try buf.appendSlice("        client.post(&self.rpc_url)\n");
    try buf.appendSlice("            .json(&body)\n");
    try buf.appendSlice("            .send()\n");
    try buf.appendSlice("            .await?\n");
    try buf.appendSlice("            .json()\n");
    try buf.appendSlice("            .await\n");
    try buf.appendSlice("    }\n\n");

    // Generate methods
    for (SUi_RPC_METHODS) |method| {
        const method_name = method.name["sui_".len..];
        const snake_name = convertToSnakeCase(method_name);

        try buf.appendSlice("    pub async fn ");
        try buf.appendSlice(snake_name);
        try buf.appendSlice("(&self, ");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(param);
            try buf.appendSlice(": &str");
        }
        try buf.appendSlice(") -> Result<serde_json::Value, reqwest::Error> {\n");
        try buf.appendSlice("        let params = vec![");
        for (method.params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice("\"");
            try buf.appendSlice(param);
            try buf.appendSlice("\".to_string()");
        }
        try buf.appendSlice("];\n");
        try buf.appendSlice("        self.rpc_call(\"");
        try buf.appendSlice(method.name);
        try buf.appendSlice("\", params).await\n");
        try buf.appendSlice("    }\n\n");
    }

    try buf.appendSlice("}\n\n");

    // Types
    try buf.appendSlice("#[derive(Serialize, Deserialize)]\n");
    try buf.appendSlice("pub struct SuiObject {\n");
    try buf.appendSlice("    pub id: String,\n");
    try buf.appendSlice("    pub version: u64,\n");
    try buf.appendSlice("    pub owner: String,\n");
    try buf.appendSlice("    #[serde(rename = \"type\")]\n");
    try buf.appendSlice("    pub obj_type: String,\n");
    try buf.appendSlice("    pub data: String,\n");
    try buf.appendSlice("}\n\n");

    return buf.toOwnedSlice();
}

/// Convert CamelCase to snake_case
fn convertToSnakeCase(name: []const u8) []const u8 {
    var result: [256]u8 = undefined;
    var j: usize = 0;

    for (name, 0..) |c, i| {
        if (i > 0 and c >= 'A' and c <= 'Z') {
            result[j] = '_';
            j += 1;
        }
        result[j] = std.ascii.toLower(c);
        j += 1;
    }

    return result[0..j];
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
    try std.testing.expect(code.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, code, "knot3_getObject") != null);
}

test "ClientSDK methods count" {
    // Verify all RPC methods are defined
    try std.testing.expect(SUi_RPC_METHODS.len >= 10);
}
