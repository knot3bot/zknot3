//! Creator³ Marketplace — Creation Listings & Bids
//!
//! Enables creators to list their works for sale, buyers to purchase or bid,
//! and automatic royalty distribution on every sale.

const std = @import("std");
const core = @import("../../core.zig");
const LicenseFile = @import("License.zig");

fn saturatingAdd(total: u64, amount: u64) u64 {
    return std.math.add(u64, total, amount) catch std.math.maxInt(u64);
}

fn saturatingAddClock(clock_sec: i64, duration_secs: i64) i64 {
    return std.math.add(i64, clock_sec, duration_secs) catch if (duration_secs < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

pub const Listing = struct {
    id: core.ObjectID,
    creation_id: core.ObjectID,
    seller: [32]u8,
    buyer: ?[32]u8 = null,
    price: u64,
    currency: []const u8,
    royalty_bps: u16,
    created_at: i64,
    is_active: bool,

    pub fn deinit(self: *Listing, allocator: std.mem.Allocator) void {
        allocator.free(self.currency);
    }
};

pub const Bid = struct {
    id: core.ObjectID,
    listing_id: core.ObjectID,
    bidder: [32]u8,
    amount: u64,
    created_at: i64,
    expires_at: i64,
};

pub const Marketplace = struct {
    allocator: std.mem.Allocator,
    listings: std.AutoArrayHashMapUnmanaged(core.ObjectID, Listing),
    bids: std.AutoArrayHashMapUnmanaged(core.ObjectID, std.ArrayList(Bid)),
    total_volume: u64,
    total_royalties_paid: u64,
    /// Mixed into listing and bid ids so two records cannot share one key.
    next_seq: u64 = 0,
    /// Seconds stamped on new records. Callers set this from the epoch start.
    clock_sec: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) !*Marketplace {
        const self = try allocator.create(Marketplace);
        self.* = .{
            .allocator = allocator,
            .listings = .empty,
            .bids = .empty,
            .total_volume = 0,
            .total_royalties_paid = 0,
            .next_seq = 0,
            .clock_sec = 0,
        };
        return self;
    }

    pub fn setClock(self: *Marketplace, epoch_start_sec: i64) void {
        self.clock_sec = epoch_start_sec;
    }

    fn allocateId(self: *Marketplace, domain: []const u8, parts: []const []const u8) !core.ObjectID {
        const seq = self.next_seq;
        self.next_seq = std.math.add(u64, seq, 1) catch return error.ArithmeticOverflow;
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(domain);
        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, seq, .big);
        hasher.update(&seq_buf);
        for (parts) |part| hasher.update(part);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return .{ .bytes = out };
    }

    pub fn deinit(self: *Marketplace) void {
        var lit = self.listings.iterator();
        while (lit.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.listings.deinit(self.allocator);

        var bit = self.bids.iterator();
        while (bit.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.bids.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// List a creation for sale with automatic royalty.
    pub fn list(
        self: *Marketplace,
        seller: [32]u8,
        creation_id: core.ObjectID,
        price: u64,
        currency: []const u8,
        royalty_bps: u16,
    ) !core.ObjectID {
        var price_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &price_buf, price, .big);
        const id = try self.allocateId("listing", &.{ &seller, &creation_id.bytes, &price_buf });
        const currency_copy = try self.allocator.dupe(u8, currency);
        errdefer self.allocator.free(currency_copy);

        const listing = Listing{
            .id = id,
            .creation_id = creation_id,
            .seller = seller,
            .price = price,
            .currency = currency_copy,
            .royalty_bps = royalty_bps,
            .created_at = self.clock_sec,
            .is_active = true,
        };
        try self.listings.put(self.allocator, id, listing);
        return id;
    }

    /// Buy a listed creation. Automatically distributes royalty.
    pub fn buy(self: *Marketplace, listing_id: core.ObjectID, buyer: [32]u8) !struct { creation_id: core.ObjectID, royalty_amount: u64 } {
        const listing = self.listings.getPtr(listing_id) orelse return error.ListingNotFound;
        if (!listing.is_active) return error.ListingNotActive;
        if (std.mem.eql(u8, &buyer, &listing.seller)) return error.SelfPurchase;

        listing.buyer = buyer;
        listing.is_active = false;
        self.total_volume = saturatingAdd(self.total_volume, listing.price);

        const royalty_amount = LicenseFile.License.royaltyOf(listing.price, listing.royalty_bps);
        self.total_royalties_paid = saturatingAdd(self.total_royalties_paid, royalty_amount);

        return .{ .creation_id = listing.creation_id, .royalty_amount = royalty_amount };
    }

    /// Place a bid on a listing.
    pub fn bid(
        self: *Marketplace,
        listing_id: core.ObjectID,
        bidder: [32]u8,
        amount: u64,
        duration_secs: i64,
    ) !core.ObjectID {
        _ = self.listings.get(listing_id) orelse return error.ListingNotFound;
        var amount_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &amount_buf, amount, .big);
        const id = try self.allocateId("bid", &.{ &listing_id.bytes, &bidder, &amount_buf });

        const bid_entry = Bid{
            .id = id,
            .listing_id = listing_id,
            .bidder = bidder,
            .amount = amount,
            .created_at = self.clock_sec,
            .expires_at = saturatingAddClock(self.clock_sec, duration_secs),
        };

        const bid_list = try self.bids.getOrPutValue(self.allocator, listing_id, std.ArrayList(Bid).empty);
        try bid_list.value_ptr.append(self.allocator, bid_entry);
        return id;
    }

    /// Accept the highest bid on a listing. Auto royalty distribution.
    pub fn acceptBid(self: *Marketplace, listing_id: core.ObjectID) !struct { buyer: [32]u8, amount: u64, royalty: u64 } {
        const listing = self.listings.getPtr(listing_id) orelse return error.ListingNotFound;
        const bid_list = self.bids.getPtr(listing_id) orelse return error.NoBids;
        if (bid_list.items.len == 0) return error.NoBids;

        // Find highest bid
        var best_idx: usize = 0;
        for (bid_list.items, 0..) |b, i| {
            if (b.amount > bid_list.items[best_idx].amount) best_idx = i;
        }
        const best_bid = bid_list.items[best_idx];

        listing.buyer = best_bid.bidder;
        listing.is_active = false;
        self.total_volume = saturatingAdd(self.total_volume, best_bid.amount);
        const royalty = LicenseFile.License.royaltyOf(best_bid.amount, listing.royalty_bps);
        self.total_royalties_paid = saturatingAdd(self.total_royalties_paid, royalty);

        return .{ .buyer = best_bid.bidder, .amount = best_bid.amount, .royalty = royalty };
    }

    /// Get active listings.
    pub fn getActiveListings(self: *Marketplace) ![]Listing {
        var results = std.ArrayList(Listing).empty;
        var it = self.listings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.is_active) try results.append(self.allocator, entry.value_ptr.*);
        }
        return results.toOwnedSlice(self.allocator);
    }
};

