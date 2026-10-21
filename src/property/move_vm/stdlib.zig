//! Move Standard Library — zknot3 Framework
//!
//! High-level ObjectStore-oriented helpers for Coin / Transfer / Event.
//! VM-callable natives live in NativeFunction.Registry.registerSuiFramework
//! (CoinBalance, ObjectTransfer, EventEmitter). `registerSuiFramework` here
//! is a thin alias so call sites that go through stdlib are not no-ops.

const std = @import("std");
const core = @import("../../core.zig");
const NativeFunction = @import("NativeFunction.zig");

/// Coin balance operations with ObjectStore-backed balance tracking.
/// Balances are stored as dynamic fields under the owner's ObjectID.
pub const Coin = struct {
    /// Transfer `amount` from `sender` to `recipient` using ObjectStore.
    /// Decrements sender's balance and increments recipient's balance.
    pub fn transfer(store: anytype, sender: [32]u8, recipient: [32]u8, amount: u64) !void {
        const sender_id = core.ObjectID{ .bytes = sender };
        const recipient_id = core.ObjectID{ .bytes = recipient };

        const sender_balance = try readBalance(store, sender_id);
        if (sender_balance < amount) return error.InsufficientBalance;
        const new_sender_balance = sender_balance - amount;

        const recipient_balance = try readBalance(store, recipient_id);
        const new_recipient_balance, const overflow = @addWithOverflow(recipient_balance, amount);
        if (overflow != 0) return error.BalanceOverflow;

        try writeBalance(store, sender_id, new_sender_balance);
        try writeBalance(store, recipient_id, new_recipient_balance);
    }

    fn readBalance(store: anytype, owner_id: core.ObjectID) !u64 {
        const data = try store.getField(owner_id, "balance") orelse return 0;
        defer store.allocator.free(data);
        if (data.len < 8) return 0;
        return std.mem.readInt(u64, data[0..8], .little);
    }

    fn writeBalance(store: anytype, owner_id: core.ObjectID, balance: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, balance, .little);
        try store.addField(owner_id, "balance", &buf);
    }

    /// Split `coin_id`'s balance field into new coin IDs for each amount.
    /// Decrements the source balance; each new ID gets a `balance` field.
    /// Caller owns the returned slice (`allocator`).
    pub fn split(
        store: anytype,
        allocator: std.mem.Allocator,
        coin_id: core.ObjectID,
        amounts: []const u64,
    ) ![]core.ObjectID {
        if (amounts.len == 0) return error.EmptySplit;

        var total: u64 = 0;
        for (amounts) |a| {
            const next, const overflow = @addWithOverflow(total, a);
            if (overflow != 0) return error.BalanceOverflow;
            total = next;
        }

        const source = try readBalance(store, coin_id);
        if (source < total) return error.InsufficientBalance;

        try writeBalance(store, coin_id, source - total);

        const ids = try allocator.alloc(core.ObjectID, amounts.len);
        errdefer allocator.free(ids);

        for (amounts, 0..) |amount, i| {
            var seed: [48]u8 = undefined;
            @memcpy(seed[0..32], coin_id.asBytes());
            std.mem.writeInt(u64, seed[32..40], @as(u64, @intCast(i)), .little);
            std.mem.writeInt(u64, seed[40..48], amount, .little);
            ids[i] = core.ObjectID.hash(&seed);
            try writeBalance(store, ids[i], amount);
        }
        return ids;
    }

    /// Join balances of `coin_ids` into the first coin; zero the rest.
    /// Returns the surviving (first) coin ID.
    pub fn join(store: anytype, coin_ids: []const core.ObjectID) !core.ObjectID {
        if (coin_ids.len == 0) return error.EmptyJoin;

        var total: u64 = 0;
        for (coin_ids) |id| {
            const bal = try readBalance(store, id);
            const next, const overflow = @addWithOverflow(total, bal);
            if (overflow != 0) return error.BalanceOverflow;
            total = next;
        }

        try writeBalance(store, coin_ids[0], total);
        for (coin_ids[1..]) |id| {
            try writeBalance(store, id, 0);
        }
        return coin_ids[0];
    }
};

