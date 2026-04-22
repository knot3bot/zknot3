//! zknot3 Error Types
//!
//! Comprehensive error types for the entire zknot3 blockchain node.
//! Organized by layer for easy error handling and debugging.

const std = @import("std");
const Log = @import("../app/Log.zig");

// =============================================================================
// Core Layer Errors
// =============================================================================

pub const CoreError = error {
    InvalidObjectID,
    VersionOrderingError,
    OwnershipInvariantViolation,
    ZeroOwnerError,
    TransferError,
    ObjectNotFound,
    ObjectAlreadyExists,
};

// =============================================================================
// Form Layer Errors (Storage, Network, Consensus)
// =============================================================================

pub const StorageError = error {
    ReadError,
    WriteError,
    KeyNotFound,
    ChecksumMismatch,
    CorruptionDetected,
    IOError,
    OutOfMemory,
};

pub const NetworkError = error {
    ConnectionFailed,
    Timeout,
    MessageTooLarge,
    MalformedMessage,
    PeerNotFound,
    TooManyConnections,
    NodeKeyError,
    CryptoError,
};

pub const ConsensusError = error {
    QuorumNotReached,
    InsufficientStake,
    InvalidValidatorSet,
    VoteVerificationFailed,
    DAGIntegrityError,
    BlockNotFound,
    CommitRuleNotSatisfied,
};

// =============================================================================
// Property Layer Errors (Move VM, Access, Crypto)
// =============================================================================

pub const MoveVMError = error {
    InvalidBytecode,
    OutOfGas,
    ResourceNotFound,
    TypeMismatch,
    LinearTypeViolation,
    ResourceLeak,
    InvalidCall,
    Abort,
    MoveAbort,
};

pub const AccessError = error {
    PermissionDenied,
    CapabilityNotFound,
    PolicyViolation,
    InvalidCapability,
};

pub const CryptoError = error {
    InvalidSignature,
    KeyDerivationFailed,
    HashComputationFailed,
    MerkleProofError,
    InvalidPublicKey,
    VRFProofError,
};

// =============================================================================
// Metric Layer Errors (Stake, Epoch, Metrics)
// =============================================================================

pub const MetricError = error {
    InsufficientStake,
    ValidatorNotFound,
    EpochTransitionError,
    InvalidEpoch,
    QuorumCalculationError,
    CollectionError,
};

// =============================================================================
// Pipeline Layer Errors (Ingress, Executor, Egress)
// =============================================================================

pub const IngressError = error {
    TooManyPending,
    VerificationFailed,
    LockFailed,
    InvalidTransaction,
    InsufficientGas,
    SequenceError,
};

pub const ExecutorError = error {
    ExecutionFailed,
    DependencyError,
    ParallelismError,
    OutputObjectError,
};

pub const EgressError = error {
    AggregationFailed,
    SignatureVerificationFailed,
    CommitError,
    StateRootMismatch,
};

// =============================================================================
// App Layer Errors (GraphQL, Indexer, ClientSDK)
// =============================================================================

pub const GraphQLError = error {
    ParseError,
    ValidationError,
    ExecutionError,
    SchemaError,
};

pub const IndexerError = error {
    IndexingFailed,
    QueryError,
    MigrationError,
};

pub const ClientError = error {
    RPCError,
    ResponseParseError,
    ConnectionError,
};

// =============================================================================
// Formal Verification Errors
// =============================================================================

pub const FormalError = error {
    SpecGenerationFailed,
    ProofExportFailed,
    CoqCompilationError,
    LeanCompilationError,
};

// =============================================================================
// Universal Error Helpers
// =============================================================================

/// Convert any error to a user-friendly string
pub fn formatError(comptime E: type, err: E, writer: anytype) !void {
    try writer.print("Error: {s}", .{@errorName(err)});
}



/// Check if error is retryable
pub fn isRetryable(comptime E: type, err: E) bool {
    return switch (err) {
        NetworkError.Timeout => true,
        NetworkError.ConnectionFailed => true,
        StorageError.IOError => true,
        else => false,
    };
}

// =============================================================================
// Error Conversion
// =============================================================================

