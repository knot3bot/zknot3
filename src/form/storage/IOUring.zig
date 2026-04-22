//! Async I/O compatibility wrapper for storage
//!
//! Provides cross-platform async I/O with automatic backend selection:
//! - Linux: currently uses synchronous pread/pwrite compatibility path
//! - macOS/Windows: thread_pool (good performance)
//! - Fallback: blocking I/O (works everywhere)

const std = @import("std");
const builtin = @import("builtin");

pub const OpType = enum(u8) {
    read,
    write,
    fsync,
    openat,
    close,
    statx,
};

pub const IoUringOp = enum(u8) {
    nop = 0,
    readv = 1,
    writev = 2,
    fsync = 3,
    openat = 4,
    close = 5,
    statx = 7,
};

pub const SQE = struct {
    opcode: u8,
    flags: u8,
    ioprio: u16,
    off: u64,
    addr: u64,
    len: u32,
    sqe_flags: u32,
    user_data: u64,

    pub fn init(op: IoUringOp) @This() {
        return .{
            .opcode = @intFromEnum(op),
            .flags = 0,
            .ioprio = 0,
            .off = 0,
            .addr = 0,
            .len = 0,
            .sqe_flags = 0,
            .user_data = 0,
        };
    }
};

pub const CQE = struct {
    user_data: u64,
    res: i32,
    flags: u32,

    pub fn isSuccess(self: @This()) bool {
        return self.res >= 0;
    }

    pub fn result(self: @This()) !usize {
        if (self.res < 0) {
            return error.IoError;
        }
        return @as(usize, @intCast(self.res));
    }
};

pub const RingState = struct {
    submitted: u32,
    completed: u32,
    err: ?anyerror,
};

pub const Config = struct {
    ring_size: u32 = 256,
    sqpoll: bool = false,
    poll_timeout_ms: u32 = 1000,
    fixed_buffers: bool = true,
    thread_pool_size: usize = 4,
};

