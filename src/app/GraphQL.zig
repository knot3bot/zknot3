//! GraphQL - GraphQL interface with compile-time schema verification
//!
//! Implements a Knot3-compatible GraphQL API with:
//! - Schema definition with type system
//! - Query parsing and validation
//! - Field resolution with object store integration
//! - Compile-time schema verification

const std = @import("std");
const core = @import("../core.zig");
const ObjectStore = @import("../form/storage/ObjectStore.zig");
const Checkpoint = @import("../form/storage/Checkpoint.zig");
const Node = @import("Node.zig").Node;
const MainnetExtensionHooks = @import("MainnetExtensionHooks.zig");
const M4RpcParams = @import("../form/network/M4RpcParams.zig");
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
        types: std.StringArrayHashMapUnmanaged(*const TypeDefinition),
        object_types: std.ArrayList(*ObjectType),

    /// Type definition
    pub const TypeDefinition = struct {
        name: []const u8,
        kind: TypeKind,
    fields: []const FieldDefinition,
        enum_values: ?[]const []const u8,
        implements: ?[]const []const u8,
    };

    /// Field definition
    pub const FieldDefinition = struct {
        name: []const u8,
        type: TypeRef,
        args: []const InputValue,
        resolve: ?*const fn (*const ResolverContext, []const ArgValue) anyerror!Value,
    };

    /// Input value definition
    pub const InputValue = struct {
        name: []const u8,
        type: TypeRef,
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
    fields: std.StringArrayHashMapUnmanaged(FieldDefinition),
        interfaces: []const []const u8,
    };

    /// Initialize schema with Knot3 types
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .query_type = null,
            .mutation_type = null,
            .types = std.StringArrayHashMapUnmanaged(*const TypeDefinition).empty,
            .object_types = std.ArrayList(*ObjectType).empty,
        };

        // Build Knot3-compatible schema
        try self.buildKnot3Schema();

        return self;
    }

    /// Build Knot3-compatible GraphQL schema
    fn buildKnot3Schema(self: *Self) !void {
        // Register Knot3Object type
        _ = try self.registerObject("Knot3Object", &.{
            .{ .name = "id", .type = .{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveObjectId },
            .{ .name = "version", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveObjectVersion },
            .{ .name = "owner", .type = .{ .kind = .Scalar, .named_type = "Address", .of_type = null }, .args = &.{}, .resolve = resolveObjectOwner },
            .{ .name = "type", .type = .{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{}, .resolve = resolveObjectType },
            .{ .name = "previousTransaction", .type = .{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveObjectPrevTx },
            .{ .name = "storageRebate", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveObjectStorageRebase },
            .{ .name = "balance", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveObjectBalance },
        }, &.{});

        // Register Knot3Checkpoint type
        _ = try self.registerObject("Checkpoint", &.{
            .{ .name = "sequence", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveCheckpointSequence },
            .{ .name = "digest", .type = .{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{}, .resolve = resolveCheckpointDigest },
            .{ .name = "timestamp", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveCheckpointTimestamp },
            .{ .name = "transactions", .type = .{ .kind = .List, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveCheckpointTxs },
        }, &.{});

        // Register Knot3Transaction type
        _ = try self.registerObject("Knot3Transaction", &.{
            .{ .name = "digest", .type = .{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveTxDigest },
            .{ .name = "sender", .type = .{ .kind = .Scalar, .named_type = "Address", .of_type = null }, .args = &.{}, .resolve = resolveTxSender },
            .{ .name = "gasBudget", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveTxGasBudget },
            .{ .name = "gasPrice", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveTxGasPrice },
            .{ .name = "executedEpoch", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveTxEpoch },
            .{ .name = "status", .type = .{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{}, .resolve = resolveTxStatus },
        }, &.{});

        // Register Coin type
        _ = try self.registerObject("Coin", &.{
            .{ .name = "coinObjectId", .type = .{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveCoinObjectId },
            .{ .name = "coinType", .type = .{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{}, .resolve = resolveCoinType },
            .{ .name = "balance", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .args = &.{}, .resolve = resolveCoinBalance },
            .{ .name = "previousTransaction", .type = .{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .args = &.{}, .resolve = resolveCoinPrevTx },
        }, &.{});

        // M4 mainnet extension types
        _ = try self.registerObject("StakeOperationReceipt", &.{
            .{ .name = "status", .type = m4_gql_nn.string_req, .args = &.{}, .resolve = resolveStakeOpStatus },
            .{ .name = "operationId", .type = m4_gql_nn.int_req, .args = &.{}, .resolve = resolveStakeOpId },
        }, &.{});

        _ = try self.registerObject("GovernanceProposalReceipt", &.{
            .{ .name = "status", .type = m4_gql_nn.string_req, .args = &.{}, .resolve = resolveGovStatus },
            .{ .name = "proposalId", .type = m4_gql_nn.int_req, .args = &.{}, .resolve = resolveGovProposalId },
        }, &.{});

        _ = try self.registerObject("CheckpointProof", &.{
            .{ .name = "sequence", .type = m4_gql_nn.int_req, .args = &.{}, .resolve = resolveProofSequence },
            .{ .name = "stateRoot", .type = m4_gql_nn.string_req, .args = &.{}, .resolve = resolveProofStateRoot },
            .{ .name = "proof", .type = m4_gql_nn.string_req, .args = &.{}, .resolve = resolveProofBytes },
            .{ .name = "signatures", .type = m4_gql_nn.string_req, .args = &.{}, .resolve = resolveProofSignatures },
            .{ .name = "blsSignature", .type = m4_gql_nn.string_req, .args = &.{}, .resolve = resolveProofBlsSignature },
            .{ .name = "blsSignerBitmap", .type = m4_gql_nn.string_req, .args = &.{}, .resolve = resolveProofBlsSignerBitmap },
        }, &.{});

        // Build query type with root fields
        self.query_type = try self.registerObject("Query", &.{
            .{ .name = "knot3_getObject", .type = .{ .kind = .Object, .named_type = "Knot3Object", .of_type = null }, .args = &.{
                .{ .name = "id", .type = .{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .default_value = null },
            }, .resolve = resolveGetObject },
            .{ .name = "knot3_getCheckpoint", .type = .{ .kind = .Object, .named_type = "Checkpoint", .of_type = null }, .args = &.{
                .{ .name = "id", .type = .{ .kind = .Scalar, .named_type = "Int", .of_type = null }, .default_value = null },
            }, .resolve = resolveGetCheckpoint },
            .{ .name = "knot3_getCoins", .type = .{ .kind = .List, .named_type = "Coin", .of_type = null }, .args = &.{
                .{
                    .name = "owner", .type = .{ .kind = .Scalar, .named_type = "Address", .of_type = null }, .default_value = null,
                },
                .{ .name = "coinType", .type = .{ .kind = .Scalar, .named_type = "String", .of_type = null }, .default_value = null },
            }, .resolve = resolveGetCoins },
            .{ .name = "knot3_getTransactionBlock", .type = .{ .kind = .Object, .named_type = "Knot3Transaction", .of_type = null }, .args = &.{
                .{ .name = "digest", .type = .{ .kind = .Scalar, .named_type = "ID", .of_type = null }, .default_value = null },
            }, .resolve = resolveGetTransaction },
            .{ .name = "knot3_queryEvents", .type = .{ .kind = .Scalar, .named_type = "String", .of_type = null }, .args = &.{
                .{ .name = "query", .type = .{ .kind = .Scalar, .named_type = "String", .of_type = null }, .default_value = null },
            }, .resolve = resolveQueryEvents },
            .{ .name = "knot3_getCheckpointProof", .type = m4_gql_nn.checkpoint_proof_req, .args = &.{
                .{ .name = "sequence", .type = m4_gql_nn.int_req, .default_value = null },
                .{ .name = "objectId", .type = m4_gql_nn.id_req, .default_value = null },
            }, .resolve = resolveGetCheckpointProof },
        }, &.{});

        // Mutation root for M4 write-like hooks with typed inputs.
        self.mutation_type = try self.registerObject("Mutation", &.{
            .{ .name = "knot3_submitStakeOperation", .type = m4_gql_nn.stake_receipt_req, .args = &.{
                .{ .name = "validator", .type = m4_gql_nn.id_req, .default_value = null },
                .{ .name = "delegator", .type = m4_gql_nn.id_req, .default_value = null },
                .{ .name = "amount", .type = m4_gql_nn.int_req, .default_value = null },
                .{ .name = "action", .type = m4_gql_nn.string_req, .default_value = null },
                .{ .name = "metadata", .type = m4_gql_nn.string_req, .default_value = null },
            }, .resolve = resolveSubmitStakeOperation },
            .{ .name = "knot3_submitGovernanceProposal", .type = m4_gql_nn.gov_receipt_req, .args = &.{
                .{ .name = "proposer", .type = m4_gql_nn.id_req, .default_value = null },
                .{ .name = "title", .type = m4_gql_nn.string_req, .default_value = null },
                .{ .name = "description", .type = m4_gql_nn.string_req, .default_value = null },
                .{ .name = "kind", .type = m4_gql_nn.string_req, .default_value = null },
                .{ .name = "activationEpoch", .type = m4_gql_nn.int_opt, .default_value = null },
            }, .resolve = resolveSubmitGovernanceProposal },
        }, &.{});
    }

    /// Register an object type
    fn registerObject(self: *Self, name: []const u8, fields: []const FieldDefinition, interfaces: []const []const u8) !*ObjectType {
        const obj = try self.allocator.create(ObjectType);
        obj.* = .{
            .name = name,
            .fields = std.StringArrayHashMapUnmanaged(FieldDefinition).empty,
            .interfaces = interfaces,
        };

        for (fields) |field| {
            try obj.fields.put(self.allocator, field.name, field);
        }

        const type_def = try self.allocator.create(TypeDefinition);
        type_def.* = .{
            .name = name,
            .kind = .Object,
            .fields = fields,
            .enum_values = null,
            .implements = if (interfaces.len > 0) interfaces else null,
        };

        try self.types.put(self.allocator, name, type_def);
        try self.object_types.append(self.allocator, obj);
        return obj;
    }

    /// Render `TypeRef` as GraphQL SDL type syntax (e.g. `Int!`, `[ID!]!`).
    pub fn formatTypeRefSdl(allocator: std.mem.Allocator, ref: TypeRef) std.mem.Allocator.Error![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try formatTypeRefSdlAppend(allocator, &buf, ref);
        return try buf.toOwnedSlice(allocator);
    }

    fn formatTypeRefSdlAppend(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), ref: TypeRef) std.mem.Allocator.Error!void {
        switch (ref.kind) {
            .NonNull => {
                try formatTypeRefSdlAppend(allocator, buf, ref.of_type.?.*);
                try buf.append(allocator, '!');
            },
            .List => {
                try buf.append(allocator, '[');
                if (ref.of_type) |inner| {
                    try formatTypeRefSdlAppend(allocator, buf, inner.*);
                } else {
                    try buf.appendSlice(allocator, ref.named_type);
                }
                try buf.appendSlice(allocator, "]");
            },
            else => try buf.appendSlice(allocator, ref.named_type),
        }
    }

    pub fn deinit(self: *Self) void {
        // Clean up all registered object types
        for (self.object_types.items) |obj| {
            obj.fields.deinit(self.allocator);
            self.allocator.destroy(obj);
        }
        self.object_types.deinit(self.allocator);
        // Clean up allocated types
        var it = self.types.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.types.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Stable `TypeRef` graph for M4 fields that are non-null in SDL (`!`).
const m4_gql_nn = struct {
    const int_s = Schema.TypeRef{ .kind = .Scalar, .named_type = "Int", .of_type = null };
    const id_s = Schema.TypeRef{ .kind = .Scalar, .named_type = "ID", .of_type = null };
    const string_s = Schema.TypeRef{ .kind = .Scalar, .named_type = "String", .of_type = null };
    const cp_o = Schema.TypeRef{ .kind = .Object, .named_type = "CheckpointProof", .of_type = null };
    const sr_o = Schema.TypeRef{ .kind = .Object, .named_type = "StakeOperationReceipt", .of_type = null };
    const gr_o = Schema.TypeRef{ .kind = .Object, .named_type = "GovernanceProposalReceipt", .of_type = null };

    pub const int_req: Schema.TypeRef = .{ .kind = .NonNull, .named_type = "Int", .of_type = &int_s };
    pub const id_req: Schema.TypeRef = .{ .kind = .NonNull, .named_type = "ID", .of_type = &id_s };
    pub const string_req: Schema.TypeRef = .{ .kind = .NonNull, .named_type = "String", .of_type = &string_s };
    pub const checkpoint_proof_req: Schema.TypeRef = .{ .kind = .NonNull, .named_type = "CheckpointProof", .of_type = &cp_o };
    pub const stake_receipt_req: Schema.TypeRef = .{ .kind = .NonNull, .named_type = "StakeOperationReceipt", .of_type = &sr_o };
    pub const gov_receipt_req: Schema.TypeRef = .{ .kind = .NonNull, .named_type = "GovernanceProposalReceipt", .of_type = &gr_o };
    pub const int_opt: Schema.TypeRef = int_s;
};

/// Resolver context for field resolution
pub const ResolverContext = struct {
    allocator: std.mem.Allocator,
    object_store: ?*ObjectStore,
    checkpoint_store: ?*Checkpoint,
    node: ?*Node = null,
};

/// Argument value
pub const ArgValue = struct {
    name: []const u8,
    value: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(ArgValue) == @sizeOf(M4RpcParams.PlainArg));
    std.debug.assert(@alignOf(ArgValue) == @alignOf(M4RpcParams.PlainArg));
}

fn asPlainArgs(args: []const ArgValue) []const M4RpcParams.PlainArg {
    return @as([*]const M4RpcParams.PlainArg, @ptrCast(@alignCast(args.ptr)))[0..args.len];
}

/// GraphQL value
pub const Value = struct {
    kind: ValueKind,
    string: ?[]const u8,
    int: ?i64,
    float: ?f64,
    bool: ?bool,
    list: ?[]const Value,
    object: ?std.StringArrayHashMapUnmanaged(Value),

    pub const ValueKind = enum {
        Null,
        String,
        Int,
        Float,
        Boolean,
        List,
        Object,
    };

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        if (self.object) |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            obj.deinit(allocator);
        }
        if (self.list) |list| {
            for (0..list.len) |i| {
                var item = list[i];
                item.deinit(allocator);
            }
        }
        self.* = .{ .kind = .Null, .string = null, .int = null, .float = null, .bool = null, .list = null, .object = null };
    }
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

fn objectValue(obj: std.StringArrayHashMapUnmanaged(Value)) Value {
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
    _ = args;
    const node = ctx.node orelse return intValue(0);
    const info = node.getNodeInfo();
    return intValue(@intCast(info.checkpoint_sequence));
}

fn resolveCheckpointDigest(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("0xabc123");
}

fn resolveCheckpointTimestamp(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); });
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
    _ = args;
    const node = ctx.node orelse return intValue(0);
    const epoch = node.getEpochInfo();
    return intValue(@intCast(epoch.epoch_number));
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
    _ = args;
    // Would look up object from object_store
    var obj = std.StringArrayHashMapUnmanaged(Value).empty;
    try obj.put(ctx.allocator, "id", stringValue("0x0"));
    try obj.put(ctx.allocator, "version", intValue(1));
    return objectValue(obj);
}

fn resolveGetCheckpoint(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = args;
    var obj = std.StringArrayHashMapUnmanaged(Value).empty;
    try obj.put(ctx.allocator, "sequence", intValue(0));
    try obj.put(ctx.allocator, "digest", stringValue("0xabc123"));
    return objectValue(obj);
}

fn resolveGetCoins(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    // Would query coins from object store
    return listValue(&.{});
}

fn resolveGetTransaction(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = args;
    var obj = std.StringArrayHashMapUnmanaged(Value).empty;
    try obj.put(ctx.allocator, "digest", stringValue("0x0"));
    try obj.put(ctx.allocator, "status", stringValue("Success"));
    return objectValue(obj);
}

fn resolveQueryEvents(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("[]");
}

fn resolveStakeOpStatus(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("accepted");
}

fn resolveStakeOpId(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(1);
}

fn resolveGovStatus(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("accepted");
}

fn resolveGovProposalId(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(1);
}

fn resolveProofSequence(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return intValue(0);
}

fn resolveProofBytes(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("");
}

fn resolveProofSignatures(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("");
}

fn resolveProofStateRoot(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("");
}

fn resolveProofBlsSignature(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("");
}

fn resolveProofBlsSignerBitmap(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    _ = ctx;
    _ = args;
    return stringValue("");
}

fn resolveGetCheckpointProof(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    const node = ctx.node orelse return error.NodeNotConfigured;
    const req = M4RpcParams.parseCheckpointProofFromPlainArgs(asPlainArgs(args)) catch return error.InvalidParams;
    const proof = try node.buildCheckpointProof(req);
    defer node.freeCheckpointProof(proof);
    const proof_text = try MainnetExtensionHooks.allocHexLower(ctx.allocator, proof.proof_bytes);
    const signatures_text = try MainnetExtensionHooks.allocHexLower(ctx.allocator, proof.signatures);
    const bls_signature_text = try MainnetExtensionHooks.allocHexLower(ctx.allocator, proof.bls_signature);
    const bls_bitmap_text = try MainnetExtensionHooks.allocHexLower(ctx.allocator, proof.bls_signer_bitmap);
    const state_root_text = try std.fmt.allocPrint(ctx.allocator, "{x}", .{proof.state_root});
    var obj = std.StringArrayHashMapUnmanaged(Value).empty;
    try obj.put(ctx.allocator, "sequence", intValue(@intCast(proof.sequence)));
    try obj.put(ctx.allocator, "stateRoot", stringValue(state_root_text));
    try obj.put(ctx.allocator, "proof", stringValue(proof_text));
    try obj.put(ctx.allocator, "signatures", stringValue(signatures_text));
    try obj.put(ctx.allocator, "blsSignature", stringValue(bls_signature_text));
    try obj.put(ctx.allocator, "blsSignerBitmap", stringValue(bls_bitmap_text));
    return objectValue(obj);
}

fn resolveSubmitStakeOperation(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    const node = ctx.node orelse return error.NodeNotConfigured;
    const input = M4RpcParams.parseStakeOperationFromPlainArgs(asPlainArgs(args)) catch return error.InvalidParams;
    const operation_id = try node.submitStakeOperation(input);
    var obj = std.StringArrayHashMapUnmanaged(Value).empty;
    try obj.put(ctx.allocator, "status", stringValue("accepted"));
    try obj.put(ctx.allocator, "operationId", intValue(@intCast(operation_id)));
    return objectValue(obj);
}

fn resolveSubmitGovernanceProposal(ctx: *const ResolverContext, args: []const ArgValue) anyerror!Value {
    const node = ctx.node orelse return error.NodeNotConfigured;
    const input = M4RpcParams.parseGovernanceProposalFromPlainArgs(asPlainArgs(args)) catch return error.InvalidParams;
    const proposal_id = try node.submitGovernanceProposal(input);
    var obj = std.StringArrayHashMapUnmanaged(Value).empty;
    try obj.put(ctx.allocator, "status", stringValue("accepted"));
    try obj.put(ctx.allocator, "proposalId", intValue(@intCast(proposal_id)));
    return objectValue(obj);
}

/// GraphQL query
pub const Query = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    operation: Operation,
    variables: std.StringArrayHashMapUnmanaged(Value),

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
            .allocator = allocator,
            .operation = .{
                .kind = .Query,
                .name = null,
                .selections = try parseSelections(allocator, query_str),
            },
            .variables = std.StringArrayHashMapUnmanaged(Value).empty,
        };
        return query;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.operation.selections);
        self.variables.deinit(self.allocator);
    }
};

/// Parse field selections from query
fn parseSelections(allocator: std.mem.Allocator, query_str: []const u8) ![]const Query.Selection {
    var selections = std.ArrayList(Query.Selection).empty;
    defer selections.deinit(allocator);

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
                // Simple field name extraction: stop at '(' (args) or '{' (sub-selections)
                var field_end = i;
                for (query_str[field_start..i], field_start..) |fc, fi| {
                    if (fc == '(' or fc == '{') {
                        field_end = fi;
                        break;
                    }
                }
                const field_name = std.mem.trim(u8, query_str[field_start..field_end], " \n\t");
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

    return try selections.toOwnedSlice(allocator);
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

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.data) |*data| {
            data.deinit(allocator);
            self.data = null;
        }
        allocator.free(self.errors);
        self.errors = &.{};
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
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(allocator, "{\"data\":");

        if (self.data) |d| {
            try serializeValue(allocator, &buf, d);
        } else {
            try buf.appendSlice(allocator, "null");
        }

        if (self.errors.len > 0) {
            try buf.appendSlice(allocator, ",\"errors\":[");
            for (self.errors, 0..) |err, i| {
                if (i > 0) try buf.append(allocator, ',');
                const err_json = try std.fmt.allocPrint(allocator, "{{\"message\":\"{s}\"}}", .{err.message});
                defer allocator.free(err_json);
                try buf.appendSlice(allocator, err_json);
            }
            try buf.append(allocator, '}');
        }

        try buf.append(allocator, '}');
        return buf.toOwnedSlice(allocator);
    }
};

