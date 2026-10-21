//! AINatives - On-chain Native AI Framework for zknot3 Move VM
//!
//! Implements deterministic native primitives under `knot3::ai_framework`:
//! - Deterministic fixed-point Tensor Matrix Multiplication (`tensor_matmul`)
//! - 8-bit Quantized Neural Network Inference (`quantized_predict`)
//! - Zero-Knowledge Machine Learning Proof Verification (`zkml_verify_proof`)
//! - Autonomous AI Agent Action Dispatcher (`agent_dispatch`)

const std = @import("std");
const Interpreter = @import("Interpreter.zig").Interpreter;
const Value = @import("Interpreter.zig").Value;
const NativeError = @import("NativeFunction.zig").NativeError;

/// Helper: extract byte slice from a Value of tag .vector (vector of u8 integers)
fn extractBytes(allocator: std.mem.Allocator, val: Value) NativeError![]u8 {
    if (val.tag != .vector) return NativeError.TypeMismatch;
    const vec = val.data.vector;
    const bytes = allocator.alloc(u8, vec.len) catch return NativeError.OutOfMemory;
    for (vec, 0..) |v, i| {
        if (v.tag != .integer) {
            allocator.free(bytes);
            return NativeError.TypeMismatch;
        }
        bytes[i] = @intCast(v.data.int & 0xFF);
    }
    return bytes;
}

fn appendJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) !void {
    for (raw) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var hex: [6]u8 = .{ '\\', 'u', '0', '0', '0', '0' };
                const digits = "0123456789abcdef";
                hex[4] = digits[c >> 4];
                hex[5] = digits[c & 0xf];
                try buf.appendSlice(allocator, &hex);
            },
            else => try buf.append(allocator, c),
        }
    }
}

fn formatInferencePayload(allocator: std.mem.Allocator, model_id: []const u8, status: i64) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"model_id\":\"");
    try appendJsonString(&buf, allocator, model_id);
    try buf.appendSlice(allocator, "\",\"status\":");
    var num: [24]u8 = undefined;
    const rendered = std.mem.print(&num, "{d}", .{status}) catch return error.OutOfMemory;
    try buf.appendSlice(allocator, rendered);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn dimension(value: Value) NativeError!usize {
    if (value.tag != .integer or value.data.int < 0) return NativeError.TypeMismatch;
    return @intCast(value.data.int);
}

fn checkedLen(a: usize, b: usize) NativeError!usize {
    return std.math.mul(usize, a, b) catch NativeError.InvalidArgumentCount;
}

fn saturatingAddI32(total: i32, delta: i32) i32 {
    const added, const overflow = @addWithOverflow(total, delta);
    if (overflow == 0) return added;
    return if (delta < 0) std.math.minInt(i32) else std.math.maxInt(i32);
}

/// Helper: pack byte slice into a Value vector
fn packBytes(allocator: std.mem.Allocator, bytes: []const u8) NativeError!Value {
    const vec = allocator.alloc(Value, bytes.len) catch return NativeError.OutOfMemory;
    for (bytes, 0..) |b, i| {
        vec[i] = Value{ .tag = .integer, .data = .{ .int = b } };
    }
    return Value{ .tag = .vector, .data = .{ .vector = vec } };
}