pub const AsyncIO = struct {
    allocator: std.mem.Allocator,
    config: Config,
    backend: Backend,
    ring: ?std.os.linux.IoUring = null,

    pub const Backend = enum {
        io_uring,
        thread_pool,
        blocking,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*@This() {
        const self_ptr = try allocator.create(@This());
        self_ptr.* = .{
            .allocator = allocator,
            .config = config,
            .backend = undefined,
            .ring = null,
        };

        if (comptime builtin.os.tag == .linux) {
            // Prefer true io_uring path; gracefully fallback if unsupported.
            if (std.os.linux.IoUring.init(@intCast(config.ring_size), 0)) |ring| {
                self_ptr.backend = .io_uring;
                self_ptr.ring = ring;
            } else |_| {
                self_ptr.backend = .blocking;
            }
        } else if (comptime @hasDecl(std, "Thread") and @hasDecl(std.Thread, "Pool")) {
            self_ptr.backend = .thread_pool;
        } else {
            self_ptr.backend = .blocking;
        }

        return self_ptr;
    }

    pub fn deinit(self: *@This()) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.ring) |*ring| {
                ring.deinit();
                self.ring = null;
            }
        }
        self.allocator.destroy(self);
    }

    /// Submit an async read operation
    pub fn read(self: *@This(), fd: i32, buf: []u8, offset: u64) !usize {
        if (comptime builtin.os.tag == .linux) {
            if (self.backend == .io_uring and self.ring != null) {
                var ring = &self.ring.?;
                _ = try ring.read(1, fd, .{ .buffer = buf }, offset);
                _ = try ring.submit_and_wait(1);
                const cqe = try ring.copy_cqe();
                if (cqe.res < 0) return error.IoError;
                return @intCast(cqe.res);
            }
        }
        const rc = std.c.pread(fd, buf.ptr, buf.len, @intCast(offset));
        if (rc < 0) return error.IoError;
        return @intCast(rc);
    }

    /// Submit an async write operation
    pub fn write(self: *@This(), fd: i32, buf: []const u8, offset: u64) !usize {
        if (comptime builtin.os.tag == .linux) {
            if (self.backend == .io_uring and self.ring != null) {
                var ring = &self.ring.?;
                _ = try ring.write(2, fd, buf, offset);
                _ = try ring.submit_and_wait(1);
                const cqe = try ring.copy_cqe();
                if (cqe.res < 0) return error.IoError;
                return @intCast(cqe.res);
            }
        }
        const rc = std.c.pwrite(fd, buf.ptr, buf.len, @intCast(offset));
        if (rc < 0) return error.IoError;
        return @intCast(rc);
    }

    /// Submit an fsync operation for durability barriers.
    pub fn fsync(self: *@This(), fd: i32) !void {
        if (comptime builtin.os.tag == .linux) {
            if (self.backend == .io_uring and self.ring != null) {
                var ring = &self.ring.?;
                _ = try ring.fsync(3, fd, 0);
                _ = try ring.submit_and_wait(1);
                const cqe = try ring.copy_cqe();
                if (cqe.res < 0) return error.IoError;
                return;
            }
        }
        if (std.c.fsync(fd) != 0) return error.IoError;
        return;
    }

    /// Batched write request descriptor for `writeBatch`.
    pub const WriteOp = struct {
        fd: i32,
        buf: []const u8,
        offset: u64,
    };

    /// Batched read request descriptor for `readBatch`.
    pub const ReadOp = struct {
        fd: i32,
        buf: []u8,
        offset: u64,
    };

    /// Submit N writes as a single ring submission and wait for all CQEs in
    /// one `submit_and_wait(N)` round trip. `results[i]` receives the bytes
    /// written for `ops[i]` (or a negative errno-style value on failure, so
    /// callers may choose per-op fallback without aborting the whole batch).
    ///
    /// `results.len` must equal `ops.len`. Non-Linux / non-io_uring backends
    /// fall back to per-op `pwrite` loops with the same semantics.
    pub fn writeBatch(self: *@This(), ops: []const WriteOp, results: []isize) !void {
        if (ops.len == 0) return;
        if (ops.len != results.len) return error.LenMismatch;
        if (comptime builtin.os.tag == .linux) {
            if (self.backend == .io_uring and self.ring != null) {
                var ring = &self.ring.?;
                // Batch user_data range: [1000, 1000+N). Requires single-caller
                // invariant on the ring; this wrapper is synchronous per call.
                for (ops, 0..) |op, i| {
                    _ = try ring.write(1000 + @as(u64, @intCast(i)), op.fd, op.buf, op.offset);
                }
                _ = try ring.submit_and_wait(@intCast(ops.len));
                var pending: usize = ops.len;
                while (pending > 0) : (pending -= 1) {
                    const cqe = try ring.copy_cqe();
                    const idx = cqe.user_data - 1000;
                    if (idx >= ops.len) return error.UnexpectedCqe;
                    results[@intCast(idx)] = @intCast(cqe.res);
                }
                return;
            }
        }
        for (ops, 0..) |op, i| {
            const rc = std.c.pwrite(op.fd, op.buf.ptr, op.buf.len, @intCast(op.offset));
            results[i] = @intCast(rc);
        }
    }

    /// Symmetric counterpart of `writeBatch` for reads.
    pub fn readBatch(self: *@This(), ops: []const ReadOp, results: []isize) !void {
        if (ops.len == 0) return;
        if (ops.len != results.len) return error.LenMismatch;
        if (comptime builtin.os.tag == .linux) {
            if (self.backend == .io_uring and self.ring != null) {
                var ring = &self.ring.?;
                for (ops, 0..) |op, i| {
                    _ = try ring.read(2000 + @as(u64, @intCast(i)), op.fd, .{ .buffer = op.buf }, op.offset);
                }
                _ = try ring.submit_and_wait(@intCast(ops.len));
                var pending: usize = ops.len;
                while (pending > 0) : (pending -= 1) {
                    const cqe = try ring.copy_cqe();
                    const idx = cqe.user_data - 2000;
                    if (idx >= ops.len) return error.UnexpectedCqe;
                    results[@intCast(idx)] = @intCast(cqe.res);
                }
                return;
            }
        }
        for (ops, 0..) |op, i| {
            const rc = std.c.pread(op.fd, op.buf.ptr, op.buf.len, @intCast(op.offset));
            results[i] = @intCast(rc);
        }
    }

    /// Gathered durable write: submits `pwritev` for the scattered iovecs and
    /// links an `fsync` so both complete in one `submit_and_wait(2)`. Skips
    /// the caller-side "concat into one buffer then single write" memcpy that
    /// hot paths like `WAL.appendRecord` previously performed.
    ///
    /// Returns the number of bytes written across all iovecs (must equal the
    /// sum of `iov.len` for WAL callers). Non-Linux falls back to sequential
    /// `pwrite` per segment + one `fsync`.
    pub fn writevAndFsync(
        self: *@This(),
        fd: i32,
        iovecs: []const std.posix.iovec_const,
        offset: u64,
    ) !usize {
        if (iovecs.len == 0) {
            try self.fsync(fd);
            return 0;
        }
        if (comptime builtin.os.tag == .linux) {
            if (self.backend == .io_uring and self.ring != null) {
                var ring = &self.ring.?;
                const wv_sqe = try ring.writev(20, fd, iovecs, offset);
                wv_sqe.link_next();
                _ = try ring.fsync(21, fd, 0);
                _ = try ring.submit_and_wait(2);
                const cqe_a = try ring.copy_cqe();
                const cqe_b = try ring.copy_cqe();
                const wv_res = if (cqe_a.user_data == 20) cqe_a.res else cqe_b.res;
                const fs_res = if (cqe_a.user_data == 21) cqe_a.res else cqe_b.res;
                if (wv_res < 0) return error.IoError;
                if (fs_res < 0) return error.IoError;
                return @intCast(wv_res);
            }
        }
        // Portable fallback: pwrite each segment at incrementing offsets, then
        // one fsync. Matches the durability contract of the io_uring path.
        var cur = offset;
        var total: usize = 0;
        for (iovecs) |iov| {
            const rc = std.c.pwrite(fd, iov.base, iov.len, @intCast(cur));
            if (rc < 0) return error.IoError;
            const n: usize = @intCast(rc);
            total += n;
            cur += n;
            if (n != iov.len) return error.ShortWrite;
        }
        if (std.c.fsync(fd) != 0) return error.IoError;
        return total;
    }

    /// Durability barrier combining write + fsync as a single ring submission.
    ///
    /// On io_uring backend, submits a linked (IOSQE_IO_LINK) WRITE → FSYNC pair and
    /// waits for both completions in one `submit_and_wait(2)` round trip, cutting
    /// one syscall vs issuing them back-to-back. On blocking/thread-pool backends,
    /// falls back to pwrite + fsync sequentially so callers see identical semantics.
    ///
    /// Returns the number of bytes written (must equal `buf.len` for WAL callers).
    pub fn writeAndFsync(self: *@This(), fd: i32, buf: []const u8, offset: u64) !usize {
        if (comptime builtin.os.tag == .linux) {
            if (self.backend == .io_uring and self.ring != null) {
                var ring = &self.ring.?;
                const write_sqe = try ring.write(10, fd, buf, offset);
                write_sqe.link_next();
                _ = try ring.fsync(11, fd, 0);
                _ = try ring.submit_and_wait(2);
                const cqe_write = try ring.copy_cqe();
                const cqe_fsync = try ring.copy_cqe();
                // Order of CQEs is not guaranteed by kernel; match on user_data.
                const write_res = if (cqe_write.user_data == 10) cqe_write.res else cqe_fsync.res;
                const fsync_res = if (cqe_write.user_data == 11) cqe_write.res else cqe_fsync.res;
                if (write_res < 0) return error.IoError;
                // IOSQE_IO_LINK cancels downstream ops on upstream failure: fsync_res
                // may be -ECANCELED. We already bailed above if the write failed.
                if (fsync_res < 0) return error.IoError;
                return @intCast(write_res);
            }
        }
        const wrc = std.c.pwrite(fd, buf.ptr, buf.len, @intCast(offset));
        if (wrc < 0) return error.IoError;
        if (std.c.fsync(fd) != 0) return error.IoError;
        return @intCast(wrc);
    }

    /// Check if using native io_uring
    pub fn isIoUring(self: @This()) bool {
        return self.backend == .io_uring;
    }

    /// Check if using thread pool
    pub fn isThreadPool(self: @This()) bool {
        return self.backend == .thread_pool;
    }
};