/// Convert network error to core error
pub fn networkToCoreError(err: NetworkError) CoreError {
    return switch (err) {
        .CryptoError => .OwnershipInvariantViolation,
        else => .ObjectNotFound,
    };
}

/// Convert storage error to core error
pub fn storageToCoreError(err: StorageError) CoreError {
    return switch (err) {
        .KeyNotFound => .ObjectNotFound,
        .ChecksumMismatch => .CorruptionDetected,
        else => .ObjectNotFound,
    };
}
// =============================================================================
// Error Code Conversion and Mapping
// =============================================================================

/// RPC Error Code to System Error Type Mapping
pub const RPCErrorCodeMap = struct {
    pub fn toSystemError(code: i32) !CoreError { // 这里可以根据需要返回适当的错误类型
        switch (code) {
            // 标准 JSON-RPC 错误
            -32700 => return CoreError.InvalidObjectID,    // parse_error
            -32600 => return CoreError.InvalidObjectID,    // invalid_request
            -32601 => return CoreError.ObjectNotFound,     // method_not_found
            -32602 => return CoreError.InvalidObjectID,    // invalid_params
            -32603 => return StorageError.ReadError,       // internal_error
            
            // Knot3 特定错误
            -32001 => return CoreError.ObjectNotFound,     // knot3_object_not_found
            -32002 => return CoreError.TransferError,      // knot3_object_not_deliverable
            -32003 => return MoveVMError.MoveAbort,        // knot3_move_abort
            -32004 => return MoveVMError.InvalidBytecode,  // knot3_move_verification_error
            -32005 => return CoreError.ObjectNotFound,     // knot3_package_not_found
            -32006 => return CoreError.ObjectNotFound,     // knot3_module_not_found
            -32007 => return CoreError.ObjectNotFound,     // knot3_function_not_found
            -32008 => return CoreError.InvalidObjectID,    // knot3_invalid_transaction
            -32009, -32010 => return CryptoError.InvalidSignature, // knot3_invalid_signature (legacy/new)
            
            else => return CoreError.InvalidObjectID,
        }
    }
    
    pub fn fromSystemError(err: anytype) i32 {
        const E = @TypeOf(err);
        
        switch (@typeInfo(E)) {
            .ErrorSet => {
                switch (err) {
                    // 核心层错误
                    CoreError.InvalidObjectID => return -32008,
                    CoreError.ObjectNotFound => return -32001,
                    CoreError.TransferError => return -32002,
                    CoreError.OwnershipInvariantViolation => return -32002,
                    
                    // 存储层错误
                    StorageError.ReadError => return -32603,
                    StorageError.WriteError => return -32603,
                    StorageError.ChecksumMismatch => return -32603,
                    StorageError.CorruptionDetected => return -32603,
                    
                    // 网络层错误
                    NetworkError.ConnectionFailed => return -32603,
                    NetworkError.Timeout => return -32603,
                    NetworkError.MessageTooLarge => return -32008,
                    
                    // 共识层错误
                    ConsensusError.QuorumNotReached => return -32603,
                    ConsensusError.VoteVerificationFailed => return -32010,
                    
                    // Move VM 错误
                    MoveVMError.InvalidBytecode => return -32004,
                    MoveVMError.MoveAbort => return -32003,
                    MoveVMError.OutOfGas => return -32603,
                    
                    // 加密错误
                    CryptoError.InvalidSignature => return -32010,
                    
                    else => return -32603, // internal_error
                }
            },
            else => return -32603, // internal_error
        }
    }
};

// =============================================================================
// Enhanced Error Context
// =============================================================================

/// Error context information for logging and debugging
pub const ErrorContext = struct {
    file: []const u8,
    line: u32,
    function: []const u8,
    context: []const u8 = "",
    request_id: ?[]const u8 = null,
    peer_id: ?[32]u8 = null,
};

