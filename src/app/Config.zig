//! Config - Node and network configuration management
//!
//! Provides configuration structures for all node components
//! with sensible defaults and validation.

const std = @import("std");
const json = @import("std").json;

/// Protocol version
pub const ProtocolVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    const Self = @This();

    pub fn format(_self: Self) []const u8 {
        _ = _self;
        return "0.1.0"; // Simplified
    }
};

/// Network configuration
pub const NetworkConfig = struct {
    /// Bind address for HTTP/RPC server
    bind_address: []const u8 = "127.0.0.1",
    /// RPC server port
    rpc_port: u16 = 9000,
    /// Enable P2P networking
    p2p_enabled: bool = false,
    /// P2P listen address
    p2p_address: []const u8 = "0.0.0.0:8080",
    /// P2P port
    p2p_port: u16 = 8080,
    /// Local peer ID for P2P
    local_peer_id: []const u8 = "local_peer",
    /// Bootstrap peers for P2P network discovery (addresses)
    bootstrap_peers: []const []const u8 = &.{},
    /// Enable metrics server
    metrics_enabled: bool = true,
    /// Metrics server address
    metrics_address: []const u8 = "127.0.0.1:9090",
    /// Maximum connections
    max_connections: usize = 1024,
    /// Connection timeout in seconds
    connection_timeout: u64 = 30,
    /// Enable UPnP port forwarding
    enable_upnp: bool = false,
    /// Maximum HTTP requests per second (rate limiting)
    max_requests_per_second: u32 = 100,
    /// Maximum inbound P2P messages per peer per second
    p2p_max_messages_per_peer_per_second: usize = 256,
    /// Maximum inbound P2P messages for one message type per second
    p2p_max_messages_per_type_per_second: usize = 128,
    /// Peer score threshold that triggers a temporary ban
    p2p_peer_score_ban_threshold: i32 = -100,
    /// Temporary peer ban duration in seconds
    p2p_peer_ban_seconds: i64 = 300,
};

/// Consensus configuration
pub const ConsensusConfig = struct {
    /// Enable validator mode
    validator_enabled: bool = false,
    /// Minimum stake to become validator
    min_validator_stake: u64 = 1_000_000_000, // 1 KNOT3
    /// Minimum number of validators
    min_validators: usize = 4,
    /// Target number of validators
    target_validators: usize = 100,
    /// Maximum validators
    max_validators: usize = 500,
    /// Epoch duration in seconds
    epoch_duration_secs: u64 = 86400, // 24 hours
    /// Quorum stake threshold (fraction of total)
    quorum_threshold: u64 = 200, // basis points (2%)
    /// Backup quorum threshold
    backup_quorum_threshold: u64 = 150,
    /// Minimum votes required to commit a block (for BFT safety)
    vote_quorum: usize = 3,
    /// Round interval in seconds
    round_interval_secs: u64 = 2,
    /// Maximum transactions per block
    max_txs_per_block: u32 = 50,
    /// Maximum committed blocks to retain in memory before pruning
    max_committed_blocks: usize = 10000,

    // ---------------------------------------------------------------------
    // P2P message scheduling budgets (public-chain hardening)
    // ---------------------------------------------------------------------
    /// Total messages processed per event-loop tick
    max_messages_per_tick: usize = 256,
    /// Base per-type budgets
    max_block_messages_per_tick: usize = 64,
    max_vote_messages_per_tick: usize = 128,
    max_certificate_messages_per_tick: usize = 32,
    max_transaction_messages_per_tick: usize = 32,
    /// Per-peer cap in one scheduling turn
    per_peer_batch_limit: usize = 4,

    /// Dynamic budget thresholds based on mempool pressure
    pending_tx_medium_threshold: usize = 256,
    pending_tx_high_threshold: usize = 2048,

    /// Dynamic budget deltas (applied when thresholds/phase match)
    medium_tx_budget_boost: usize = 24,
    high_tx_budget_boost: usize = 48,
    near_round_vote_budget_boost: usize = 24,
    near_round_certificate_budget_boost: usize = 16,
    near_round_block_budget_boost: usize = 8,

    /// Per-type floors to avoid starvation
    min_block_messages_per_tick: usize = 32,
    min_vote_messages_per_tick: usize = 64,
    min_certificate_messages_per_tick: usize = 16,
    min_transaction_messages_per_tick: usize = 8,
};

/// Storage configuration
pub const StorageConfig = struct {
    /// Data directory
    data_dir: []const u8 = "./data",
    /// Object store path
    object_store_path: []const u8 = "objects",
    /// Checkpoint store path
    checkpoint_store_path: []const u8 = "checkpoints",
    /// Maximum cache size in bytes
    cache_size: usize = 1024 * 1024 * 1024, // 1GB
    /// Enable LSM tree compaction
    enable_compaction: bool = true,
    /// Compaction interval in seconds
    compaction_interval_secs: u64 = 3600,
};

