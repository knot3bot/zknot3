//! GraphQL Tests for zknot3

const std = @import("std");
const root = @import("../../src/root.zig");
const GraphQL = root.app.GraphQL;
const ClientSDK = root.app.ClientSDK;
const RPC = root.form.network.RPC;

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
        .node = null,
    };

    try std.testing.expect(ctx.object_store == null);
    try std.testing.expect(ctx.checkpoint_store == null);
    try std.testing.expect(ctx.node == null);
}

fn hasField(fields: []const GraphQL.Schema.FieldDefinition, name: []const u8) bool {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

fn findField(fields: []const GraphQL.Schema.FieldDefinition, name: []const u8) ?GraphQL.Schema.FieldDefinition {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

test "M4 GraphQL contract alignment" {
    const allocator = std.testing.allocator;
    var schema = try Schema.init(allocator);
    defer schema.deinit();

    const query_type = schema.types.get("Query") orelse return error.QueryTypeMissing;
    try std.testing.expect(hasField(query_type.fields, "knot3_getCheckpointProof"));

    const mutation_type = schema.types.get("Mutation") orelse return error.MutationTypeMissing;
    try std.testing.expect(hasField(mutation_type.fields, "knot3_submitStakeOperation"));
    try std.testing.expect(hasField(mutation_type.fields, "knot3_submitGovernanceProposal"));

    const proof_type = schema.types.get("CheckpointProof") orelse return error.CheckpointProofTypeMissing;
    try std.testing.expect(hasField(proof_type.fields, "stateRoot"));
}

test "M4 GraphQL SDL uses NonNull for checkpoint proof args and receipt fields" {
    const allocator = std.testing.allocator;
    var schema = try Schema.init(allocator);
    defer schema.deinit();

    const query_type = schema.types.get("Query") orelse return error.QueryTypeMissing;
    const proof_field = findField(query_type.fields, "knot3_getCheckpointProof") orelse return error.FieldMissing;
    const seq_arg = for (proof_field.args) |a| {
        if (std.mem.eql(u8, a.name, "sequence")) break a;
    } else return error.ArgMissing;
    const obj_arg = for (proof_field.args) |a| {
        if (std.mem.eql(u8, a.name, "objectId")) break a;
    } else return error.ArgMissing;

    const seq_sdl = try Schema.formatTypeRefSdl(allocator, seq_arg.type);
    defer allocator.free(seq_sdl);
    const obj_sdl = try Schema.formatTypeRefSdl(allocator, obj_arg.type);
    defer allocator.free(obj_sdl);
    try std.testing.expectEqualStrings("Int!", seq_sdl);
    try std.testing.expectEqualStrings("ID!", obj_sdl);

    const ret_sdl = try Schema.formatTypeRefSdl(allocator, proof_field.type);
    defer allocator.free(ret_sdl);
    try std.testing.expectEqualStrings("CheckpointProof!", ret_sdl);

    const stake_type = schema.types.get("StakeOperationReceipt") orelse return error.TypeMissing;
    const status_f = findField(stake_type.fields, "status") orelse return error.FieldMissing;
    const status_sdl = try Schema.formatTypeRefSdl(allocator, status_f.type);
    defer allocator.free(status_sdl);
    try std.testing.expectEqualStrings("String!", status_sdl);
}

test "M4 GraphQL RPC SDK contract alignment" {
    const allocator = std.testing.allocator;
    var schema = try Schema.init(allocator);
    defer schema.deinit();

    const query_type = schema.types.get("Query") orelse return error.QueryTypeMissing;
    try std.testing.expect(hasField(query_type.fields, "knot3_getCheckpointProof"));

    const mutation_type = schema.types.get("Mutation") orelse return error.MutationTypeMissing;
    try std.testing.expect(hasField(mutation_type.fields, "knot3_submitStakeOperation"));
    try std.testing.expect(hasField(mutation_type.fields, "knot3_submitGovernanceProposal"));

    const sdk_source = @embedFile("../../src/app/ClientSDK.zig");
    try std.testing.expect(std.mem.indexOf(u8, sdk_source, "knot3_getCheckpointProof") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_source, "knot3_submitStakeOperation") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_source, "knot3_submitGovernanceProposal") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_source, "\"validator\", \"delegator\", \"amount\", \"action\", \"metadata\"") != null);

    const rpc_source = @embedFile("../../src/form/network/RPC.zig");
    try std.testing.expect(std.mem.indexOf(u8, rpc_source, "knot3_getCheckpointProof") != null);
    try std.testing.expect(std.mem.indexOf(u8, rpc_source, "knot3_submitStakeOperation") != null);
    try std.testing.expect(std.mem.indexOf(u8, rpc_source, "knot3_submitGovernanceProposal") != null);
}

test "ClientSDK and RPC compile smoke" {
    try std.testing.expect(ClientSDK.KNOT3_RPC_METHODS.len >= 3);

    var server = try RPC.RPCServer.init(std.testing.allocator);
    defer server.deinit();
    try std.testing.expect(server.context.user_data == null);
}