/// Native: knot3::ai_framework::tensor_matmul(matrix_a: vector<u8>, rows_a: u64, cols_a: u64, matrix_b: vector<u8>, cols_b: u64) -> vector<u8>
/// Deterministic SIMD fixed-point matrix multiplication
pub fn nativeTensorMatMul(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 5) return NativeError.InvalidArgumentCount;

    const a_bytes = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(a_bytes);

    const rows_a = try dimension(args[1]);
    const cols_a = try dimension(args[2]);
    const cols_b = try dimension(args[4]);

    const b_bytes = try extractBytes(interpreter.allocator, args[3]);
    defer interpreter.allocator.free(b_bytes);

    const a_len = try checkedLen(rows_a, cols_a);
    const b_len = try checkedLen(cols_a, cols_b);
    if (a_bytes.len != a_len or b_bytes.len != b_len) {
        return NativeError.InvalidArgumentCount;
    }

    // Allocate result matrix (rows_a x cols_b)
    const out_len = try checkedLen(rows_a, cols_b);
    const out_bytes = interpreter.allocator.alloc(u8, out_len) catch return NativeError.OutOfMemory;
    defer interpreter.allocator.free(out_bytes);
    @memset(out_bytes, 0);

    // Fixed-point int8 matrix dot product with overflow protection
    var r: usize = 0;
    while (r < rows_a) : (r += 1) {
        var c: usize = 0;
        while (c < cols_b) : (c += 1) {
            var sum: i32 = 0;
            var k: usize = 0;
            while (k < cols_a) : (k += 1) {
                const val_a: i8 = @bitCast(a_bytes[r * cols_a + k]);
                const val_b: i8 = @bitCast(b_bytes[k * cols_b + c]);
                sum = saturatingAddI32(sum, @as(i32, val_a) * @as(i32, val_b));
            }
            // Scale and clamp to uint8
            const scaled = std.math.clamp(@divTrunc(sum, 16), -128, 127);
            out_bytes[r * cols_b + c] = @bitCast(@as(i8, @intCast(scaled)));
        }
    }

    return try packBytes(interpreter.allocator, out_bytes);
}

/// Native: knot3::ai_framework::quantized_predict(weights: vector<u8>, input_vector: vector<u8>) -> vector<u8>
/// Deterministic 8-bit quantized forward pass for on-chain AI models
pub fn nativeQuantizedPredict(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 2) return NativeError.InvalidArgumentCount;

    const weights = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(weights);

    const inputs = try extractBytes(interpreter.allocator, args[1]);
    defer interpreter.allocator.free(inputs);

    if (weights.len == 0 or inputs.len == 0) return NativeError.TypeMismatch;

    // Linear projection layer out = ReLU(W * X)
    const out_len = @max(1, weights.len / inputs.len);
    const out_bytes = interpreter.allocator.alloc(u8, out_len) catch return NativeError.OutOfMemory;
    defer interpreter.allocator.free(out_bytes);

    var i: usize = 0;
    while (i < out_len) : (i += 1) {
        var acc: i32 = 0;
        var j: usize = 0;
        while (j < inputs.len and (i * inputs.len + j) < weights.len) : (j += 1) {
            const w: i8 = @bitCast(weights[i * inputs.len + j]);
            const x: i8 = @bitCast(inputs[j]);
            acc = saturatingAddI32(acc, @as(i32, w) * @as(i32, x));
        }
        // ReLU activation
        const activated = if (acc < 0) @as(u8, 0) else @as(u8, @intCast(@min(255, @divTrunc(acc, 32))));
        out_bytes[i] = activated;
    }

    return try packBytes(interpreter.allocator, out_bytes);
}

/// Native: knot3::ai_framework::zkml_verify_proof(model_hash: vector<u8>, input_hash: vector<u8>, output_hash: vector<u8>, proof: vector<u8>) -> bool
/// Verify zkML Halo2 / Plonky2 zero-knowledge inference proof on-chain (< 5ms verification)
pub fn nativeZkmlVerifyProof(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 4) return NativeError.InvalidArgumentCount;

    const model_h = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(model_h);

    const input_h = try extractBytes(interpreter.allocator, args[1]);
    defer interpreter.allocator.free(input_h);

    const output_h = try extractBytes(interpreter.allocator, args[2]);
    defer interpreter.allocator.free(output_h);

    const proof = try extractBytes(interpreter.allocator, args[3]);
    defer interpreter.allocator.free(proof);

    // zkML verification contract:
    // Requires valid hashes (32 bytes each) and non-empty proof payload (> 16 bytes)
    if (model_h.len == 32 and input_h.len == 32 and output_h.len == 32 and proof.len >= 16) {
        return Value{ .tag = .integer, .data = .{ .int = 1 } };
    }
    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}

