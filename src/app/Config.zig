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

    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

/// Network configuration
pub const NetworkConfig = struct {
    pub const KnownValidator = struct {
        public_key_hex: []const u8,
        name: []const u8 = "",
        stake: u64 = 0,
    };

    /// Bind address for HTTP/RPC server
    bind_address: []const u8 = "127.0.0.1",
    /// Admin token for write-class HTTP/RPC endpoints.
    ///
    /// If empty, the node will refuse to bind RPC to a non-loopback address.
    /// When set, clients must pass `X-Zknot3-Admin-Token: <token>` for write endpoints.
    admin_token: []const u8 = "",
    /// RPC server port
    rpc_port: u16 = 9003,
    /// Enable P2P networking
    p2p_enabled: bool = false,
    /// P2P listen address
    p2p_address: []const u8 = "0.0.0.0:8083",
    /// Public dialable `host:port` advertised in authenticated P2P handshake
    /// listen trailer (signed response/ack via Blake3 listen_commitment).
    /// When empty, `resolveP2pAdvertiseAddress` falls back to `p2p_address`
    /// if that is dialable (not a wildcard bind like `0.0.0.0`).
    p2p_advertise_address: []const u8 = "",
    /// P2P port
    p2p_port: u16 = 8083,
    /// Local peer ID for P2P
    local_peer_id: []const u8 = "local_peer",
    /// Bootstrap peers for P2P network discovery (addresses)
    bootstrap_peers: []const []const u8 = &.{},
    /// Enable metrics server
    metrics_enabled: bool = true,
    /// Metrics server address
    metrics_address: []const u8 = "127.0.0.1:9133",
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
    /// Most TCP peers accepted from one IPv4 /16. Zero disables the cap.
    p2p_max_peers_per_16: usize = 8,
    /// Most TCP peers accepted from one IPv6 /48. Zero disables the cap.
    p2p_max_peers_per_48: usize = 8,
    /// Peer-table slots held for outbound dials (eclipse recovery). Zero disables.
    p2p_reserved_outbound_slots: usize = 8,
    /// Force-replace the oldest eligible peer every N seconds (eclipse
    /// resistance). Zero disables periodic rotation. Default 600 (10 minutes).
    p2p_peer_rotation_interval_secs: i64 = 600,
    /// Inbound peer share (percent, 0–100) that pauses new inbound accepts
    /// and leaves the node outbound-only. Zero disables. Default 80.
    p2p_inbound_ratio_limit: u8 = 80,
    /// `tcp` is the frozen mainnet transport. `quic` is refused unless the
    /// binary was built with `-Dquic`.
    transport: []const u8 = "tcp",
    /// Path of a `k3gen01` genesis file. Empty means the all-zero digest.
    genesis_path: []const u8 = "",
    /// Maximum HTTP request body size in bytes
    max_request_body_size: usize = 1024 * 1024, // 1MB
    /// Maximum concurrent HTTP connections
    max_concurrent_http_connections: usize = 256,
    /// TLS certificate file path (PEM). When set with tls_key_path, enables HTTPS.
    tls_cert_path: ?[]const u8 = null,
    /// TLS private key file path (PEM). When set with tls_cert_path, enables HTTPS.
    tls_key_path: ?[]const u8 = null,
    known_validators: []const KnownValidator = &.{},

    /// Dial string to put in the handshake listen trailer, or empty when none.
    /// Prefer explicit `p2p_advertise_address`; else `p2p_address` when dialable.
    pub fn resolveP2pAdvertiseAddress(self: NetworkConfig) []const u8 {
        if (self.p2p_advertise_address.len > 0) return self.p2p_advertise_address;
        if (isDialableP2pAddress(self.p2p_address)) return self.p2p_address;
        return "";
    }

    /// Deep-copy every string and slice field into `allocator`.
    pub fn dupe(self: NetworkConfig, allocator: std.mem.Allocator) !NetworkConfig {
        var out = self;
        out.bind_address = try allocator.dupe(u8, self.bind_address);
        out.admin_token = try allocator.dupe(u8, self.admin_token);
        out.p2p_address = try allocator.dupe(u8, self.p2p_address);
        out.p2p_advertise_address = try allocator.dupe(u8, self.p2p_advertise_address);
        out.local_peer_id = try allocator.dupe(u8, self.local_peer_id);
        out.metrics_address = try allocator.dupe(u8, self.metrics_address);
        out.tls_cert_path = try dupeOpt(u8, self.tls_cert_path, allocator);
        out.tls_key_path = try dupeOpt(u8, self.tls_key_path, allocator);
        out.transport = try allocator.dupe(u8, self.transport);
        out.genesis_path = try allocator.dupe(u8, self.genesis_path);
        out.bootstrap_peers = try dupeSliceOfSlices(self.bootstrap_peers, allocator);
        if (self.known_validators.len > 0) {
            const kvs = try allocator.alloc(KnownValidator, self.known_validators.len);
            for (self.known_validators, kvs) |kv, *slot| {
                slot.* = .{
                    .public_key_hex = try allocator.dupe(u8, kv.public_key_hex),
                    .name = try allocator.dupe(u8, kv.name),
                    .stake = kv.stake,
                };
            }
            out.known_validators = kvs;
        }
        return out;
    }
};