test "Marketplace list and buy with royalty" {
    const allocator = std.testing.allocator;
    var mp = try Marketplace.init(allocator);
    defer mp.deinit();

    const seller = @as([32]u8, @splat(1));
    const creation = core.ObjectID.hash("artwork-1");

    const list_id = try mp.list(seller, creation, 1000, "KNOT", 500); // 5% royalty
    try std.testing.expect(!list_id.eql(core.ObjectID.zero));

    const buyer = @as([32]u8, @splat(2));
    const result = try mp.buy(list_id, buyer);
    try std.testing.expectEqual(@as(u64, 50), result.royalty_amount); // 5% of 1000
    try std.testing.expectEqual(@as(u64, 1000), mp.total_volume);

    const sold = mp.listings.get(list_id).?;
    try std.testing.expect(!sold.is_active);
    try std.testing.expectEqual(@as(?[32]u8, buyer), sold.buyer);
    try std.testing.expectError(error.ListingNotActive, mp.buy(list_id, buyer));

    const own_id = try mp.list(seller, core.ObjectID.hash("artwork-own"), 400, "KNOT", 100);
    try std.testing.expectError(error.SelfPurchase, mp.buy(own_id, seller));
    const own = mp.listings.get(own_id).?;
    try std.testing.expect(own.is_active);
    try std.testing.expectEqual(@as(?[32]u8, null), own.buyer);
}