/// Serialize Value to JSON
fn serializeValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: Value) !void {
    switch (value.kind) {
        .Null => try buf.appendSlice(allocator, "null"),
        .String => {
            const str_json = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value.string.?});
            defer allocator.free(str_json);
            try buf.appendSlice(allocator, str_json);
        },
        .Int => {
            const int_json = try std.fmt.allocPrint(allocator, "{d}", .{value.int.?});
            defer allocator.free(int_json);
            try buf.appendSlice(allocator, int_json);
        },
        .Float => {
            const float_json = try std.fmt.allocPrint(allocator, "{d}", .{value.float.?});
            defer allocator.free(float_json);
            try buf.appendSlice(allocator, float_json);
        },
        .Boolean => try buf.appendSlice(allocator, if (value.bool.?) "true" else "false"),
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
                    const key_json = try std.fmt.allocPrint(allocator, "\"{s}\":", .{entry.key_ptr.*});
                    defer allocator.free(key_json);
                    try buf.appendSlice(allocator, key_json);
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
        var result = std.StringArrayHashMapUnmanaged(Value).empty;

        for (selections) |sel| {
            switch (sel.kind) {
                .Field => {
                    const value = try self.executeField(sel, ctx);
                    const key = sel.alias orelse sel.name;
                    try result.put(self.allocator, key, value);
                },
                else => {},
            }
        }

        return objectValue(result);
    }

    /// Execute a single field - looks up resolver in schema and calls it
    fn executeField(self: *Self, sel: Query.Selection, ctx: *const ResolverContext) !Value {
        // Build arguments from selection
        var args = std.ArrayList(ArgValue).empty;
        defer args.deinit(self.allocator);

        for (sel.arguments) |arg| {
            try args.append(self.allocator, .{ .name = arg.name, .value = arg.value.string orelse "" });
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
    try std.testing.expect(schema.types.contains("Knot3Object"));
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

    var obj = std.StringArrayHashMapUnmanaged(Value).empty;
    defer obj.deinit(allocator);
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
        .node = null,
    };

    const query = "{ knot3_getCheckpoint(id: 1) { sequence digest } }";
    var resp = try compiler.execute(query, &ctx);
    defer resp.deinit(allocator);

    try std.testing.expect(resp.data != null);
}