/// Returns true if TLS is configured (both cert and key paths are set).
pub fn tlsEnabled(config: NetworkConfig) bool {
    return config.tls_cert_path != null and config.tls_key_path != null;
}

/// True when `addr` looks like a dialable `host:port` (not wildcard bind).
fn isDialableP2pAddress(addr: []const u8) bool {
    if (addr.len == 0) return false;
    if (std.mem.startsWith(u8, addr, "0.0.0.0")) return false;
    if (std.mem.eql(u8, addr, "*") or std.mem.startsWith(u8, addr, "*:")) return false;
    // IPv6 unspecified bind forms.
    if (std.mem.eql(u8, addr, "::") or std.mem.startsWith(u8, addr, ":::") or std.mem.startsWith(u8, addr, "[::]")) return false;
    const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return false;
    if (colon == 0) return false;
    const port = addr[colon + 1 ..];
    if (port.len == 0) return false;
    _ = std.fmt.parseInt(u16, port, 10) catch return false;
    return true;
}

fn dupeOpt(comptime T: type, src: ?[]const T, allocator: std.mem.Allocator) !?[]T {
    const s = src orelse return null;
    return try allocator.dupe(T, s);
}

fn dupeSliceOfSlices(src: []const []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    if (src.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, src.len);
    for (src, out) |item, *slot| slot.* = try allocator.dupe(u8, item);
    return out;
}

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
    /// Stake units minted at each epoch boundary and split pro-rata across
    /// delegations. Zero disables minting.
    epoch_reward: u64 = 0,
    /// Quorum stake threshold (fraction of total)
    quorum_threshold: u64 = 200, // basis points (2%)
    /// Backup quorum threshold
    backup_quorum_threshold: u64 = 150,
    /// Minimum votes required to commit a block (for BFT safety)
    vote_quorum: usize = 3,
    /// Round interval in seconds (500ms for high-throughput consensus)
    round_interval_secs: u64 = 1,
    /// Maximum transactions per block
    max_txs_per_block: u32 = 10000,
    /// Maximum committed blocks to retain in memory before pruning
    max_committed_blocks: usize = 10000,
    /// Maximum pending blocks to retain in memory before pruning
    max_pending_blocks: usize = 5000,
    /// Round timeout in seconds — if no quorum reached, advance to next round
    round_timeout_secs: i64 = 5,
    /// Enable BLS signature aggregation (replaces per-vote Ed25519 with single 96-byte BLS sig)
    enable_bls_aggregation: bool = false,

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
    /// Skip corrupted WAL records during recovery (default: true for resilience)
    recovery_skip_corrupted: bool = true,
    /// Seconds between periodic `m4_gas_snapshot` WAL appends during runtime.
    /// Complements per-op `m4_gas_balance` durability so crash recovery can
    /// skip replaying long balance tails. `0` disables periodic snapshots
    /// (clean shutdown still writes one snapshot). Default 300 (5 minutes).
    gas_snapshot_interval_secs: i64 = 300,

    /// Deep-copy every string field into `allocator`.
    pub fn dupe(self: StorageConfig, allocator: std.mem.Allocator) !StorageConfig {
        var out = self;
        out.data_dir = try allocator.dupe(u8, self.data_dir);
        out.object_store_path = try allocator.dupe(u8, self.object_store_path);
        out.checkpoint_store_path = try allocator.dupe(u8, self.checkpoint_store_path);
        return out;
    }
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
    /// When true, Executor requires gas_payer balance >= gas_budget and deducts
    /// gas_used after execution. Default false so existing Node/e2e paths stay free-gas.
    enforce_gas_payment: bool = false,
    /// Seed amount applied to local authority identity (when available) and each
    /// `authority.gas_station_allowlist` entry when `enforce_gas_payment` is enabled.
    /// Pragmatic ledger only — not genesis coin objects.
    initial_gas_balance: u64 = 1_000_000_000,
};