/// VM/execution configuration
pub const VMConfig = struct {
    /// Maximum gas budget per transaction
    max_gas_budget: u64 = 10_000_000,
    /// Minimum gas price
    min_gas_price: u64 = 1000,
    /// Maximum bytecode size
    max_bytecode_size: usize = 65536,
    /// Instruction gas cost base
    base_instruction_gas: u64 = 1,
    /// Storage gas per byte
    storage_gas_per_byte: u64 = 10,
};

/// Authority/validator configuration
pub const AuthorityConfig = struct {
    /// Validator address (IP or hostname)
    address: []const u8 = "127.0.0.1",
    /// Validator port
    port: u16 = 8080,
    /// Validator's signing key (32 bytes)
    signing_key: ?[32]u8 = null,
    /// Validator's network key (32 bytes)
    network_key: ?[32]u8 = null,
    /// Validator's stake
    stake: u64 = 0,
    /// Validator name
    name: []const u8 = "Validator",
    /// Validator description
    description: []const u8 = "",
    /// Validator index (for round-robin proposer selection)
    validator_index: usize = 0,
    /// Extra Ed25519 seeds for M4 `buildCheckpointProof` signatures, appended after `signing_key` (same message, distinct validator ids).
    checkpoint_proof_extra_signing_seeds: []const [32]u8 = &.{},
    /// Optional BLS signing seed used for aggregated checkpoint signature payloads.
    bls_signing_seed: ?[32]u8 = null,
    /// Extra BLS seeds aggregated together with `bls_signing_seed`.
    extra_bls_signing_seeds: []const [32]u8 = &.{},
};

/// Full node configuration
pub const NodeConfig = struct {
    const Self = @This();

    /// Protocol version
    version: ProtocolVersion = .{ .major = 0, .minor = 1, .patch = 0 },
    /// Network settings
    network: NetworkConfig = .{},
    /// Consensus settings
    consensus: ConsensusConfig = .{},
    /// Storage settings
    storage: StorageConfig = .{},
    /// VM settings
    vm: VMConfig = .{},
    /// Authority settings (if validator)
    authority: AuthorityConfig = .{},
    /// Enable validator mode
    is_validator: bool = false,
    /// Enable dev mode
    is_dev: bool = false,
    /// Enable verbose logging
    verbose: bool = false,

    /// Validate configuration
    pub fn validate(self: Self) !void {
        if (self.consensus.min_validators < 4) {
            return error.MinValidatorsTooLow;
        }
        if (self.consensus.target_validators > self.consensus.max_validators) {
            return error.InvalidValidatorRange;
        }
        if (self.vm.min_gas_price == 0) {
            return error.InvalidGasPrice;
        }
        if (self.network.max_connections == 0) {
            return error.InvalidMaxConnections;
        }
        if (self.network.p2p_max_messages_per_peer_per_second == 0 or
            self.network.p2p_max_messages_per_type_per_second == 0)
        {
            return error.InvalidP2PRateLimit;
        }
        if (self.network.p2p_peer_ban_seconds <= 0) {
            return error.InvalidP2PBanWindow;
        }
        if (self.consensus.max_messages_per_tick == 0) {
            return error.InvalidConsensusMessageBudget;
        }
    }

    /// Create production configuration
    pub fn production() Self {
        return .{
            .is_validator = false,
            .is_dev = false,
            .verbose = false,
        };
    }

    /// Create development configuration
    pub fn development() Self {
        return .{
            .is_validator = true,
            .is_dev = true,
            .verbose = true,
        };
    }

    /// Create validator configuration
    pub fn validator(signing_key: [32]u8, stake: u64) Self {
        return .{
            .is_validator = true,
            .authority = .{
                .signing_key = signing_key,
                .stake = stake,
            },
        };
    }


/// Load node config from JSON file
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
    const contents = try std.Io.Dir.cwd().readFileAlloc(@import("io_instance").io, path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(contents);
    return try Self.loadFromJSON(allocator, contents);
}

/// Parse node config from JSON string
/// NOTE: The returned config borrows from json_slice - caller must keep
/// json_slice alive for the lifetime of the returned config!
pub fn loadFromJSON(allocator: std.mem.Allocator, json_slice: []const u8) !Self {
    return try json.parseFromSlice(Self, allocator, json_slice, .{ .ignore_unknown_fields = true });
}

    /// Save node config to JSON string
    pub fn toJSON(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        try json.stringify(self, .{ .whitespace = .indent_tab }, buf.writer());
        return buf.toOwnedSlice();
    }

    /// Save node config to JSON file
    pub fn saveToFile(self: Self, allocator: std.mem.Allocator, path: []const u8) !void {
        const json_str = try self.toJSON(allocator);
        defer allocator.free(json_str);
        try std.Io.Dir.cwd().writeFile(@import("io_instance").io, .{ .sub_path = path, .data = json_str });
    }
};