test "Marketplace bid and accept" {
    const allocator = std.testing.allocator;
    var mp = try Marketplace.init(allocator);
    defer mp.deinit();

    const seller = @as([32]u8, @splat(1));
    const creation = core.ObjectID.hash("artwork-2");
    const list_id = try mp.list(seller, creation, 2000, "KNOT", 300);

    const bidder1 = @as([32]u8, @splat(2));
    const bidder2 = @as([32]u8, @splat(3));
    _ = try mp.bid(list_id, bidder1, 1800, 3600);
    _ = try mp.bid(list_id, bidder2, 2200, 3600);

    const accepted = try mp.acceptBid(list_id);
    try std.testing.expectEqual(@as(u64, 2200), accepted.amount);
    try std.testing.expectEqual(@as(u64, 66), accepted.royalty); // 3% of 2200
    try std.testing.expectEqual(@as(?[32]u8, bidder2), mp.listings.get(list_id).?.buyer);
}

test "Marketplace listings stay distinct and use the epoch clock" {
    const allocator = std.testing.allocator;
    var mp = try Marketplace.init(allocator);
    defer mp.deinit();
    mp.setClock(1_700_000_000);

    const seller = @as([32]u8, @splat(1));
    const first = try mp.list(seller, core.ObjectID.hash("a"), 1000, "KNOT", 500);
    const second = try mp.list(seller, core.ObjectID.hash("b"), 1000, "KNOT", 500);
    try std.testing.expect(!first.eql(second));
    try std.testing.expectEqual(@as(i64, 1_700_000_000), mp.listings.get(first).?.created_at);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), mp.listings.get(second).?.created_at);

    const active = try mp.getActiveListings();
    defer allocator.free(active);
    try std.testing.expectEqual(@as(usize, 2), active.len);

    const bid_id = try mp.bid(first, @as([32]u8, @splat(2)), 900, 60);
    try std.testing.expect(!bid_id.eql(first));
    try std.testing.expectEqual(@as(i64, 1_700_000_060), mp.bids.get(first).?.items[0].expires_at);
}

test "Marketplace volume saturates at the u64 limit" {
    const allocator = std.testing.allocator;
    var mp = try Marketplace.init(allocator);
    defer mp.deinit();

    const seller = @as([32]u8, @splat(1));
    const buyer = @as([32]u8, @splat(2));
    const price = std.math.maxInt(u64);
    const first = try mp.list(seller, core.ObjectID.hash("volume-a"), price, "KNOT", 0);
    _ = try mp.buy(first, buyer);
    const second = try mp.list(seller, core.ObjectID.hash("volume-b"), price, "KNOT", 0);
    _ = try mp.buy(second, buyer);
    try std.testing.expectEqual(price, mp.total_volume);
}

test "Marketplace bid expiry saturates at the i64 limits" {
    const allocator = std.testing.allocator;
    var mp = try Marketplace.init(allocator);
    defer mp.deinit();

    const seller = @as([32]u8, @splat(1));
    const bidder = @as([32]u8, @splat(2));
    mp.setClock(std.math.maxInt(i64) - 10);
    const list_id = try mp.list(seller, core.ObjectID.hash("expiry"), 1000, "KNOT", 0);
    _ = try mp.bid(list_id, bidder, 100, 100);
    try std.testing.expectEqual(std.math.maxInt(i64), mp.bids.get(list_id).?.items[0].expires_at);

    mp.setClock(std.math.minInt(i64) + 10);
    _ = try mp.bid(list_id, bidder, 200, -100);
    try std.testing.expectEqual(std.math.minInt(i64), mp.bids.get(list_id).?.items[1].expires_at);
}

test "Marketplace refuses to wrap its id sequence" {
    const allocator = std.testing.allocator;
    var mp = try Marketplace.init(allocator);
    defer mp.deinit();

    mp.next_seq = std.math.maxInt(u64);
    const seller = @as([32]u8, @splat(1));
    try std.testing.expectError(error.ArithmeticOverflow, mp.list(seller, core.ObjectID.hash("seq"), 1, "KNOT", 0));
    try std.testing.expectEqual(std.math.maxInt(u64), mp.next_seq);
    try std.testing.expectEqual(@as(usize, 0), mp.listings.count());
}