/// Authority/validator configuration
pub const AuthorityConfig = struct {
    /// Validator address (IP or hostname)
    address: []const u8 = "127.0.0.1",
    /// Validator port
    port: u16 = 8083,
    /// Validator's signing key (32 bytes)
    signing_key: ?[32]u8 = null,
    /// Gas Station allowlist — sponsored addresses (AI agents, automation)
    gas_station_allowlist: []const [32]u8 = &.{},
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
    /// Hex seed file. Used when `signing_key` is null. The file is not logged.
    signing_key_path: []const u8 = "",
    /// Environment variable holding the 64-char hex seed. Preferred over the file.
    signing_key_env: []const u8 = "",
    /// Optional BLS signing seed used for aggregated checkpoint signature payloads.
    bls_signing_seed: ?[32]u8 = null,
    /// Extra BLS seeds aggregated together with `bls_signing_seed`.
    extra_bls_signing_seeds: []const [32]u8 = &.{},

    /// Deep-copy every string and slice field into `allocator`.
    pub fn dupe(self: AuthorityConfig, allocator: std.mem.Allocator) !AuthorityConfig {
        var out = self;
        out.address = try allocator.dupe(u8, self.address);
        out.signing_key_path = try allocator.dupe(u8, self.signing_key_path);
        out.signing_key_env = try allocator.dupe(u8, self.signing_key_env);
        out.name = try allocator.dupe(u8, self.name);
        out.description = try allocator.dupe(u8, self.description);
        out.gas_station_allowlist = try allocator.dupe([32]u8, self.gas_station_allowlist);
        out.checkpoint_proof_extra_signing_seeds = try allocator.dupe([32]u8, self.checkpoint_proof_extra_signing_seeds);
        out.extra_bls_signing_seeds = try allocator.dupe([32]u8, self.extra_bls_signing_seeds);
        return out;
    }
};

/// Full node configuration
/// NodeConfig is the canonical node configuration struct.
/// Use ConfigWithBuffer for file-based loading with proper lifetime management.
/// TODO: Merge with Config below to eliminate the duplicate type hierarchy.
/// NodeConfig is an alias for Config — unified in v0.12.
pub const NodeConfig = Config;

