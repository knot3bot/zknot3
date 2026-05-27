//! Creator³ Marketplace — Creation Listings & Bids
//!
//! Enables creators to list their works for sale, buyers to purchase or bid,
//! and automatic royalty distribution on every sale.

const std = @import("std");
const core = @import("../../core.zig");

pub const Listing = struct {
    id: core.ObjectID,
    creation_id: core.ObjectID,
    seller: [32]u8,
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

    pub fn init(allocator: std.mem.Allocator) !*Marketplace {
        const self = try allocator.create(Marketplace);
        self.* = .{
            .allocator = allocator,
            .listings = .empty,
            .bids = .empty,
            .total_volume = 0,
            .total_royalties_paid = 0,
        };
        return self;
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
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const id = core.ObjectID.hash("listing");

        const listing = Listing{
            .id = id,
            .creation_id = creation_id,
            .seller = seller,
            .price = price,
            .currency = try self.allocator.dupe(u8, currency),
            .royalty_bps = royalty_bps,
            .created_at = ts.sec,
            .is_active = true,
        };
        try self.listings.put(self.allocator, id, listing);
        return id;
    }

    /// Buy a listed creation. Automatically distributes royalty.
    pub fn buy(self: *Marketplace, listing_id: core.ObjectID, buyer: [32]u8) !struct { creation_id: core.ObjectID, royalty_amount: u64 } {
        const listing = self.listings.getPtr(listing_id) orelse return error.ListingNotFound;
        if (!listing.is_active) return error.ListingNotActive;

        listing.is_active = false;
        self.total_volume += listing.price;

        const royalty_amount = (listing.price * listing.royalty_bps) / 10000;
        self.total_royalties_paid += royalty_amount;

        _ = buyer; // transfer ownership in full impl

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
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const id = core.ObjectID.hash("bid");

        const bid_entry = Bid{
            .id = id,
            .listing_id = listing_id,
            .bidder = bidder,
            .amount = amount,
            .created_at = ts.sec,
            .expires_at = ts.sec + duration_secs,
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

        listing.is_active = false;
        self.total_volume += best_bid.amount;
        const royalty = (best_bid.amount * listing.royalty_bps) / 10000;
        self.total_royalties_paid += royalty;

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
}
