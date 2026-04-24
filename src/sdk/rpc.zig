const std = @import("std");
const errors = @import("errors.zig");

pub const RpcConfig = struct {
    /// Request timeout in milliseconds.
    timeout_ms: u64 = 5000,
    /// Maximum number of retries for transient failures.
    max_retries: u32 = 3,
    /// Base backoff in milliseconds between retries.
    backoff_ms: u64 = 250,
    /// Maximum backoff in milliseconds (exponential cap).
    max_backoff_ms: u64 = 8000,
};

pub const RpcClient = struct {
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    config: RpcConfig,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, rpc_url: []const u8, config: RpcConfig, io: std.Io) RpcClient {
        return .{ .allocator = allocator, .rpc_url = rpc_url, .config = config, .io = io };
    }

    pub fn call(self: *const RpcClient, comptime T: type, method: []const u8, params_json: []const u8) !T {
        const body = try std.fmt.allocPrint(self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        defer self.allocator.free(body);

        var last_err: anyerror = error.Transport;
        var backoff = self.config.backoff_ms;

        var retry: u32 = 0;
        while (retry <= self.config.max_retries) : (retry += 1) {
            if (retry > 0) {
                const delay = @min(backoff, self.config.max_backoff_ms);
                const delay_ns = delay * std.time.ns_per_ms;
                var req: std.c.timespec = .{
                    .sec = @intCast(delay_ns / std.time.ns_per_s),
                    .nsec = @intCast(@rem(delay_ns, std.time.ns_per_s)),
                };
                _ = std.c.nanosleep(&req, null);
                backoff *= 2;
            }

            var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
            defer client.deinit();

            const uri = try std.Uri.parse(self.rpc_url);

            var response_body = std.ArrayList(u8).empty;
            var response_writer = std.Io.Writer.fromArrayList(&response_body);

            const res = client.fetch(.{
                .method = .POST,
                .location = .{ .uri = uri },
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
                .payload = body,
                .response_writer = &response_writer,
            }) catch {
                response_body = std.Io.Writer.toArrayList(&response_writer);
                response_body.deinit(self.allocator);
                last_err = error.Transport;
                continue;
            };

            if (res.status == .service_unavailable or res.status == .too_many_requests) {
                var rb = std.Io.Writer.toArrayList(&response_writer);
                rb.deinit(self.allocator);
                last_err = error.Transport;
                continue;
            }

            if (res.status != .ok) {
                var rb = std.Io.Writer.toArrayList(&response_writer);
                rb.deinit(self.allocator);
                return error.ProtocolInvalidResponse;
            }

            // Minimal JSON-RPC 2.0 envelope decoder:
            // { "result": T } OR { "error": { code, message, data? } }
            const Envelope = struct {
                jsonrpc: []const u8 = "2.0",
                id: i64 = 1,
                result: ?T = null,
                err: ?struct {
                    code: i64,
                    message: []const u8,
                    data: ?std.json.Value = null,
                } = null,
            };

            var parsed = std.json.parseFromSlice(Envelope, self.allocator, response_body.items, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.ProtocolDecode;
            };
            defer parsed.deinit();

            if (parsed.value.err) |e| {
                return errors.classifyRpcError(e.code, e.message);
            }

            return parsed.value.result orelse return error.ProtocolInvalidResponse;
        }

        if (last_err == error.Transport and retry > self.config.max_retries) {
            return error.RetryExhausted;
        }
        return last_err;
    }
};

test "RpcClient retry with backoff" {
    // This test validates the retry logic structurally by using an invalid URL.
    const allocator = std.testing.allocator;
    var client = RpcClient.init(allocator, "http://127.0.0.1:1/rpc", .{
        .timeout_ms = 100,
        .max_retries = 1,
        .backoff_ms = 50,
    }, std.testing.io);
    const result = client.call([]const u8, "knot3_getEpochs", "[]");
    try std.testing.expectError(error.RetryExhausted, result);
}