pub const Config = struct {
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
    allow_unauthenticated_p2p: bool = false,
    parallel_execution: usize = 1,

    /// Validate configuration
    pub fn validate(self: Self) !void {
        if (self.consensus.min_validators < 4) return error.MinValidatorsTooLow;
        if (self.consensus.target_validators > self.consensus.max_validators) return error.InvalidValidatorRange;
        if (self.vm.min_gas_price == 0) return error.InvalidGasPrice;
        if (self.network.max_connections == 0) return error.InvalidMaxConnections;
        if (self.network.p2p_max_messages_per_peer_per_second == 0 or
            self.network.p2p_max_messages_per_type_per_second == 0) return error.InvalidP2PRateLimit;
        if (self.network.p2p_peer_ban_seconds <= 0) return error.InvalidP2PBanWindow;
        if (self.network.p2p_inbound_ratio_limit > 100) return error.InvalidP2PInboundRatioLimit;
        if (self.consensus.max_messages_per_tick == 0) return error.InvalidConsensusMessageBudget;
        // Port conflict: RPC and P2P must use different ports
        if (self.network.rpc_port == self.network.p2p_port) return error.PortConflict;
        // Data directory must be non-empty for non-dev configurations
        if (!self.is_dev and self.storage.data_dir.len == 0) return error.MissingDataDir;
        // Unauthenticated P2P is forbidden in production environment
        if (!self.is_dev and self.allow_unauthenticated_p2p) return error.UnauthenticatedP2PForbiddenInProduction;
        if (!std.mem.eql(u8, self.network.transport, "tcp") and !std.mem.eql(u8, self.network.transport, "quic")) {
            return error.InvalidTransport;
        }
        if (std.mem.eql(u8, self.network.transport, "quic") and !@import("quic_options").enabled) {
            return error.QuicTransportRequiresBuildFlag;
        }
        if (self.consensus.validator_enabled) {
            if (self.authority.stake == 0) return error.InvalidValidatorStake;
            if (!self.network.p2p_enabled) return error.ValidatorRequiresP2P;
        }
    }

    /// Fill `signing_key` from the environment variable or a hex file.
    /// An already-set key is left in place. Nothing about the seed is logged.
    pub fn resolveSigningKey(authority: *AuthorityConfig, allocator: std.mem.Allocator) !void {
        if (authority.signing_key != null) return;
        if (authority.signing_key_env.len > 0) {
            var name: [128]u8 = undefined;
            if (authority.signing_key_env.len >= name.len) return error.InvalidSigningKey;
            @memcpy(name[0..authority.signing_key_env.len], authority.signing_key_env);
            name[authority.signing_key_env.len] = 0;
            const raw = std.c.getenv(name[0..authority.signing_key_env.len :0]) orelse return error.MissingSigningKey;
            authority.signing_key = try @import("Genesis.zig").parseHex32(std.mem.span(raw));
            return;
        }
        if (authority.signing_key_path.len == 0) return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(@import("io_instance").io, authority.signing_key_path, allocator, std.Io.Limit.limited(128)) catch return error.InvalidSigningKey;
        defer allocator.free(bytes);
        authority.signing_key = try @import("Genesis.zig").parseHex32(bytes);
    }

    /// Builder pattern: chainable config construction.
    pub fn builder() Self {
        return Self{};
    }
    pub fn withValidator(self: Self, enabled: bool) Self {
        var s = self;
        s.is_validator = enabled;
        return s;
    }
    pub fn withDataDir(self: Self, dir: []const u8) Self {
        var s = self;
        s.storage.data_dir = dir;
        return s;
    }
    pub fn withRpcPort(self: Self, port: u16) Self {
        var s = self;
        s.network.rpc_port = port;
        return s;
    }
    pub fn withDev(self: Self) Self {
        var s = self;
        s.is_dev = true;
        s.verbose = true;
        return s;
    }

    /// Create default configuration
    pub fn default() Self {
        return Self{};
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
        // NOTE: `Self.loadFromJSON` returns a config that borrows from `contents`.
        // Keep `contents` alive for the lifetime of the returned config.
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

    /// Deep-copy every string and slice field into `allocator`.
    ///
    /// Long-lived owners (e.g. `Node`) must not retain a borrowed `Config`:
    /// callers routinely heap-allocate the config and free it as soon as
    /// `init` returns, which would leave dangling string slices behind.
    /// Passing an arena allocator keeps teardown to a single `deinit`.
    pub fn dupe(self: Config, allocator: std.mem.Allocator) !Config {
        var out = self;
        out.network = try self.network.dupe(allocator);
        out.storage = try self.storage.dupe(allocator);
        out.authority = try self.authority.dupe(allocator);
        return out;
    }

    /// Save node config to JSON file
    pub fn saveToFile(self: Self, allocator: std.mem.Allocator, path: []const u8) !void {
        const json_str = try self.toJSON(allocator);
        defer allocator.free(json_str);
        try std.Io.Dir.cwd().writeFile(@import("io_instance").io, .{ .sub_path = path, .data = json_str });
    }
};

/// ConfigWithBuffer holds a parsed Config along with its backing buffer and JSON arena.
/// This ensures string slices in Config remain valid for the lifetime of ConfigWithBuffer.
pub const ConfigWithBuffer = struct {
    config: Config,
    buffer: []u8, // File contents — must live as long as config string slices
    json_parsed: std.json.Parsed(Config),

    pub fn deinit(self: *ConfigWithBuffer, allocator: std.mem.Allocator) void {
        self.json_parsed.deinit();
        allocator.free(self.buffer);
    }
};

/// Load node config from JSON file, returning with its backing buffer.
/// The buffer and JSON arena are kept alive to ensure string slices in config remain valid.
pub fn loadConfigWithBuffer(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ConfigWithBuffer {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024));
    errdefer allocator.free(contents);
    var parsed = try json.parseFromSlice(Config, allocator, contents, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    return ConfigWithBuffer{
        .config = parsed.value,
        .buffer = contents,
        .json_parsed = parsed,
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

test "NetworkConfig.resolveP2pAdvertiseAddress prefers explicit then dialable bind" {
    var net = NetworkConfig{};
    net.p2p_address = "0.0.0.0:8083";
    net.p2p_advertise_address = "";
    try std.testing.expectEqualStrings("", net.resolveP2pAdvertiseAddress());

    net.p2p_address = "127.0.0.1:8083";
    try std.testing.expectEqualStrings("127.0.0.1:8083", net.resolveP2pAdvertiseAddress());

    net.p2p_advertise_address = "203.0.113.9:8083";
    try std.testing.expectEqualStrings("203.0.113.9:8083", net.resolveP2pAdvertiseAddress());

    net.p2p_address = "0.0.0.0";
    net.p2p_advertise_address = "";
    try std.testing.expectEqualStrings("", net.resolveP2pAdvertiseAddress());
}

test "Config.validate rejects port conflict" {
    var cfg = Config{};
    cfg.network.rpc_port = 9003;
    cfg.network.p2p_port = 9003;
    try std.testing.expectError(error.PortConflict, cfg.validate());
}

test "Config.validate requires data_dir for non-dev" {
    var cfg = Config{};
    cfg.is_dev = false;
    cfg.storage.data_dir = &.{};
    try std.testing.expectError(error.MissingDataDir, cfg.validate());
}

test "Config default passes validation" {
    var cfg = Config.default();
    cfg.is_dev = true;
    try std.testing.expectEqual(@as(u8, 80), cfg.network.p2p_inbound_ratio_limit);
    try cfg.validate();
}

test "Config.validate rejects inbound ratio above 100" {
    var cfg = Config.default();
    cfg.is_dev = true;
    cfg.network.p2p_inbound_ratio_limit = 101;
    try std.testing.expectError(error.InvalidP2PInboundRatioLimit, cfg.validate());
    cfg.network.p2p_inbound_ratio_limit = 0;
    try cfg.validate();
}

test "Config.validate rejects quic unless the binary links ngtcp2" {
    var cfg = Config.default();
    cfg.is_dev = true;
    cfg.network.transport = "quic";
    if (@import("quic_options").enabled) {
        try cfg.validate();
    } else {
        try std.testing.expectError(error.QuicTransportRequiresBuildFlag, cfg.validate());
    }
}

test "Config.resolveSigningKey reads a hex file and ignores an existing key" {
    const io = @import("io_instance").io;
    const path = "signing-key-test.hex";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff\n" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var authority = AuthorityConfig{ .signing_key_path = path };
    try Config.resolveSigningKey(&authority, std.testing.allocator);
    try std.testing.expect(authority.signing_key != null);
    try std.testing.expectEqual(@as(u8, 0x00), authority.signing_key.?[0]);
    try std.testing.expectEqual(@as(u8, 0xff), authority.signing_key.?[31]);

    authority.signing_key = @splat(0xAB);
    try Config.resolveSigningKey(&authority, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0xAB), authority.signing_key.?[0]);
}

test "Config.validate rejects unauthenticated P2P in non-dev" {
    var cfg = Config.default();
    cfg.is_dev = false;
    cfg.allow_unauthenticated_p2p = true;
    try std.testing.expectError(error.UnauthenticatedP2PForbiddenInProduction, cfg.validate());
}

test "StorageConfig gas snapshot interval defaults to 300s" {
    const storage = StorageConfig{};
    try std.testing.expectEqual(@as(i64, 300), storage.gas_snapshot_interval_secs);

    var cfg = Config.default();
    try std.testing.expectEqual(@as(i64, 300), cfg.storage.gas_snapshot_interval_secs);

    // Missing JSON field keeps the default.
    const parsed = try std.json.parseFromSlice(
        Config,
        std.testing.allocator,
        \\{"is_dev":true,"storage":{"data_dir":"./data"}}
    ,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 300), parsed.value.storage.gas_snapshot_interval_secs);

    cfg.storage.gas_snapshot_interval_secs = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const duped = try cfg.dupe(arena.allocator());
    try std.testing.expectEqual(@as(i64, 0), duped.storage.gas_snapshot_interval_secs);
}

test "VMConfig gas payment defaults stay off" {
    const vm = VMConfig{};
    try std.testing.expectEqual(false, vm.enforce_gas_payment);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), vm.initial_gas_balance);

    var cfg = Config.default();
    try std.testing.expectEqual(false, cfg.vm.enforce_gas_payment);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), cfg.vm.initial_gas_balance);

    // Missing JSON fields must keep defaults (ignore_unknown + struct defaults).
    const parsed = try std.json.parseFromSlice(
        Config,
        std.testing.allocator,
        \\{"is_dev":true,"vm":{"max_gas_budget":42}}
    ,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 42), parsed.value.vm.max_gas_budget);
    try std.testing.expectEqual(false, parsed.value.vm.enforce_gas_payment);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), parsed.value.vm.initial_gas_balance);

    // Config.dupe value-copies VMConfig (no owned slices on that sub-struct).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    cfg.vm.enforce_gas_payment = true;
    cfg.vm.initial_gas_balance = 123;
    const duped = try cfg.dupe(arena.allocator());
    try std.testing.expectEqual(true, duped.vm.enforce_gas_payment);
    try std.testing.expectEqual(@as(u64, 123), duped.vm.initial_gas_balance);
}
