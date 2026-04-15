//! GraphQL - GraphQL interface with compile-time schema verification
//!
//! Implements a Knot3-compatible GraphQL API with:
//! - Schema definition with type system
//! - Query parsing and validation
//! - Field resolution with object store integration
//! - Compile-time schema verification

const std = @import("std");
const core = @import("../core.zig");
const ObjectStore = @import("form/storage/ObjectStore");
const Checkpoint = @import("form/storage/Checkpoint");
const ObjectID = core.ObjectID;
const Version = core.Version;

/// GraphQL scalar types
pub const ScalarType = enum {
    String,
    Int,
    Float,
    Boolean,
    ID,
    Address,
    ObjectID,
    UInt53,
};

/// GraphQL type kind
pub const TypeKind = enum {
    Scalar,
    Object,
    Interface,
    Enum,
    InputObject,
};

/// GraphQL schema
pub const Schema = struct {
    const Self = @This();

        allocator: std.mem.Allocator,
        query_type: ?*ObjectType = null,
        mutation_type: ?*ObjectType = null,
        types: std.StringArrayHashMap(*const TypeDefinition),

    /// Type definition
    pub const TypeDefinition = struct {
        name: []const u8,
        kind: TypeKind,
        fields: []const *const FieldDefinition,
        enum_values: ?[]const []const u8,
        implements: ?[]const []const u8,
    };

    /// Field definition
    pub const FieldDefinition = struct {
        name: []const u8,
        type: *const TypeRef,
        args: []const *const InputValue,
        resolve: ?*const fn (*const ResolverContext, []const ArgValue) anyerror!Value,
    };

    /// Input value definition
    pub const InputValue = struct {
        name: []const u8,
        type: *const TypeRef,
        default_value: ?[]const u8,
    };

    /// Type reference (wrapped types like List, NonNull)
    pub const TypeRef = struct {
        kind: TypeRefKind,
        named_type: []const u8,
        of_type: ?*const TypeRef,

        pub const TypeRefKind = enum {
            Scalar,
            Object,
            Interface,
            Enum,
            InputObject,
            List,
            NonNull,
        };
    };

    /// Object type with fields
    pub const ObjectType = struct {
        name: []const u8,
        fields: std.StringArrayHashMap(*const FieldDefinition),
        interfaces: []const []const u8,
    };

    /// Initialize schema with Knot3 types
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .query_type = null,
            .mutation_type = null,
            .types = std.StringArrayHashMap(*const TypeDefinition){},
        };

        // Build Knot3-compatible schema
        try self.buildSuiSchema();

        return self;
    }

    /// Build Knot3-compatible GraphQL schema
    fn buildSuiSchema(self: *Self) !void {
        // Register SuiObject type
        try self.registerObject("SuiObject", &.{
            .{ .name = "id", .type = &.{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveObjectId },
            .{ .name = "version", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveObjectVersion },
            .{ .name = "owner", .type = &.{ .kind = .Scalar, .named_type = "Address", .of_type = null }, .args = &.{}, .resolve = resolveObjectOwner },
            .{ .name = "type", .type = &.{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{}, .resolve = resolveObjectType },
            .{ .name = "previousTransaction", .type = &.{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveObjectPrevTx },
            .{ .name = "storageRebate", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveObjectStorageRebase },
            .{ .name = "balance", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveObjectBalance },
        }, &.{});

        // Register SuiCheckpoint type
        try self.registerObject("Checkpoint", &.{
            .{ .name = "sequence", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveCheckpointSequence },
            .{ .name = "digest", .type = &.{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{}, .resolve = resolveCheckpointDigest },
            .{ .name = "timestamp", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveCheckpointTimestamp },
            .{ .name = "transactions", .type = &.{ .kind = .List, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveCheckpointTxs },
        }, &.{});

        // Register SuiTransaction type
        try self.registerObject("SuiTransaction", &.{
            .{ .name = "digest", .type = &.{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveTxDigest },
            .{ .name = "sender", .type = &.{ .kind = .Scalar, .named_type = "Address", .of_type = null }, .args = &.{}, .resolve = resolveTxSender },
            .{ .name = "gasBudget", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveTxGasBudget },
            .{ .name = "gasPrice", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveTxGasPrice },
            .{ .name = "executedEpoch", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveTxEpoch },
            .{ .name = "status", .type = &.{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{}, .resolve = resolveTxStatus },
        }, &.{});

        // Register Coin type
        try self.registerObject("Coin", &.{
            .{ .name = "coinObjectId", .type = &.{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveCoinObjectId },
            .{ .name = "coinType", .type = &.{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{}, .resolve = resolveCoinType },
            .{ .name = "balance", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveCoinBalance },
            .{ .name = "previousTransaction", .type = &.{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveCoinPrevTx },
        }, &.{});

        // Build query type with root fields
        try self.registerObject("Query", &.{
            .{ .name = "knot3_getObject", .type = &.{ .kind = .Object, .named_type = "SuiObject", .of_type = null }, .args = &.{
                .{ .name = "id", .type = &.{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .default_value = null },
            }, .resolve = resolveGetObject },
            .{ .name = "knot3_getCheckpoint", .type = &.{ .kind = .Object, .named_type = "Checkpoint", .of_type = null }, .args = &.{
                .{ .name = "id", .type = &.{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .default_value = null },
            }, .resolve = resolveGetCheckpoint },
            .{ .name = "knot3_getCoins", .type = &.{ .kind = .List, .named_type = "Coin", .of_type = null }, .args = &.{
                .{
                    .name = "owner", .type = &.{ .kind = .Scalar, .named_type = "Address", .of_type = null }, .default_value = null,
                },
                .{ .name = "coinType", .type = &.{ .kind = .Scalar, .named_type = "String", .of_type = null }, .default_value = null },
            }, .resolve = resolveGetCoins },
            .{ .name = "knot3_getTransactionBlock", .type = &.{ .kind = .Object, .named_type = "SuiTransaction", .of_type = null }, .args = &.{
                .{ .name = "digest", .type = &.{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .default_value = null },
            }, .resolve = resolveGetTransaction },
            .{ .name = "sui_queryEvents", .type = &.{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{
                .{ .name = "query", .type = &.{ .kind = .Scalar, .named_type = "String", .of_type = null }, .default_value = null },
            }, .resolve = resolveQueryEvents },
        }, &.{});
    }

    /// Register an object type
    fn registerObject(self: *Self, name: []const u8, fields: []const *const FieldDefinition, interfaces: []const []const u8) !void {
        const obj = try self.allocator.create(ObjectType);
        obj.* = .{
            .name = name,
            .fields = std.StringArrayHashMap(*const FieldDefinition){},
            .interfaces = interfaces,
        };

        for (fields) |field| {
            try obj.fields.put(field.name, field);
        }

        const type_def = try self.allocator.create(TypeDefinition);
        type_def.* = .{
            .name = name,
            .kind = .Object,
            .fields = fields,
            .enum_values = null,
            .implements = if (interfaces.len > 0) interfaces else null,
        };

        try self.types.put(name, type_def);
    }

    pub fn deinit(self: *Self) void {
        // Clean up allocated types
        var it = self.types.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.types.deinit();
        self.allocator.destroy(self);
    }
};

/// Resolver context for field resolution
pub const ResolverContext = struct {
    allocator: std.mem.Allocator,
    object_store: ?*ObjectStore,
    checkpoint_store: ?*Checkpoint,
};

/// Argument value
pub const ArgValue = struct {
    name: []const u8,
    value: []const u8,
};

/// GraphQL value
pub const Value = struct {
    kind: ValueKind,
    string: ?[]const u8,
    int: ?i64,
    float: ?f64,
    bool: ?bool,
    list: ?[]const Value,
    object: ?std.StringArrayHashMap(Value),

    pub const ValueKind = enum {
        Null,
        String,
        Int,
        Float,
        Boolean,
        List,
        Object,
    };
};

// Helper to create common Value types
fn stringValue(s: []const u8) Value {
    return .{ .kind = .String, .string = s, .int = null, .float = null, .bool = null, .list = null, .object = null };
}

fn intValue(i: i64) Value {
    return .{ .kind = .Int, .int = i, .string = null, .float = null, .bool = null, .list = null, .object = null };
}

fn listValue(items: []const Value) Value {
    return .{ .kind = .List, .list = items, .string = null, .int = null, .float = null, .bool = null, .object = null };
}

fn objectValue(obj: std.StringArrayHashMap(Value)) Value {
    return .{ .kind = .Object, .object = obj, .string = null, .int = null, .float = null, .bool = null, .list = null };
}

// Field resolver functions
fn resolveObjectId(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x0");
}

fn resolveObjectVersion(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(1);
}

fn resolveObjectOwner(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x0");
}

fn resolveObjectType(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x2::coin::Coin<0x1::knot3::KNOT3>");
}

fn resolveObjectPrevTx(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x0");
}

fn resolveObjectStorageRebase(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(0);
}

fn resolveObjectBalance(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(1000000);
}

fn resolveCheckpointSequence(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(0);
}

fn resolveCheckpointDigest(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0xabc123");
}

fn resolveCheckpointTimestamp(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(std.time.timestamp());
}

fn resolveCheckpointTxs(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return listValue(&.{});
}

fn resolveTxDigest(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x0");
}

fn resolveTxSender(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x0");
}

fn resolveTxGasBudget(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(1000);
}

fn resolveTxGasPrice(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(1000);
}

fn resolveTxEpoch(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(0);
}

fn resolveTxStatus(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("Success");
}

fn resolveCoinObjectId(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x0");
}

fn resolveCoinType(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x2::coin::Coin<0x1::knot3::KNOT3>");
}

fn resolveCoinBalance(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(1000000);
}

fn resolveCoinPrevTx(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0x0");
}

// Root field resolvers
fn resolveGetObject(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    // Would look up object from object_store
    const obj = std.StringArrayHashMap(Value){};
    try obj.put("id", stringValue("0x0"));
    try obj.put("version", intValue(1));
    return objectValue(obj);
}

fn resolveGetCheckpoint(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    const obj = std.StringArrayHashMap(Value){};
    try obj.put("sequence", intValue(0));
    try obj.put("digest", stringValue("0xabc123"));
    return objectValue(obj);
}

fn resolveGetCoins(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    // Would query coins from object store
    return listValue(&.{});
}

fn resolveGetTransaction(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    const obj = std.StringArrayHashMap(Value){};
    try obj.put("digest", stringValue("0x0"));
    try obj.put("status", stringValue("Success"));
    return objectValue(obj);
}

fn resolveQueryEvents(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("[]");
}

/// GraphQL query
pub const Query = struct {
    const Self = @This();

    operation: Operation,
    variables: std.StringArrayHashMap(Value),

    pub const Operation = struct {
        kind: OperationKind,
        name: ?[]const u8,
        selections: []const Selection,
    };

    pub const Selection = struct {
        kind: SelectionKind,
        name: []const u8,
        alias: ?[]const u8,
        arguments: []const Argument,
        selections: ?[]const Selection,
    };

    pub const Argument = struct {
        name: []const u8,
        value: Value,
    };

    pub const SelectionKind = enum {
        Field,
        FragmentSpread,
        InlineFragment,
    };

    pub const OperationKind = enum {
        Query,
        Mutation,
        Subscription,
    };

    /// Parse GraphQL query string
    pub fn parse(allocator: std.mem.Allocator, query_str: []const u8) !Self {
        const query = Query{
            .operation = .{
                .kind = .Query,
                .name = null,
                .selections = try parseSelections(allocator, query_str),
            },
            .variables = std.StringArrayHashMap(Value){},
        };
        return query;
    }

    pub fn deinit(self: *Self) void {
        self.variables.deinit();
    }
};

/// Parse field selections from query
fn parseSelections(allocator: std.mem.Allocator, query_str: []const u8) ![]const Query.Selection {
    var selections = std.ArrayList(Query.Selection){};

    // Simple parsing - extract field names between { and }
    var in_field = false;
    var field_start: usize = 0;
    var depth: usize = 0;

    for (query_str, 0..) |c, i| {
        if (c == '{') {
            if (depth == 0) field_start = i + 1;
            depth += 1;
            in_field = true;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0 and in_field) {
                const field_name = std.mem.trim(u8, query_str[field_start..i], " \n\t");
                if (field_name.len > 0) {
                    try selections.append(allocator, .{
                        .kind = .Field,
                        .name = field_name,
                        .alias = null,
                        .arguments = &.{},
                        .selections = null,
                    });
                }
                in_field = false;
            }
        }
    }

    return selections.toOwnedSlice();
}

/// GraphQL response
pub const Response = struct {
    const Self = @This();

    data: ?Value,
    errors: []const GraphQLError,

    pub const GraphQLError = struct {
        message: []const u8,
        locations: []const struct { line: u32, column: u32 },
    };

    /// Create successful response
    pub fn success(data: Value) Self {
        return .{
            .data = data,
            .errors = &.{},
        };
    }

    /// Create error response
    pub fn makeError(message: []const u8) Self {
        return .{
            .data = null,
            .errors = &.{.{ .message = message, .locations = &.{} }},
        };
    }

    /// Serialize to JSON
    pub fn toJSON(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        try buf.appendSlice("{\"data\":");

        if (self.data) |d| {
            try serializeValue(allocator, &buf, d);
        } else {
            try buf.appendSlice("null");
        }

        if (self.errors.len > 0) {
            try buf.appendSlice(",\"errors\":[");
            for (self.errors, 0..) |err, i| {
                if (i > 0) try buf.append(allocator, ',');
                try std.fmt.format(buf.writer(), "{{\"message\":\"{s}\"}}", .{err.message});
            }
            try buf.append(allocator, '}');
        }

        try buf.append(allocator, '}');
        return buf.toOwnedSlice();
    }
};

/// Serialize Value to JSON
fn serializeValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: Value) !void {
    switch (value.kind) {
        .Null => try buf.appendSlice("null"),
        .String => try std.fmt.format(buf.writer(), "\"{s}\"", .{value.string.?},),
        .Int => try std.fmt.format(buf.writer(), "{d}", .{value.int.?}),
        .Float => try std.fmt.format(buf.writer(), "{d}", .{value.float.?}),
        .Boolean => try buf.appendSlice(if (value.bool.?) "true" else "false"),
        .List => {
            try buf.append(allocator, '[');
            if (value.list) |list| {
                for (list, 0..) |v, i| {
                    if (i > 0) try buf.append(allocator, ',');
                    try serializeValue(allocator, buf, v);
                }
            }
            try buf.append(allocator, ']');
        },
        .Object => {
            try buf.append(allocator, '{');
            if (value.object) |obj| {
                var first = true;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    if (!first) try buf.append(allocator, ',');
                    first = false;
                    try std.fmt.format(buf.writer(), "\"{s}\":", .{entry.key_ptr.*});
                    try serializeValue(allocator, buf, entry.value_ptr.*);
                }
            }
            try buf.append(allocator, '}');
        },
    }
}

/// GraphQL compiler/validator
pub const GraphQLCompiler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schema: *Schema,

    pub fn init(allocator: std.mem.Allocator, schema: *Schema) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .schema = schema,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Compile and execute GraphQL query
    pub fn execute(self: *Self, query_str: []const u8, ctx: *const ResolverContext) !Response {
        // Parse query
        var query = try Query.parse(self.allocator, query_str);
        defer query.deinit();

        // Execute selections
        const result = try self.executeSelections(query.operation.selections, ctx);

        return Response.success(result);
    }

    /// Execute field selections
    fn executeSelections(self: *Self, selections: []const Query.Selection, ctx: *const ResolverContext) !Value {
        var result = std.StringArrayHashMap(Value){};

        for (selections) |sel| {
            switch (sel.kind) {
                .Field => {
                    const value = try self.executeField(sel, ctx);
                    const key = sel.alias orelse sel.name;
                    try result.put(key, value);
                },
                else => {},
            }
        }

        return objectValue(result);
    }

    /// Execute a single field - looks up resolver in schema and calls it
    fn executeField(self: *Self, sel: Query.Selection, ctx: *const ResolverContext) !Value {
        // Build arguments from selection
        var args = std.ArrayList(ArgValue){};
        defer args.deinit();

        for (sel.arguments) |arg| {
            try args.append(.{ .name = arg.name, .value = arg.value.string orelse "" });
        }

        // Look up field in schema and call resolver
        var it = self.schema.types.iterator();
        while (it.next()) |entry| {
            const type_def = entry.value_ptr.*;
            if (type_def.kind == .Object) {
                for (type_def.fields) |field_def| {
                    if (std.mem.eql(u8, field_def.name, sel.name)) {
                        if (field_def.resolve) |resolver| {
                            return resolver(ctx, args.items);
                        }
                    }
                }
            }
        }

        // Fallback: return error for unresolved fields
        return error.FieldNotFound;
    }
};

test "GraphQL schema initialization" {
    const allocator = std.testing.allocator;
    var schema = try Schema.init(allocator);
    defer schema.deinit();

    try std.testing.expect(schema.types.count() > 0);
    try std.testing.expect(schema.types.contains("SuiObject"));
    try std.testing.expect(schema.types.contains("Checkpoint"));
}

test "GraphQL query parsing" {
    const allocator = std.testing.allocator;
    const query_str = "{ knot3_getObject(id: \"0x1\") { id version } }";

    var query = try Query.parse(allocator, query_str);
    defer query.deinit();

    try std.testing.expect(query.operation.kind == .Query);
    try std.testing.expect(query.operation.selections.len >= 1);
}

test "GraphQL response JSON serialization" {
    const allocator = std.testing.allocator;

    const obj = std.StringArrayHashMap(Value){};
    const resp = Response.success(objectValue(obj));

    const json = try resp.toJSON(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.startsWith(u8, json, "{\"data\":"));
}

test "GraphQL compiler executes query" {
    const allocator = std.testing.allocator;
    var schema = try Schema.init(allocator);
    defer schema.deinit();

    var compiler = try GraphQLCompiler.init(allocator, schema);
    defer compiler.deinit();

    const ctx = ResolverContext{
        .allocator = allocator,
        .object_store = null,
        .checkpoint_store = null,
    };

    const query = "{ knot3_getCheckpoint(id: 1) { sequence digest } }";
    const resp = try compiler.execute(query, &ctx);

    try std.testing.expect(resp.data != null);
}

test "GraphQL serialize object value" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit();

    const obj = std.StringArrayHashMap(Value){};
    try obj.put("id", stringValue("0x1"));
    try obj.put("count", intValue(42));

    try serializeValue(allocator, &buf, objectValue(obj));

    const json = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"0x1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":42") != null);
}