/// Extended error type with context information
pub const ContextualError = struct {
    err: anyerror,
    ctx: ErrorContext,
    
    pub fn init(err: anyerror, file: []const u8, line: u32, function: []const u8) @This() {
        return .{
            .err = err,
            .ctx = .{
                .file = file,
                .line = line,
                .function = function,
            },
        };
    }
    
    pub fn withContext(self: @This(), context: []const u8) @This() {
        var copy = self;
        copy.ctx.context = context;
        return copy;
    }
    
    pub fn withRequestId(self: @This(), request_id: []const u8) @This() {
        var copy = self;
        copy.ctx.request_id = request_id;
        return copy;
    }
    
    pub fn withPeerId(self: @This(), peer_id: [32]u8) @This() {
        var copy = self;
        copy.ctx.peer_id = peer_id;
        return copy;
    }
};

/// Create a contextual error
pub fn contextualize(err: anyerror, file: []const u8, line: u32, function: []const u8) ContextualError {
    return ContextualError.init(err, file, line, function);
}

// =============================================================================
// Enhanced Error Logging
// =============================================================================

/// Log an error with context
pub fn logError(err: anyerror, context: ErrorContext) void {
    const error_name = @errorName(err);
    
    if (context.peer_id) |pid| {
        var peer_str: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&peer_str, "0x{x}", .{pid}) catch @memcpy(&peer_str, "<error>");
        
        if (context.request_id) |rid| {
            Log.err("[{}:{}:{}] [PEER={}] [REQ={}] {}: {}", .{ 
                context.file, 
                context.line, 
                context.function, 
                peer_str[0..std.mem.indexOf(u8, &peer_str, "\x00") orelse peer_str.len],
                rid,
                context.context,
                error_name
            });
        } else {
            Log.err("[{}:{}:{}] [PEER={}] {}: {}", .{ 
                context.file, 
                context.line, 
                context.function, 
                peer_str[0..std.mem.indexOf(u8, &peer_str, "\x00") orelse peer_str.len],
                context.context,
                error_name
            });
        }
    } else if (context.request_id) |rid| {
        Log.err("[{}:{}:{}] [REQ={}] {}: {}", .{ 
            context.file, 
            context.line, 
            context.function, 
            rid,
            context.context,
            error_name
        });
    } else {
        Log.err("[{}:{}:{}] {}: {}", .{ 
            context.file, 
            context.line, 
            context.function, 
            context.context,
            error_name
        });
    }
}



// =============================================================================
// Error Recovery Helper
// =============================================================================

/// Check if an error is retryable and get suggested retry strategy
pub const RetryStrategy = enum {
    no_retry,
    immediate,
    exponential_backoff,
    fixed_delay,
};

pub const RetryInfo = struct {
    strategy: RetryStrategy,
    max_attempts: u32,
    base_delay_ms: u32,
};

pub fn getRetryInfo(err: anyerror) RetryInfo {
    const E = @TypeOf(err);
    
    switch (@typeInfo(E)) {
        .ErrorSet => {
            switch (err) {
                // 网络相关错误 - 可重试
                NetworkError.Timeout => return .{ .strategy = .exponential_backoff, .max_attempts = 5, .base_delay_ms = 100 },
                NetworkError.ConnectionFailed => return .{ .strategy = .exponential_backoff, .max_attempts = 3, .base_delay_ms = 500 },
                
                // 存储相关错误 - 可重试
                StorageError.IOError => return .{ .strategy = .exponential_backoff, .max_attempts = 3, .base_delay_ms = 1000 },
                
                // 其他可重试错误
                StorageError.ReadError => return .{ .strategy = .fixed_delay, .max_attempts = 2, .base_delay_ms = 500 },
                
                // 默认 - 不可重试
                else => return .{ .strategy = .no_retry, .max_attempts = 0, .base_delay_ms = 0 },
            }
        },
        else => return .{ .strategy = .no_retry, .max_attempts = 0, .base_delay_ms = 0 },
    }
}

/// Check if an error is fatal and requires node shutdown
pub fn isFatal(err: anyerror) bool {
    const E = @TypeOf(err);
    
    switch (@typeInfo(E)) {
        .ErrorSet => {
            switch (err) {
                StorageError.CorruptionDetected => return true,
                StorageError.OutOfMemory => return true,
                CoreError.OwnershipInvariantViolation => return true,
                else => return false,
            }
        },
        else => return false,
    }
}