pub const AsyncFile = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    aio: *AsyncIO,
    path: []const u8,

    pub fn open(allocator: std.mem.Allocator, aio: *AsyncIO, path: []const u8, flags: u32) !*@This() {
        const self_ptr = try allocator.create(@This());
        errdefer allocator.destroy(self_ptr);

        const fd = try std.posix.open(path, flags, .{});
        self_ptr.* = .{
            .allocator = allocator,
            .fd = fd,
            .aio = aio,
            .path = try allocator.dupe(u8, path),
        };

        return self_ptr;
    }

    pub fn close(self: *@This()) void {
        std.posix.close(self.fd);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn read(self: *@This(), buf: []u8, offset: u64) !usize {
        return self.aio.read(self.fd, buf, offset);
    }

    pub fn write(self: *@This(), buf: []const u8, offset: u64) !usize {
        return self.aio.write(self.fd, buf, offset);
    }
};

pub const IOUring = AsyncIO;

/// Check if native io_uring is supported on this platform
pub fn isSupported() bool {
    return builtin.os.tag == .linux;
}

/// Check if io_uring is actually available (kernel support check would go here)
pub fn isAvailable() bool {
    return builtin.os.tag == .linux;
}

/// Get a human-readable description of the I/O backend being used
pub fn version() []const u8 {
    if (builtin.os.tag == .linux) {
        return "io_uring (with blocking fallback)";
    } else if (comptime @hasDecl(std, "Thread") and @hasDecl(std.Thread, "Pool")) {
        return "thread_pool (cross-platform async I/O)";
    } else {
        return "blocking I/O (portable fallback)";
    }
}