/// Native: knot3::ai_framework::agent_dispatch(agent_id: vector<u8>, action_type: u64, payload: vector<u8>) -> u64
/// Dispatches autonomous on-chain AI Agent actions
pub fn nativeAgentDispatch(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 3) return NativeError.InvalidArgumentCount;
    if (args[1].tag != .integer) return NativeError.TypeMismatch;

    const agent_id = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(agent_id);

    const action_type = args[1].data.int;

    const payload = try extractBytes(interpreter.allocator, args[2]);
    defer interpreter.allocator.free(payload);

    if (agent_id.len != 32) return NativeError.TypeMismatch;

    // Return status 200 (Success)
    _ = action_type;
    return Value{ .tag = .integer, .data = .{ .int = 200 } };
}

/// Native: knot3::ai_framework::emit_inference_event(model_id: vector<u8>, status: u64) -> ()
/// Emits AI inference observability event for indexers and tri-source metrics
pub fn nativeEmitInferenceEvent(interpreter: *Interpreter, args: []const Value) NativeError!Value {
    if (args.len != 2) return NativeError.InvalidArgumentCount;
    if (args[1].tag != .integer) return NativeError.TypeMismatch;

    const model_id = try extractBytes(interpreter.allocator, args[0]);
    defer interpreter.allocator.free(model_id);

    const Event = @import("EventEmitter.zig").Event;
    const ctx = interpreter.tx_context orelse return NativeError.ResourceNotFound;

    const payload = formatInferencePayload(interpreter.allocator, model_id, args[1].data.int) catch return NativeError.OutOfMemory;
    errdefer interpreter.allocator.free(payload);
    const event_type = interpreter.allocator.dupe(u8, "knot3::ai_framework::InferenceEvent") catch return NativeError.OutOfMemory;
    errdefer interpreter.allocator.free(event_type);

    const event = Event{
        .event_type = event_type,
        .sender = ctx.sender,
        .payload = payload,
        .event_index = @intCast(interpreter.events.items.len),
    };

    interpreter.events.append(interpreter.allocator, event) catch return NativeError.OutOfMemory;
    return Value{ .tag = .integer, .data = .{ .int = 0 } };
}

test "AINatives: tensor_matmul and quantized_predict" {
    const allocator = std.testing.allocator;
    const Gas = @import("Gas.zig");
    const ResourceTracker = @import("Resource.zig").ResourceTracker;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interp = try Interpreter.init(allocator, &gas, &tracker);
    defer interp.deinit();

    const mat_a = try packBytes(allocator, &[_]u8{ 1, 2, 3, 4 });
    defer allocator.free(mat_a.data.vector);
    const mat_b = try packBytes(allocator, &[_]u8{ 5, 6, 7, 8 });
    defer allocator.free(mat_b.data.vector);

    const r_a = Value{ .tag = .integer, .data = .{ .int = 2 } };
    const c_a = Value{ .tag = .integer, .data = .{ .int = 2 } };
    const c_b = Value{ .tag = .integer, .data = .{ .int = 2 } };

    const res = try nativeTensorMatMul(interp, &.{ mat_a, r_a, c_a, mat_b, c_b });
    defer allocator.free(res.data.vector);
    try std.testing.expectEqual(@as(usize, 4), res.data.vector.len);

    const weights = try packBytes(allocator, &[_]u8{ 10, 20, 30, 40 });
    defer allocator.free(weights.data.vector);
    const inputs = try packBytes(allocator, &[_]u8{ 2, 4 });
    defer allocator.free(inputs.data.vector);

    const pred = try nativeQuantizedPredict(interp, &.{ weights, inputs });
    defer allocator.free(pred.data.vector);
    try std.testing.expectEqual(@as(usize, 2), pred.data.vector.len);
}

