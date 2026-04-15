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

/// Log error with context
pub fn logError(comptime E: type, err: E, context: []const u8) void {
    Log.err("[{s}] Error: {s}", .{ context, @errorName(err) });
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