/// Get the name of the backend in use
pub fn getBackendName(aio: *const AsyncIO) []const u8 {
    return switch (aio.backend) {
        .io_uring => "io_uring",
        .thread_pool => "thread_pool",
        .blocking => "blocking",
    };
}

/// Get recommended I/O configuration for the current platform
pub fn getRecommendedConfig() Config {
    if (builtin.os.tag == .linux) {
        return .{
            .ring_size = 256,
            .sqpoll = false,
            .poll_timeout_ms = 1000,
            .fixed_buffers = true,
            .thread_pool_size = 4,
        };
    } else if (comptime @hasDecl(std, "Thread") and @hasDecl(std.Thread, "Pool")) {
        return .{
            .ring_size = 0,
            .thread_pool_size = 4,
        };
    } else {
        return .{
            .thread_pool_size = 1,
        };
    }
}

test "io_uring availability" {
    _ = isSupported();
}

test "AsyncIO backend detection" {
    const allocator = std.testing.allocator;
    const config = Config{ .ring_size = 32, .thread_pool_size = 2 };

    var aio = try AsyncIO.init(allocator, config);
    defer aio.deinit();

    const backend_name = getBackendName(aio);
    try std.testing.expect(backend_name.len > 0);
}

test "AsyncIO init/deinit" {
    const allocator = std.testing.allocator;
    const config = Config{};

    var aio = try AsyncIO.init(allocator, config);
    defer aio.deinit();

    try std.testing.expect(aio.config.ring_size == 256);
}

test "AsyncIO write/read roundtrip" {
    const allocator = std.testing.allocator;
    const config = Config{};
    var aio = try AsyncIO.init(allocator, config);
    defer aio.deinit();

    @import("io_instance").io = std.testing.io;
    const path = "/tmp/asyncio_roundtrip_test.bin";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true, .read = true });
    defer file.close(std.testing.io);
    const fd: i32 = file.handle;

    const payload = "hello-io-uring";
    const written = try aio.write(fd, payload, 0);
    try std.testing.expectEqual(payload.len, written);
    try aio.fsync(fd);

    var buf: [64]u8 = undefined;
    const read_n = try aio.read(fd, buf[0..payload.len], 0);
    try std.testing.expectEqual(payload.len, read_n);
    try std.testing.expectEqualStrings(payload, buf[0..payload.len]);
}

test "AsyncIO falls back to blocking on invalid ring size" {
    const allocator = std.testing.allocator;
    const config = Config{
        .ring_size = 3, // not power-of-two; io_uring init must fail
    };
    var aio = try AsyncIO.init(allocator, config);
    defer aio.deinit();

    if (builtin.os.tag == .linux) {
        try std.testing.expect(aio.backend == .blocking);
    }
}

test "Recommended config per platform" {
    const config = getRecommendedConfig();
    try std.testing.expect(config.thread_pool_size > 0);
}

