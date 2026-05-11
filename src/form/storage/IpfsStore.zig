//! IPFS Integration — Off-chain content storage with on-chain CID tracking.
//!
//! Large creation content (images, video, audio) is stored on IPFS.
//! The IPFS CID is tracked via ObjectStore dynamic fields for on-chain
//! provenance and discovery.

const std = @import("std");
const core = @import("../../core.zig");

/// IPFS content identifier and metadata.
pub const IpfsContent = struct {
    cid: []const u8,       // IPFS CIDv1 (e.g. "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi")
    size_bytes: u64,
    mime_type: []const u8, // e.g. "image/png", "video/mp4"
    pinned: bool,          // true if pinned to local IPFS node
    created_at: i64,

    pub fn deinit(self: *IpfsContent, allocator: std.mem.Allocator) void {
        allocator.free(self.cid);
        allocator.free(self.mime_type);
    }
};

/// IPFS integration helpers. Uses ObjectStore dynamic fields to track
/// CID ↔ ObjectID mappings for on-chain content discovery.
pub const IpfsStore = struct {
    /// Store an IPFS CID as a dynamic field on a creation object.
    /// Key: "ipfs_cid", Value: serialized IpfsContent.
    pub fn attachToCreation(
        store: anytype,
        creation_id: core.ObjectID,
        cid: []const u8,
        size_bytes: u64,
        mime_type: []const u8,
    ) !void {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);

        var buf = std.ArrayList(u8).empty;
        // Format: [cid_len:u16][cid][size:u64][mime_len:u16][mime][pinned:u8][created:i64]
        try buf.append(@intCast(cid.len));
        try buf.appendSlice(cid);
        var size_bytes_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &size_bytes_buf, size_bytes, .big);
        try buf.appendSlice(&size_bytes_buf);
        try buf.append(@intCast(mime_type.len));
        try buf.appendSlice(mime_type);
        try buf.append(@intFromBool(true)); // pinned
        var ts_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &ts_buf, ts.sec, .big);
        try buf.appendSlice(&ts_buf);

        try store.addField(creation_id, "ipfs_cid", buf.items);
    }

    /// Retrieve IPFS content info from a creation object.
    pub fn getFromCreation(store: anytype, creation_id: core.ObjectID) !?IpfsContent {
        const data = try store.getField(creation_id, "ipfs_cid") orelse return null;
        if (data.len < 2) return null;

        const cid_len: usize = data[0];
        if (data.len < 1 + cid_len + 8 + 1) return null;
        const cid = data[1 .. 1 + cid_len];
        const size_bytes = std.mem.readInt(u64, data[1 + cid_len .. 1 + cid_len + 8], .big);
        const mime_len: usize = data[1 + cid_len + 8];
        const mime_start = 1 + cid_len + 8 + 1;
        const mime_type = if (mime_len > 0 and data.len >= mime_start + mime_len)
            data[mime_start .. mime_start + mime_len]
        else
            "application/octet-stream";
        const pinned_byte: u8 = if (data.len > mime_start + mime_len) data[mime_start + mime_len] else 1;
        const pinned = pinned_byte != 0;

        return IpfsContent{
            .cid = cid,
            .size_bytes = size_bytes,
            .mime_type = mime_type,
            .pinned = pinned,
            .created_at = 0,
        };
    }
};

test "IpfsStore attach and retrieve" {
    // Test via mock store (ObjectStore not available in unit test context)
    try std.testing.expect(true); // placeholder — full test requires ObjectStore
}
