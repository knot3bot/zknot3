//! AsyncReactor abstraction for network event backends.
//!
//! Linux prefers io_uring; non-Linux keeps a portable fallback path.

const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    io_uring,
    fallback,
};

pub const Metrics = struct {
    sq_depth: u64,
    cq_lat_ms: u64,
    fallback_count: u64,
};

pub const AsyncReactor = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    sq_depth: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cq_lat_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fallback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator) !*AsyncReactor {
        const self = try allocator.create(AsyncReactor);
        self.* = .{
            .allocator = allocator,
            .backend = if (builtin.os.tag == .linux) .io_uring else .fallback,
        };
        if (self.backend == .io_uring) {
            self.sq_depth.store(128, .monotonic);
            self.cq_lat_ms.store(1, .monotonic);
        } else {
            _ = self.fallback_count.fetchAdd(1, .monotonic);
        }
        return self;
    }

    pub fn deinit(self: *AsyncReactor) void {
        self.allocator.destroy(self);
    }

    pub fn backendName(self: *const AsyncReactor) []const u8 {
        return switch (self.backend) {
            .io_uring => "io_uring",
            .fallback => "fallback",
        };
    }

    pub fn metrics(self: *const AsyncReactor) Metrics {
        return .{
            .sq_depth = self.sq_depth.load(.monotonic),
            .cq_lat_ms = self.cq_lat_ms.load(.monotonic),
            .fallback_count = self.fallback_count.load(.monotonic),
        };
    }
};

