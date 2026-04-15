//! API handlers for dashboard
const std = @import("std");
const Node = @import("../Node.zig");
const Mysticeti = @import("../../form/consensus/Mysticeti.zig");
const Metrics = @import("../../metric/Metrics.zig");
const TxnPool = @import("../../pipeline/TxnPool.zig");

/// API response wrapper
pub fn jsonResponse(comptime T: type, data: T) []u8 {
    // This would serialize to JSON - simplified for demo
    return "{\"status\":\"ok\"}";
}

/// GET /api/node/info
pub fn handleNodeInfo(node: *Node) NodeInfoResponse {
    const info = node.getNodeInfo();
    return NodeInfoResponse{
        .version = info.version,
        .state = info.state,
        .uptime_seconds = info.uptime_seconds,
        .object_store_count = info.object_store_count,
        .checkpoint_sequence = info.checkpoint_sequence,
        .pending_transactions = info.pending_transactions,
        .committed_blocks = info.committed_blocks,
    };
}

pub const NodeInfoResponse = struct {
    version: []const u8,
    state: []const u8,
    uptime_seconds: i64,
    object_store_count: u64,
    checkpoint_sequence: u64,
    pending_transactions: usize,
    committed_blocks: usize,
};

/// GET /api/consensus/status
pub fn handleConsensusStatus(node: *Node) ConsensusStatusResponse {
    return ConsensusStatusResponse{
        .current_round = node.stats.highest_round,
        .highest_committed_block = node.stats.blocks_committed,
        .active_validators = 4, // Placeholder
        .quorum_reached = node.stats.blocks_committed > 0,
    };
}

pub const ConsensusStatusResponse = struct {
    current_round: u64,
    highest_committed_block: u64,
    active_validators: u32,
    quorum_reached: bool,
};

/// GET /api/txn/stats
pub fn handleTxnStats(node: *Node) TxnStatsResponse {
    const pool_stats = node.getTxnPoolStats();
    return TxnStatsResponse{
        .pending = pool_stats.pending,
        .executing = pool_stats.executing,
        .total_executed = node.stats.transactions_executed,
    };
}

pub const TxnStatsResponse = struct {
    pending: usize,
    executing: usize,
    total_executed: u64,
};

/// GET /api/metrics
pub fn handleMetrics() TriSourceMetricsResponse {
    // Placeholder metrics - in real impl would aggregate from MetricsCollector
    return TriSourceMetricsResponse{
        .wu_feng = 0.85,
        .xiang_da = 0.78,
        .zi_zai = 0.92,
    };
}

pub const TriSourceMetricsResponse = struct {
    wu_feng: f64,
    xiang_da: f64,
    zi_zai: f64,
};