test "AsyncIO writeBatch + readBatch roundtrip" {
    const allocator = std.testing.allocator;
    const config = Config{};
    var aio = try AsyncIO.init(allocator, config);
    defer aio.deinit();

    @import("io_instance").io = std.testing.io;
    const path = "/tmp/asyncio_batch_test.bin";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true, .read = true });
    defer file.close(std.testing.io);
    const fd: i32 = file.handle;

    const p0 = "AAAA";
    const p1 = "BBBB";
    const p2 = "CCCCCC";
    const write_ops = [_]AsyncIO.WriteOp{
        .{ .fd = fd, .buf = p0, .offset = 0 },
        .{ .fd = fd, .buf = p1, .offset = p0.len },
        .{ .fd = fd, .buf = p2, .offset = p0.len + p1.len },
    };
    var wres: [3]isize = undefined;
    try aio.writeBatch(&write_ops, &wres);
    try std.testing.expectEqual(@as(isize, p0.len), wres[0]);
    try std.testing.expectEqual(@as(isize, p1.len), wres[1]);
    try std.testing.expectEqual(@as(isize, p2.len), wres[2]);
    try aio.fsync(fd);

    var b0: [8]u8 = undefined;
    var b1: [8]u8 = undefined;
    var b2: [8]u8 = undefined;
    const read_ops = [_]AsyncIO.ReadOp{
        .{ .fd = fd, .buf = b0[0..p0.len], .offset = 0 },
        .{ .fd = fd, .buf = b1[0..p1.len], .offset = p0.len },
        .{ .fd = fd, .buf = b2[0..p2.len], .offset = p0.len + p1.len },
    };
    var rres: [3]isize = undefined;
    try aio.readBatch(&read_ops, &rres);
    try std.testing.expectEqualStrings(p0, b0[0..p0.len]);
    try std.testing.expectEqualStrings(p1, b1[0..p1.len]);
    try std.testing.expectEqualStrings(p2, b2[0..p2.len]);
}

test "AsyncIO writevAndFsync gathered write" {
    const allocator = std.testing.allocator;
    const config = Config{};
    var aio = try AsyncIO.init(allocator, config);
    defer aio.deinit();

    @import("io_instance").io = std.testing.io;
    const path = "/tmp/asyncio_writev_test.bin";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true, .read = true });
    defer file.close(std.testing.io);
    const fd: i32 = file.handle;

    const hdr = "HDR:";
    const key = "key-123";
    const val = "value-payload";
    const iovs = [_]std.posix.iovec_const{
        .{ .base = hdr.ptr, .len = hdr.len },
        .{ .base = key.ptr, .len = key.len },
        .{ .base = val.ptr, .len = val.len },
    };
    const total = hdr.len + key.len + val.len;
    const written = try aio.writevAndFsync(fd, &iovs, 0);
    try std.testing.expectEqual(total, written);

    var buf: [64]u8 = undefined;
    const n = try aio.read(fd, buf[0..total], 0);
    try std.testing.expectEqual(total, n);
    try std.testing.expectEqualStrings(hdr, buf[0..hdr.len]);
    try std.testing.expectEqualStrings(key, buf[hdr.len .. hdr.len + key.len]);
    try std.testing.expectEqualStrings(val, buf[hdr.len + key.len .. total]);
}

test "AsyncIO writeAndFsync roundtrip" {
    const allocator = std.testing.allocator;
    const config = Config{};
    var aio = try AsyncIO.init(allocator, config);
    defer aio.deinit();

    @import("io_instance").io = std.testing.io;
    const path = "/tmp/asyncio_writeandfsync_test.bin";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true, .read = true });
    defer file.close(std.testing.io);
    const fd: i32 = file.handle;

    // First segment at offset 0
    const a = "segment-A";
    const wa = try aio.writeAndFsync(fd, a, 0);
    try std.testing.expectEqual(a.len, wa);

    // Second segment appended without gap
    const b = "segment-BB";
    const wb = try aio.writeAndFsync(fd, b, a.len);
    try std.testing.expectEqual(b.len, wb);

    var buf: [64]u8 = undefined;
    const total = try aio.read(fd, buf[0 .. a.len + b.len], 0);
    try std.testing.expectEqual(a.len + b.len, total);
    try std.testing.expectEqualStrings(a, buf[0..a.len]);
    try std.testing.expectEqualStrings(b, buf[a.len .. a.len + b.len]);
}