/// Object transfer between addresses. Maps to Move's `transfer::transfer`.
/// Requires an ObjectStore-like `store` with `get` / `put` / `allocator`.
pub const Transfer = struct {
    /// Transfer an object to a recipient address (Owned → Owned).
    pub fn transferObject(store: anytype, object_id: core.ObjectID, recipient: [32]u8) !void {
        var obj = (try store.get(object_id)) orelse return error.ObjectNotFound;
        defer obj.deinit(store.allocator);
        if (!obj.ownership.isTransferable()) return error.NotTransferable;
        try store.put(.{
            .id = obj.id,
            .version = obj.version,
            .ownership = core.Ownership.ownedBy(recipient),
            .data = obj.data,
            .type_tag = obj.type_tag,
        });
    }

    /// Freeze an object (make it immutable).
    pub fn freezeObject(store: anytype, object_id: core.ObjectID) !void {
        var obj = (try store.get(object_id)) orelse return error.ObjectNotFound;
        defer obj.deinit(store.allocator);
        try store.put(.{
            .id = obj.id,
            .version = obj.version,
            .ownership = core.Ownership.immutable(),
            .data = obj.data,
            .type_tag = obj.type_tag,
        });
    }

    /// Share an object (make it accessible to all).
    pub fn shareObject(store: anytype, object_id: core.ObjectID) !void {
        var obj = (try store.get(object_id)) orelse return error.ObjectNotFound;
        defer obj.deinit(store.allocator);
        try store.put(.{
            .id = obj.id,
            .version = obj.version,
            .ownership = core.Ownership.shared(0),
            .data = obj.data,
            .type_tag = obj.type_tag,
        });
    }
};

/// Direct `event::emit` for a caller-owned log.
/// `log.appendEvent(event_type, payload)` borrows both slices; it does not
/// take ownership. An empty type is refused. Bytecode execution still records
/// events through `EventEmitter.nativeEmit` on the interpreter.
pub const Event = struct {
    pub fn emit(log: anytype, event_type: []const u8, payload: []const u8) !void {
        if (event_type.len == 0) return error.EmptyEventType;
        try log.appendEvent(event_type, payload);
    }
};

/// Thin alias onto `NativeFunction.Registry.registerSuiFramework`.
/// Node/Executor already call the Registry method directly; this keeps the
/// stdlib entrypoint from being a silent no-op when callers pass a Registry.
pub fn registerSuiFramework(registry: anytype) !void {
    try registry.registerSuiFramework();
}

// ---------------------------------------------------------------------------
// Tests (mock stores — no filesystem)
// ---------------------------------------------------------------------------

const MockFieldStore = struct {
    allocator: std.mem.Allocator,
    fields: std.StringHashMapUnmanaged([]u8) = .{},

    fn deinit(self: *MockFieldStore) void {
        var it = self.fields.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.fields.deinit(self.allocator);
    }

    fn fieldKey(self: *MockFieldStore, owner_id: core.ObjectID, name: []const u8) ![]u8 {
        const hex = std.fmt.bytesToHex(owner_id.bytes, .lower);
        return self.allocator.print("{s}:{s}", .{ &hex, name });
    }

    fn getField(self: *MockFieldStore, owner_id: core.ObjectID, name: []const u8) !?[]u8 {
        const key = try self.fieldKey(owner_id, name);
        defer self.allocator.free(key);
        const v = self.fields.get(key) orelse return null;
        return try self.allocator.dupe(u8, v);
    }

    fn addField(self: *MockFieldStore, owner_id: core.ObjectID, name: []const u8, value: []const u8) !void {
        const key = try self.fieldKey(owner_id, name);
        errdefer self.allocator.free(key);
        const val = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val);
        const gop = try self.fields.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = val;
        } else {
            gop.value_ptr.* = val;
        }
    }
};

const MockObj = struct {
    id: core.ObjectID,
    version: core.Version,
    ownership: core.Ownership,
    data: []u8,
    type_tag: u8,

    fn deinit(self: *MockObj, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

const MockObjStore = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged([32]u8, MockObj) = .{},

    fn deinit(self: *MockObjStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.value_ptr.data);
        }
        self.map.deinit(self.allocator);
    }

    fn get(self: *MockObjStore, id: core.ObjectID) !?MockObj {
        const existing = self.map.get(id.bytes) orelse return null;
        return .{
            .id = existing.id,
            .version = existing.version,
            .ownership = existing.ownership,
            .data = try self.allocator.dupe(u8, existing.data),
            .type_tag = existing.type_tag,
        };
    }

    fn put(self: *MockObjStore, object: MockObj) !void {
        const data = try self.allocator.dupe(u8, object.data);
        errdefer self.allocator.free(data);
        const gop = try self.map.getOrPut(self.allocator, object.id.bytes);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.data);
        }
        gop.value_ptr.* = .{
            .id = object.id,
            .version = object.version,
            .ownership = object.ownership,
            .data = data,
            .type_tag = object.type_tag,
        };
    }
};