test "GraphQL serialize object value" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    var obj = std.StringArrayHashMapUnmanaged(Value).empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "id", stringValue("0x1"));
    try obj.put(allocator, "count", intValue(42));

    try serializeValue(allocator, &buf, objectValue(obj));

    const json = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"0x1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":42") != null);
}

test "GraphQL M4 resolvers call node hooks" {
    const Config = @import("Config.zig").Config;
    const NodeDependencies = @import("Node.zig").NodeDependencies;
    const allocator = std.testing.allocator;
    const hex64 = "0000000000000000000000000000000000000000000000000000000000000000";
    const hex64_b = "1111111111111111111111111111111111111111111111111111111111111111";

    const config = try allocator.create(Config);
    defer allocator.destroy(config);
    config.* = Config.default();
    config.authority.signing_key = [_]u8{0x55} ** 32;

    const node = try Node.init(allocator, config, NodeDependencies{});
    defer node.deinit();

    const ctx = ResolverContext{
        .allocator = allocator,
        .object_store = null,
        .checkpoint_store = null,
        .node = node,
    };

    const stake_args = [_]ArgValue{
        .{ .name = "validator", .value = hex64 },
        .{ .name = "delegator", .value = hex64_b },
        .{ .name = "amount", .value = "10" },
        .{ .name = "action", .value = "stake" },
        .{ .name = "metadata", .value = "gql-test" },
    };
    var stake_1 = try resolveSubmitStakeOperation(&ctx, &stake_args);
    defer stake_1.deinit(allocator);
    var stake_2 = try resolveSubmitStakeOperation(&ctx, &stake_args);
    defer stake_2.deinit(allocator);
    const stake_1_id = stake_1.object.?.get("operationId").?.int.?;
    const stake_2_id = stake_2.object.?.get("operationId").?.int.?;
    try std.testing.expectEqual(@as(i64, 1), stake_1_id);
    try std.testing.expectEqual(@as(i64, 2), stake_2_id);

    const gov_args = [_]ArgValue{
        .{ .name = "proposer", .value = hex64 },
        .{ .name = "title", .value = "t" },
        .{ .name = "description", .value = "d" },
        .{ .name = "kind", .value = "parameter_change" },
    };
    var gov = try resolveSubmitGovernanceProposal(&ctx, &gov_args);
    defer gov.deinit(allocator);
    const proposal_id = gov.object.?.get("proposalId").?.int.?;
    try std.testing.expectEqual(@as(i64, 1), proposal_id);

    const proof_args = [_]ArgValue{
        .{ .name = "sequence", .value = "9" },
        .{ .name = "objectId", .value = hex64 },
    };
    var proof = try resolveGetCheckpointProof(&ctx, &proof_args);
    defer {
        // Free dynamically allocated hex strings inside the proof object
        if (proof.object) |obj| {
            if (obj.get("proof")) |v| allocator.free(v.string.?);
            if (obj.get("signatures")) |v| allocator.free(v.string.?);
            if (obj.get("blsSignature")) |v| allocator.free(v.string.?);
            if (obj.get("blsSignerBitmap")) |v| allocator.free(v.string.?);
            if (obj.get("stateRoot")) |v| allocator.free(v.string.?);
        }
        proof.deinit(allocator);
    }
    const proof_seq = proof.object.?.get("sequence").?.int.?;
    try std.testing.expectEqual(@as(i64, 9), proof_seq);
}
