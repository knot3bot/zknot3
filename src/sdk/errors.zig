const std = @import("std");
const types = @import("types.zig");

/// SDK errors are intentionally machine-readable.
pub const Error = error{
    Transport,
    Timeout,
    RetryExhausted,
    ProtocolDecode,
    ProtocolInvalidResponse,
    RpcError,
    NodeMissingSigningKey,
};

pub const RpcErrorInfo = struct {
    code: i64,
    message: []const u8,
};

pub fn classifyRpcError(code: i64, msg: []const u8) Error {
    if (code == -32603 and std.mem.indexOf(u8, msg, "MissingSigningKey") != null) {
        return error.NodeMissingSigningKey;
    }
    return error.RpcError;
}

/// Map SDK error to standardized error code.
pub fn errorToCode(err: Error) types.SdkErrorCode {
    return switch (err) {
        error.Transport => .transport,
        error.Timeout => .timeout,
        error.RetryExhausted => .retry_exhausted,
        error.ProtocolDecode => .protocol_decode,
        error.ProtocolInvalidResponse => .protocol_invalid_response,
        error.RpcError => .rpc_error,
        error.NodeMissingSigningKey => .node_missing_signing_key,
    };
}