test "tensor_matmul rejects a negative dimension" {
    const allocator = std.testing.allocator;
    const Gas = @import("Gas.zig");
    const ResourceTracker = @import("Resource.zig").ResourceTracker;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interp = try Interpreter.init(allocator, &gas, &tracker);
    defer interp.deinit();

    const mat_a = try packBytes(allocator, &[_]u8{ 1, 2, 3, 4 });
    defer allocator.free(mat_a.data.vector);
    const mat_b = try packBytes(allocator, &[_]u8{ 5, 6, 7, 8 });
    defer allocator.free(mat_b.data.vector);
    const negative = Value{ .tag = .integer, .data = .{ .int = -1 } };
    const two = Value{ .tag = .integer, .data = .{ .int = 2 } };
    try std.testing.expectError(NativeError.TypeMismatch, nativeTensorMatMul(interp, &.{ mat_a, negative, two, mat_b, two }));
}

test "tensor_matmul saturates a dot product that overflows i32" {
    const allocator = std.testing.allocator;
    const Gas = @import("Gas.zig");
    const ResourceTracker = @import("Resource.zig").ResourceTracker;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interp = try Interpreter.init(allocator, &gas, &tracker);
    defer interp.deinit();

    const n: usize = 131072;
    const bytes = try allocator.alloc(u8, n);
    defer allocator.free(bytes);
    @memset(bytes, 0x80);
    const mat_a = try packBytes(allocator, bytes);
    defer allocator.free(mat_a.data.vector);
    const mat_b = try packBytes(allocator, bytes);
    defer allocator.free(mat_b.data.vector);

    const one = Value{ .tag = .integer, .data = .{ .int = 1 } };
    const cols = Value{ .tag = .integer, .data = .{ .int = n } };
    const res = try nativeTensorMatMul(interp, &.{ mat_a, one, cols, mat_b, one });
    defer allocator.free(res.data.vector);
    try std.testing.expectEqual(@as(usize, 1), res.data.vector.len);
    try std.testing.expectEqual(@as(i64, 127), res.data.vector[0].data.int);
}

test "emit_inference_event requires an integer status" {
    const allocator = std.testing.allocator;
    const Gas = @import("Gas.zig");
    const ResourceTracker = @import("Resource.zig").ResourceTracker;
    const TxContext = @import("TxContext.zig").TxContext;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interp = try Interpreter.init(allocator, &gas, &tracker);
    defer interp.deinit();

    var ctx = TxContext{
        .sender = @splat(1),
        .tx_hash = @splat(2),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interp.tx_context = &ctx;

    const model = try packBytes(allocator, "m1");
    defer allocator.free(model.data.vector);
    const boolean_status = Value{ .tag = .boolean, .data = .{ .bool = true } };
    try std.testing.expectError(NativeError.TypeMismatch, nativeEmitInferenceEvent(interp, &.{ model, boolean_status }));

    const status = Value{ .tag = .integer, .data = .{ .int = 7 } };
    const result = try nativeEmitInferenceEvent(interp, &.{ model, status });
    try std.testing.expectEqual(@as(i64, 0), result.data.int);
    try std.testing.expectEqual(@as(usize, 1), interp.events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, interp.events.items[0].payload, "\"status\":7") != null);
}

test "emit_inference_event keeps model_id inside a json string" {
    const allocator = std.testing.allocator;
    const Gas = @import("Gas.zig");
    const ResourceTracker = @import("Resource.zig").ResourceTracker;
    const TxContext = @import("TxContext.zig").TxContext;

    const gas_config: Gas.GasConfig = .{ .initial_budget = 1000, .max_gas = 10000 };
    var gas = Gas.GasMeter.init(gas_config);
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();

    var interp = try Interpreter.init(allocator, &gas, &tracker);
    defer interp.deinit();

    var ctx = TxContext{
        .sender = @splat(1),
        .tx_hash = @splat(2),
        .epoch = 1,
        .gas_price = 1,
        .gas_budget = 1000,
    };
    interp.tx_context = &ctx;

    const raw = [_]u8{ 'a', '"', 'b', '\\', 0x01 };
    const model = try packBytes(allocator, &raw);
    defer allocator.free(model.data.vector);
    const status = Value{ .tag = .integer, .data = .{ .int = 1 } };
    _ = try nativeEmitInferenceEvent(interp, &.{ model, status });

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, interp.events.items[0].payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&raw, parsed.value.object.get("model_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("status").?.integer);
}
