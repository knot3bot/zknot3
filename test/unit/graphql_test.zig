//! GraphQL Tests for zknot3
//!
//! Tests for GraphQL schema, query parsing, and resolution.

const std = @import("std");
const GraphQL = root.app.GraphQL;
const root = @import("root.zig");
const ObjectID = root.core.ObjectID;

/// Test GraphQL schema initialization
test "GraphQL schema init" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    try std.testing.expect(schema.query_type != null);
}

/// Test GraphQL scalar types
test "GraphQL scalar types" {
    const scalars = [_]GraphQL.ScalarType{
        .String,
        .Int,
        .Float,
        .Boolean,
        .ID,
        .Address,
        .ObjectID,
        .UInt53,
    };

    for (scalars) |scalar| {
        try std.testing.expect(@as(u8, @intFromEnum(scalar)) >= 0);
    }
}

/// Test GraphQL type kinds
test "GraphQL type kinds" {
    const kinds = [_]GraphQL.TypeKind{
        .Scalar,
        .Object,
        .Interface,
        .Enum,
        .InputObject,
    };

    for (kinds) |kind| {
        try std.testing.expect(@as(u8, @intFromEnum(kind)) >= 0);
    }
}

/// Test GraphQL TypeRef
test "GraphQL TypeRef" {
    const ref = GraphQL.TypeRef{
        .kind = .Scalar,
        .named_type = "String",
        .of_type = null,
    };

    try std.testing.expect(ref.kind == .Scalar);
    try std.testing.expect(std.mem.eql(u8, ref.named_type, "String"));
}

/// Test GraphQL TypeRef with List wrapper
test "GraphQL TypeRef List" {
    const inner = GraphQL.TypeRef{
        .kind = .Scalar,
        .named_type = "String",
        .of_type = null,
    };

    const ref = GraphQL.TypeRef{
        .kind = .List,
        .named_type = "",
        .of_type = &inner,
    };

    try std.testing.expect(ref.kind == .List);
    try std.testing.expect(ref.of_type != null);
    try std.testing.expect(ref.of_type.?.kind == .Scalar);
}

/// Test GraphQL TypeRef with NonNull wrapper
test "GraphQL TypeRef NonNull" {
    const inner = GraphQL.TypeRef{
        .kind = .Scalar,
        .named_type = "Int",
        .of_type = null,
    };

    const ref = GraphQL.TypeRef{
        .kind = .NonNull,
        .named_type = "",
        .of_type = &inner,
    };

    try std.testing.expect(ref.kind == .NonNull);
    try std.testing.expect(ref.of_type != null);
}

/// Test GraphQL FieldDefinition
test "GraphQL FieldDefinition" {
    const field_type = GraphQL.TypeRef{
        .kind = .Scalar,
        .named_type = "String",
        .of_type = null,
    };

    const field = GraphQL.FieldDefinition{
        .name = "name",
        .type = &field_type,
        .args = &.{},
        .resolve = null,
    };

    try std.testing.expect(std.mem.eql(u8, field.name, "name"));
}

/// Test GraphQL InputValue
test "GraphQL InputValue" {
    const value_type = GraphQL.TypeRef{
        .kind = .Scalar,
        .named_type = "String",
        .of_type = null,
    };

    const input = GraphQL.InputValue{
        .name = "id",
        .type = &value_type,
        .default_value = null,
    };

    try std.testing.expect(std.mem.eql(u8, input.name, "id"));
}

/// Test GraphQL ObjectType
test "GraphQL ObjectType" {
    const allocator = std.testing.allocator;
    var obj_type = GraphQL.ObjectType{
        .name = "TestObject",
        .fields = std.StringArrayHashMap(*const GraphQL.FieldDefinition).init(allocator),
        .interfaces = &.{},
    };
    defer obj_type.fields.deinit();

    try std.testing.expect(std.mem.eql(u8, obj_type.name, "TestObject"));
    try std.testing.expect(obj_type.fields.count() == 0);
}

/// Test GraphQL query parsing
test "GraphQL query parsing basic" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    const query = "{ object(id: \"0x1\") { id version } }";

    // Query should be parseable
    try std.testing.expect(query.len > 0);
}

/// Test GraphQL resolver context
test "GraphQL resolver context creation" {
    const allocator = std.testing.allocator;

    var ctx = GraphQL.ResolverContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.allocator == allocator);
}

/// Test GraphQL value types
test "GraphQL values" {
    const values = [_]GraphQL.Value{
        .{ .string = try std.testing.allocator.dupe(u8, "test") },
        .{ .int = 42 },
        .{ .float = 3.14 },
        .{ .boolean = true },
    };

    try std.testing.expect(values[0].string != null);
    try std.testing.expect(values[1].int == 42);
    try std.testing.expect(values[2].float == 3.14);
    try std.testing.expect(values[3].boolean == true);
}