/// ConfigWithBuffer holds a parsed Config along with its backing buffer.
/// This ensures string slices in Config remain valid for the lifetime of ConfigWithBuffer.
pub const ConfigWithBuffer = struct {
    config: Config,
    buffer: []u8,  // Must live at least as long as config

    pub fn deinit(self: *ConfigWithBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

/// Load node config from JSON file, returning with its backing buffer.
/// The buffer is kept alive to ensure string slices in config remain valid.
pub fn loadConfigWithBuffer(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ConfigWithBuffer {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024));
    errdefer allocator.free(contents);
    const parsed = try json.parseFromSlice(Config, allocator, contents, .{ .ignore_unknown_fields = true });
    // parsed.value contains slices into contents, so we must keep contents alive
    return ConfigWithBuffer{
        .config = parsed.value,
        .buffer = contents,
    };
}

pub const MetricsConfig = struct {
    /// Enable metrics collection
    enabled: bool = true,
    /// Prometheus scrape interval
    scrape_interval_secs: u64 = 15,
    /// Enable performance profiling
    enable_profiling: bool = false,
    /// Profile interval in seconds
    profile_interval_secs: u64 = 60,
};

/// Logger configuration
pub const LoggerConfig = struct {
    /// Log level (0=err, 1=warn, 2=info, 3=debug, 4=trace)
    level: u3 = 2,
    /// Log to file
    enable_file: bool = true,
    /// Log file path
    file_path: []const u8 = "./logs/zknot3.log",
    /// Log to stderr
    enable_stderr: bool = true,
    /// Enable structured logging (JSON)
    structured: bool = false,
    /// Enable ANSI colors
    ansi_colors: bool = true,
};

/// Metrics collector
pub const Metrics = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// Transaction count
    tx_count: u64,
    /// Block count
    block_count: u64,
    /// Object count
    object_count: u64,
    /// Checkpoint count
    checkpoint_count: u64,
    /// Total gas used
    total_gas: u64,
    /// Validator count
    validator_count: usize,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .tx_count = 0,
            .block_count = 0,
            .object_count = 0,
            .checkpoint_count = 0,
            .total_gas = 0,
            .validator_count = 0,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Record a transaction
    pub fn recordTx(self: *Self, gas: u64) void {
        self.tx_count += 1;
        self.total_gas += gas;
    }

    /// Record a block
    pub fn recordBlock(self: *Self) void {
        self.block_count += 1;
    }

    /// Record a checkpoint
    pub fn recordCheckpoint(self: *Self) void {
        self.checkpoint_count += 1;
    }

    /// Update validator count
    pub fn setValidatorCount(self: *Self, count: usize) void {
        self.validator_count = count;
    }

    /// Get TPS (transactions per second)
    pub fn tps(self: Self) f64 {
        return @as(f64, @floatFromInt(self.tx_count)) / 60.0; // Simplified
    }
};

/// Full configuration container
pub const Config = struct {
    const Self = @This();

    network: NetworkConfig = .{},
    consensus: ConsensusConfig = .{},
    storage: StorageConfig = .{},
    vm: VMConfig = .{},
    authority: AuthorityConfig = .{},
    allow_unauthenticated_p2p: bool = false,

    /// Create default configuration
    pub fn default() Self {
        return Self{};
    }

    /// Create development configuration
    pub fn development() Self {
        return .{
            .consensus = .{ .validator_enabled = true },
            .authority = .{ .stake = 1_000_000_000 },
            .allow_unauthenticated_p2p = true,
        };
    }

    /// Create production configuration
    pub fn production() Self {
        return Self{};
    }

    /// Load configuration from JSON file
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
        const contents = try std.Io.Dir.cwd().readFileAlloc(@import("io_instance").io, path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(contents);
        return try Self.loadFromJSON(allocator, contents);
    }

    /// Parse configuration from JSON string
    pub fn loadFromJSON(allocator: std.mem.Allocator, json_slice: []const u8) !Self {
        const parsed = try json.parseFromSlice(Self, allocator, json_slice, .{ .ignore_unknown_fields = true });
        return parsed.value;
    }

    /// Save configuration to JSON string
    pub fn toJSON(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        try json.stringify(self, .{ .whitespace = .indent_tab }, buf.writer());
        return buf.toOwnedSlice();
    }

    /// Save configuration to JSON file
    pub fn saveToFile(self: Self, allocator: std.mem.Allocator, path: []const u8) !void {
        const json_str = try self.toJSON(allocator);
        defer allocator.free(json_str);
        try std.Io.Dir.cwd().writeFile(@import("io_instance").io, .{ .sub_path = path, .data = json_str });
    }
};

test "Config default" {
    const config = Config.default();
    try std.testing.expect(config.network.rpc_port == 9000);
}

test "Config development" {
    const config = Config.development();
    try std.testing.expect(config.consensus.validator_enabled == true);
}

test "NodeConfig validation" {
    const config = NodeConfig.development();
    try config.validate();
}

test "Metrics recording" {
    const allocator = std.testing.allocator;
    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    metrics.recordTx(1000);
    metrics.recordBlock();
    metrics.recordCheckpoint();

    try std.testing.expect(metrics.tx_count == 1);
    try std.testing.expect(metrics.block_count == 1);
    try std.testing.expect(metrics.checkpoint_count == 1);
}

test "Metrics TPS calculation" {
    const allocator = std.testing.allocator;
    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    // Record 60 transactions
    for (0..60) |_| {
        metrics.recordTx(100);
    }

    const tps = metrics.tps();
    try std.testing.expect(tps >= 0.9 and tps <= 1.1);
}
