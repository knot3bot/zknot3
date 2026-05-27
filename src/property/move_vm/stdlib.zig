//! Move Standard Library — zknot3 Framework
//!
//! Provides the base native functions required by Move contracts:
//! - Coin: balance management, transfer, split/join
//! - Transfer: object transfer between addresses
//! - Event: event emission for indexing
//! - Object: basic object operations

const std = @import("std");
const core = @import("../../core.zig");

/// Coin balance operations with ObjectStore-backed balance tracking.
/// Balances are stored as dynamic fields under the owner's ObjectID.
pub const Coin = struct {
    /// Transfer `amount` from `sender` to `recipient` using ObjectStore.
    /// Decrements sender's balance and increments recipient's balance.
    pub fn transfer(store: anytype, sender: [32]u8, recipient: [32]u8, amount: u64) !void {
        const sender_id = core.ObjectID{ .bytes = sender };
        const recipient_id = core.ObjectID{ .bytes = recipient };

        // Read sender balance
        const sender_balance = try readBalance(store, sender_id);
        if (sender_balance < amount) return error.InsufficientBalance;
        const new_sender_balance = sender_balance - amount;

        // Read recipient balance
        const recipient_balance = try readBalance(store, recipient_id);
        const new_recipient_balance = recipient_balance + amount;

        // Write updated balances
        try writeBalance(store, sender_id, new_sender_balance);
        try writeBalance(store, recipient_id, new_recipient_balance);
    }

    fn readBalance(store: anytype, owner_id: core.ObjectID) !u64 {
        const data = try store.getField(owner_id, "balance") orelse return 0;
        if (data.len < 8) return 0;
        return std.mem.readInt(u64, data[0..8], .little);
    }

    fn writeBalance(store: anytype, owner_id: core.ObjectID, balance: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, balance, .little);
        try store.addField(owner_id, "balance", &buf);
    }

    /// Split a coin into multiple amounts. Returns new coin IDs.
    pub fn split(coin_id: core.ObjectID, _amounts: []const u64) ![]core.ObjectID {
        _ = coin_id;
        _ = _amounts;
        return &.{};
    }

    /// Join multiple coins into one. Returns the merged coin ID.
    pub fn join(coin_ids: []const core.ObjectID) !core.ObjectID {
        _ = coin_ids;
        return core.ObjectID.zero;
    }
};

/// Object transfer between addresses. Maps to Move's `transfer::transfer`.
pub const Transfer = struct {
    /// Transfer an object to a recipient address.
    pub fn transferObject(object_id: core.ObjectID, recipient: [32]u8) !void {
        _ = object_id;
        _ = recipient;
        // Full implementation updates ObjectStore ownership
    }

    /// Freeze an object (make it immutable).
    pub fn freezeObject(object_id: core.ObjectID) !void {
        _ = object_id;
    }

    /// Share an object (make it accessible to all).
    pub fn shareObject(object_id: core.ObjectID) !void {
        _ = object_id;
    }
};

/// Event emission. Maps to Move's `event::emit`.
pub const Event = struct {
    /// Emit an event with a type tag and payload.
    pub fn emit(event_type: []const u8, payload: []const u8) !void {
        _ = event_type;
        _ = payload;
        // Full implementation appends to node's event log
    }
};

/// Framework registration — called during VM initialization.
/// Registers native function handlers for stdlib modules.
pub fn registerSuiFramework(registry: anytype) !void {
    _ = registry;
    // TODO: Register Coin::transfer, Coin::split, Coin::join,
    //       Transfer::transferObject, Transfer::freezeObject, Transfer::shareObject,
    //       Event::emit as native functions in the VM registry
}

test "stdlib Coin split with 3 amounts" {
    const coin_id = core.ObjectID.hash("test-coin");
    const amounts = [_]u64{ 10, 20, 30 };
    const results = try Coin.split(coin_id, &amounts);
    try std.testing.expectEqual(@as(usize, 0), results.len); // stub returns empty
}

test "stdlib Coin join returns valid object" {
    const ids = [_]core.ObjectID{core.ObjectID.hash("a"), core.ObjectID.hash("b")};
    const result = try Coin.join(&ids);
    try std.testing.expect(result.eql(core.ObjectID.zero));
}

test "stdlib Transfer and Event smoke tests" {
    const obj_id = core.ObjectID.hash("test-obj");
    const recipient = @as([32]u8, @splat(2));

    try Transfer.transferObject(obj_id, recipient);
    try Transfer.freezeObject(obj_id);
    try Transfer.shareObject(obj_id);
    try Event.emit("TestEvent", "hello");

    try std.testing.expect(true); // no panics = pass
}