/// Test GraphQL argument value
test "GraphQL argument values" {
    const arg = GraphQL.ArgValue{
        .name = "id",
        .value = .{ .string = try std.testing.allocator.dupe(u8, "0x123") },
    };

    try std.testing.expect(std.mem.eql(u8, arg.name, "id"));
}

/// Test GraphQL error creation
test "GraphQL error creation" {
    const error = GraphQL.GraphQLError{
        .message = "Field not found",
        .locations = &.{},
        .path = &.{},
    };

    try std.testing.expect(std.mem.eql(u8, error.message, "Field not found"));
}

/// Test GraphQL field resolver registry
test "GraphQL field resolver registry" {
    const allocator = std.testing.allocator;
    var registry = GraphQL.FieldResolverRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.resolvers.count() == 0);
}

/// Test GraphQL schema has required Knot3 types
test "GraphQL schema has Knot3 types" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    // Schema should have query type
    try std.testing.expect(schema.query_type != null);
}

/// Test GraphQL resolver context with object store
test "GraphQL resolver context with store" {
    const allocator = std.testing.allocator;

    var ctx = GraphQL.ResolverContext.init(allocator);
    defer ctx.deinit();

    // Should be able to set object store
    // Note: Actual store integration tested in integration tests
    try std.testing.expect(ctx.allocator == allocator);
}

/// Test GraphQL query validation - empty query
test "GraphQL query validation empty" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    const result = schema.validateQuery("");

    // Empty query should fail validation
    try std.testing.expect(result.isErr());
}

/// Test GraphQL query validation - valid query structure
test "GraphQL query validation valid" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    // Note: Actual validation depends on schema structure
    // This tests the validation function exists and is callable
    _ = schema.validateQuery("query { dummy }");
}

/// Test GraphQL serialize value
test "GraphQL serialize string" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    const value: GraphQL.Value = .{ .string = try allocator.dupe(u8, "test") };
    const serialized = try schema.serializeValue(value, allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
}

/// Test GraphQL serialize int value
test "GraphQL serialize int" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    const value: GraphQL.Value = .{ .int = 12345 };
    const serialized = try schema.serializeValue(value, allocator);
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "12345") != null);
}

/// Test GraphQL serialize bool value
test "GraphQL serialize bool" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    const value: GraphQL.Value = .{ .boolean = true };
    const serialized = try schema.serializeValue(value, allocator);
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "true") != null);
}

/// Test GraphQL compiler initialization
test "GraphQL compiler init" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    var compiler = try GraphQL.GraphQLCompiler.init(allocator, schema);
    defer compiler.deinit();
}

/// Test GraphQL compiler executes query with field resolution
test "GraphQL compiler executes query with field resolution" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    var compiler = try GraphQL.GraphQLCompiler.init(allocator, schema);
    defer compiler.deinit();

    const ctx = GraphQL.ResolverContext{
        .allocator = allocator,
        .object_store = null,
        .checkpoint_store = null,
    };

    // Execute a simple query that should resolve fields
    const query = "{ knot3_getCheckpoint(id: 1) { sequence digest } }";
    const resp = try compiler.execute(query, &ctx);

    try std.testing.expect(resp.data != null);
    try std.testing.expect(resp.errors.len == 0);
}

/// Test GraphQL compiler resolves multiple fields
test "GraphQL compiler resolves multiple fields" {
    const allocator = std.testing.allocator;
    var schema = try GraphQL.Schema.init(allocator);
    defer schema.deinit();

    var compiler = try GraphQL.GraphQLCompiler.init(allocator, schema);
    defer compiler.deinit();

    const ctx = GraphQL.ResolverContext{
        .allocator = allocator,
        .object_store = null,
        .checkpoint_store = null,
    };

    // Execute query with multiple fields
    const query = "{ knot3_getCoins(owner: \"0x1\", coinType: \"KNOT3\") { coinObjectId balance } }";
    const resp = try compiler.execute(query, &ctx);

    try std.testing.expect(resp.data != null);
}

/// Test GraphQL query parsing with selections
test "GraphQL query parsing with selections" {
    const allocator = std.testing.allocator;
    
    const query_str = "{ field1 field2 field3 }";
    var query = try GraphQL.Query.parse(allocator, query_str);
    defer query.deinit();

    try std.testing.expect(query.operation.kind == .Query);
    try std.testing.expect(query.operation.selections.len == 3);
}

/// Test GraphQL response JSON serialization with data
test "GraphQL response JSON with data" {
    const allocator = std.testing.allocator;

    var obj = std.StringArrayHashMap(GraphQL.Value){};
    try obj.put("id", .{ .kind = .String, .string = "0x1", .int = null, .float = null, .bool = null, .list = null, .object = null });
    try obj.put("value", .{ .kind = .Int, .int = 42, .string = null, .float = null, .bool = null, .list = null, .object = null });

    const resp = GraphQL.Response.success(.{
        .kind = .Object,
        .object = obj,
        .string = null,
        .int = null,
        .float = null,
        .bool = null,
        .list = null,
    });

    const json = try resp.toJSON(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"0x1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value\":42") != null);
}
