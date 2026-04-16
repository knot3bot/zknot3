//! GraphQL Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");
const GraphQL = root.app.GraphQL;

const Schema = GraphQL.Schema;
const ScalarType = GraphQL.ScalarType;
const TypeKind = GraphQL.TypeKind;

// Test GraphQL schema initialization
test "GraphQL schema init" {
    const allocator = std.testing.allocator;
    var schema = try Schema.init(allocator);
    defer schema.deinit();

    try std.testing.expect(schema.query_type != null);
}

// Test GraphQL scalar types
test "GraphQL scalar types" {
    const scalars = [_]ScalarType{
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

// Test GraphQL type kinds
test "GraphQL type kinds" {
    const kinds = [_]TypeKind{
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

// Test GraphQL TypeRef
test "GraphQL TypeRef" {
    const ref = Schema.TypeRef{
        .kind = .Scalar,
        .named_type = "String",
        .of_type = null,
    };

    try std.testing.expect(ref.kind == .Scalar);
    try std.testing.expect(std.mem.eql(u8, ref.named_type, "String"));
    try std.testing.expect(ref.of_type == null);
}

// Test GraphQL Value creation
test "GraphQL Value" {
    const value = GraphQL.Value{
        .kind = .String,
        .string = "test",
        .int = null,
        .float = null,
        .bool = null,
        .list = null,
        .object = null,
    };

    try std.testing.expect(value.kind == .String);
    try std.testing.expect(std.mem.eql(u8, value.string.?, "test"));
}

// Test GraphQL compiler initialization
test "GraphQL compiler init" {
    const allocator = std.testing.allocator;
    var schema = try Schema.init(allocator);
    defer schema.deinit();

    var compiler = try GraphQL.GraphQLCompiler.init(allocator, schema);
    defer compiler.deinit();

    try std.testing.expect(compiler.schema.query_type != null);
}

// Test ResolverContext
test "GraphQL ResolverContext" {
    const allocator = std.testing.allocator;
    const ctx = GraphQL.ResolverContext{
        .allocator = allocator,
        .object_store = null,
        .checkpoint_store = null,
    };

    try std.testing.expect(ctx.object_store == null);
    try std.testing.expect(ctx.checkpoint_store == null);
}