test "stdlib registerSuiFramework wires NativeFunction registry" {
    const allocator = std.testing.allocator;
    var reg = NativeFunction.Registry.init(allocator);
    defer reg.deinit();

    try registerSuiFramework(&reg);

    try std.testing.expect(reg.resolve("sui", "coin::split") != null);
    try std.testing.expect(reg.resolve("sui", "coin::join") != null);
    try std.testing.expect(reg.resolve("sui", "transfer::public_transfer") != null);
    try std.testing.expect(reg.resolve("sui", "event::emit") != null);
    try std.testing.expect(reg.resolve("knot3", "coin::value") != null);
}

test "stdlib Coin split and join against field store" {
    const allocator = std.testing.allocator;
    var store = MockFieldStore{ .allocator = allocator };
    defer store.deinit();

    const coin_id = core.ObjectID.hash("test-coin");
    try Coin.writeBalance(&store, coin_id, 100);

    const amounts = [_]u64{ 10, 20, 30 };
    const parts = try Coin.split(&store, allocator, coin_id, &amounts);
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqual(@as(u64, 40), try Coin.readBalance(&store, coin_id));
    try std.testing.expectEqual(@as(u64, 10), try Coin.readBalance(&store, parts[0]));
    try std.testing.expectEqual(@as(u64, 20), try Coin.readBalance(&store, parts[1]));
    try std.testing.expectEqual(@as(u64, 30), try Coin.readBalance(&store, parts[2]));

    const merged = try Coin.join(&store, parts);
    try std.testing.expect(merged.eql(parts[0]));
    try std.testing.expectEqual(@as(u64, 60), try Coin.readBalance(&store, parts[0]));
    try std.testing.expectEqual(@as(u64, 0), try Coin.readBalance(&store, parts[1]));
    try std.testing.expectEqual(@as(u64, 0), try Coin.readBalance(&store, parts[2]));
}

test "stdlib Coin split rejects insufficient balance" {
    const allocator = std.testing.allocator;
    var store = MockFieldStore{ .allocator = allocator };
    defer store.deinit();

    const coin_id = core.ObjectID.hash("poor-coin");
    try Coin.writeBalance(&store, coin_id, 5);
    const amounts = [_]u64{ 10 };
    try std.testing.expectError(
        error.InsufficientBalance,
        Coin.split(&store, allocator, coin_id, &amounts),
    );
}

test "stdlib Transfer updates ownership and Event.emit records on the caller log" {
    const allocator = std.testing.allocator;
    var store = MockObjStore{ .allocator = allocator };
    defer store.deinit();

    const obj_id = core.ObjectID.hash("test-obj");
    const owner = @as([32]u8, @splat(1));
    const recipient = @as([32]u8, @splat(2));
    const data = try allocator.dupe(u8, "payload");
    defer allocator.free(data);

    try store.put(.{
        .id = obj_id,
        .version = .{ .seq = 1, .causal = @as([16]u8, @splat(0)) },
        .ownership = core.Ownership.ownedBy(owner),
        .data = data,
        .type_tag = 1,
    });

    try Transfer.transferObject(&store, obj_id, recipient);
    var after = (try store.get(obj_id)).?;
    defer after.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &recipient, &after.ownership.getOwner().?);

    try Transfer.freezeObject(&store, obj_id);
    var frozen = (try store.get(obj_id)).?;
    defer frozen.deinit(allocator);
    try std.testing.expect(frozen.ownership.tag == .Immutable);

    const Log = struct {
        event_type: []const u8 = "",
        payload: []const u8 = "",
        fn appendEvent(self: *@This(), event_type: []const u8, payload: []const u8) !void {
            self.event_type = event_type;
            self.payload = payload;
        }
    };
    var log = Log{};
    try std.testing.expectError(error.EmptyEventType, Event.emit(&log, "", "hello"));
    try Event.emit(&log, "TestEvent", "hello");
    try std.testing.expectEqualStrings("TestEvent", log.event_type);
    try std.testing.expectEqualStrings("hello", log.payload);
}
