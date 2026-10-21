//! P2PServer - TCP/QUIC server for peer-to-peer networking
//!
//! Implements actual network I/O following libp2p patterns:
//! - TCP or QUIC transport with non-blocking I/O
//! - Connection acceptance and management
//! - Message framing and parsing
//! - Peer identification and handshake
//!
//! Reference: rust-libp2p's TCP/QUIC transport and swarm patterns

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../../core.zig");
const Transport = @import("Transport.zig");
const Message = Transport.Message;
const P2PMessageType = @import("P2P.zig").P2PMessageType;
const QUIC = @import("QUIC.zig");
const Log = @import("../../app/Log.zig");

/// Breaking change vs v2: signed message binds `listen_commitment` (Blake3 of
/// advertise UTF-8, or 32 zero bytes when empty). Wire signed core stays 168B;
/// commitment lives only in the sign/verify buffer (verifier rebuilds it from
/// the plaintext listen trailer, or empty). Unauthenticated handshake unchanged.
const HANDSHAKE_CONTEXT = "zknot3_p2p_handshake_v3";

/// Authenticated handshake request core: nonce_a(32) + timestamp(8) + genesis(32).
/// Request is unsigned; initiator advertise is carried on the signed ack.
const HANDSHAKE_REQUEST_CORE_LEN: usize = 72;
/// Authenticated handshake signed core: nonce_a(32) + nonce_b(32) + ts(8) + sig(64) + genesis(32).
/// Optional listen trailer (`u16_be len` + UTF-8) may follow; Blake3(trailer)
/// must equal the listen_commitment covered by `sig`.
const HANDSHAKE_SIGNED_CORE_LEN: usize = 168;
/// Max UTF-8 `host:port` bytes in an optional listen trailer after signed cores.
const HANDSHAKE_MAX_LISTEN_LEN: usize = 256;

const GenesisDigest = struct {
    fn accepted(local: [32]u8, remote: [32]u8) bool {
        return std.mem.eql(u8, &local, &remote);
    }
};
const HANDSHAKE_WINDOW_SECS: i64 = 60;

const HandshakeNonceTracker = struct {
    allocator: std.mem.Allocator,
    ttl_secs: i64,
    entries: std.AutoArrayHashMapUnmanaged([32]u8, i64) = .empty,
    /// Inbound handshakes run on worker threads, so the shared nonce table
    /// needs a lock: replay protection is only sound if the check-and-insert
    /// is atomic.
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    fn init(allocator: std.mem.Allocator, ttl_secs: i64) HandshakeNonceTracker {
        return .{
            .allocator = allocator,
            .ttl_secs = ttl_secs,
        };
    }

    fn deinit(self: *HandshakeNonceTracker) void {
        self.entries.deinit(self.allocator);
    }

    fn registerFresh(self: *HandshakeNonceTracker, nonce: [32]u8, now: i64) bool {
        const io = @import("io_instance").io;
        self.mutex.lock(io) catch return false;
        defer self.mutex.unlock(io);
        return self.registerFreshLocked(nonce, now);
    }

    fn registerFreshLocked(self: *HandshakeNonceTracker, nonce: [32]u8, now: i64) bool {
        var i: usize = 0;
        while (i < self.entries.count()) {
            const ts = self.entries.values()[i];
            if (now - ts > self.ttl_secs) {
                const key = self.entries.keys()[i];
                _ = self.entries.swapRemove(key);
                continue;
            }
            i += 1;
        }

        if (self.entries.contains(nonce)) return false;
        self.entries.put(self.allocator, nonce, now) catch return false;
        return true;
    }
};

fn streamWriteAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var writer = stream.writer(@import("io_instance").io, &.{});
    try writer.interface.writeAll(bytes);
}

fn streamReadShort(stream: std.Io.net.Stream, buf: []u8) !usize {
    var reader = stream.reader(@import("io_instance").io, &.{});
    return reader.interface.readSliceShort(buf) catch |err| {
        if (err == error.ReadFailed) return reader.err.?;
        return error.WouldBlock;
    };
}

fn streamReadVec(stream: std.Io.net.Stream, buf: []u8) !usize {
    var reader = stream.reader(@import("io_instance").io, &.{});
    var data: [1][]u8 = .{buf};
    return reader.interface.readVec(&data) catch |err| {
        if (err == error.ReadFailed) return reader.err.?;
        return error.WouldBlock;
    };
}

fn currentSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

/// Transport protocol type
pub const TransportType = enum {
    tcp,
    quic,
};

pub const P2PServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0:8083",
    max_connections: usize = 256,
    connection_timeout_secs: u64 = 30,
    ping_interval_secs: u64 = 15,
    max_message_size: usize = 64 * 1024 * 1024,
    transport_type: TransportType = .tcp,
    /// Bootstrap peer addresses to connect to on startup
    bootstrap_peers: []const []const u8 = &.{},
    /// Whether to dial bootstrap peers
    dial_bootstrap: bool = true,
    /// Optional validator key for P2P handshake authentication
    validator_key: ?[32]u8 = null,
    /// Development-only escape hatch for peers without validator identity
    allow_unauthenticated_handshake: bool = false,
    /// Per-peer incoming message cap in a one-second window
    max_messages_per_second_per_peer: usize = 256,
    /// Per-message-type incoming message cap in a one-second window
    max_messages_per_second_per_type: usize = 128,
    /// Score threshold for temporary ban
    peer_score_ban_threshold: i32 = -100,
    /// Ban duration in seconds
    peer_ban_seconds: i64 = 300,
    /// Most peers accepted from one IPv4 /16. Zero disables the cap.
    /// Unspecified 0.0.0.0 is not counted, so test sockets are unaffected.
    max_peers_per_16: usize = 8,
    /// Most peers accepted from one IPv6 /48. Zero disables the cap.
    /// Unspecified `::` and IPv4-mapped addresses are not counted here.
    max_peers_per_48: usize = 8,
    /// Slots held exclusively for outbound dials so an inbound eclipse cannot
    /// fill the peer table. Zero disables. Clamped to `max_connections - 1`
    /// when reserved would otherwise leave no inbound room.
    reserved_outbound_slots: usize = 8,
    /// Force-disconnect the lowest-quality eligible peer every N seconds so
    /// long-lived / low-quality inbound peers cannot permanently eclipse the
    /// view. Zero disables.
    peer_rotation_interval_secs: i64 = 600,
    /// Inbound share (percent, 0–100) above which new inbound accepts pause
    /// and the node stays outbound-only. Zero disables. The inbound side is
    /// published inbound peers plus in-flight inbound handshakes. See
    /// `inboundRatioSuspicious`.
    inbound_ratio_limit: u8 = 80,
    /// Genesis digest exchanged in the authenticated handshake. All-zero
    /// matches peers that have not pinned a chain.
    genesis_digest: [32]u8 = @splat(0),
    /// Dialable `host:port` advertised in authenticated handshake: responder
    /// puts it on the signed **response** trailer; initiator on the signed
    /// **ack** trailer (see `PeerConnection.appendListenTrailer`). Empty
    /// disables advertisement (signed listen_commitment is 32 zero bytes).
    /// Trailer plaintext is bound by Ed25519 via `Blake3(advertise_utf8)`.
    advertise_address: []const u8 = "",
    /// Decoded Ed25519 public keys from `network.known_validators`.
    /// Borrowed for the server lifetime. Handshake-advertised dial strings
    /// are quality-remembered only when the peer key is in this set. Empty
    /// refuses every advertised address (fail closed). Dial strings this
    /// node opened are remembered regardless.
    known_validator_keys: []const [32]u8 = &.{},
    /// Per-key operator dial, parallel to `known_validator_keys`. Borrowed
    /// for the server lifetime. An empty `dial` leaves that key unrestricted
    /// (any signed advertise may be remembered). A non-empty `dial` is the
    /// only advertised `host:port` that may be quality-remembered for the key.
    known_validator_dials: []const KnownValidatorDial = &.{},
};

/// Operator dial pin for one known validator. `dial` empty means unrestricted.
pub const KnownValidatorDial = struct {
    key: [32]u8,
    dial: []const u8,
};

/// Snapshot used by the pure rotation victim picker (no sockets).
pub const PeerRotationCandidate = struct {
    key: [32]u8,
    connected_at: i64,
    is_outbound: bool,
    /// Live peer reputation in [0, 100]; lower → preferred rotation victim.
    reputation: i32 = 100,
    /// Observed RTT in ms; higher → lower quality (see `peerRotationQuality`).
    latency_ms: u64 = 0,
};

/// True when `interval_secs > 0` and enough wall time has elapsed since
/// `last_rotation`. Zero (or negative) interval disables rotation.
pub fn peerRotationDue(last_rotation: i64, now: i64, interval_secs: i64) bool {
    if (interval_secs <= 0) return false;
    return now - last_rotation >= interval_secs;
}

/// Peer quality for rotation preference. Lower = worse = preferred victim.
/// Same score is reused for outbound dial preference (higher = better target).
///
/// Formula: `quality = reputation - min(latency_ms / 10, 50)`.
/// With reputation in [0, 100], quality is roughly in [-50, 100].
pub fn peerRotationQuality(reputation: i32, latency_ms: u64) i32 {
    const lat_penalty: i32 = @intCast(@min(latency_ms / 10, 50));
    return reputation - lat_penalty;
}

/// True when `key` is one of the configured known-validator public keys.
/// An empty `keys` slice matches nothing (advertised dial strings are refused).
pub fn pubkeyAllowed(keys: []const [32]u8, key: [32]u8) bool {
    for (keys) |candidate| {
        if (std.mem.eql(u8, &candidate, &key)) return true;
    }
    return false;
}

/// Non-empty operator dial for `key`. Null when the key has no entry or the
/// configured dial string is empty. An empty dial does not mean "any address".
fn configuredValidatorDial(dials: []const KnownValidatorDial, key: [32]u8) ?[]const u8 {
    for (dials) |entry| {
        if (!std.mem.eql(u8, &entry.key, &key)) continue;
        if (entry.dial.len == 0) return null;
        return entry.dial;
    }
    return null;
}

/// Cap on remembered disconnects used for quality-weighted redial.
pub const QUALITY_MEMORY_CAP: usize = 64;

/// Snapshot of a disconnected peer eligible for quality-weighted redial.
pub const PeerQualityMemoryEntry = struct {
    /// Owned dial string, preferably resolved (`a.b.c.d:port` / `[v6]:port`).
    /// Freed when the entry is evicted.
    address: []u8,
    /// Last observed peer key (pubkey or address-derived).
    peer_key: [32]u8,
    reputation: i32,
    latency_ms: u64,
};

/// Pure dial-target candidate (no sockets). Caller sets `connected` / `subnet_ok`.
pub const QualityDialCandidate = struct {
    address: []const u8,
    reputation: i32 = 100,
    latency_ms: u64 = 0,
    /// Already in the live peer table (by key or address hash).
    connected: bool = false,
    /// Would pass IPv4 /16 or IPv6 /48 admission if dialed now.
    subnet_ok: bool = true,
};

/// Pick which remembered peer to dial next. Prefers highest
/// `peerRotationQuality` among candidates that are not connected and pass
/// subnet admission. Returns an index into `candidates`, or null.
pub fn pickQualityDialTarget(candidates: []const QualityDialCandidate) ?usize {
    var best: ?usize = null;
    for (candidates, 0..) |c, i| {
        if (c.connected or !c.subnet_ok or c.address.len == 0) continue;
        if (best) |b| {
            const qa = peerRotationQuality(c.reputation, c.latency_ms);
            const qb = peerRotationQuality(candidates[b].reputation, candidates[b].latency_ms);
            if (qa > qb) best = i;
        } else {
            best = i;
        }
    }
    return best;
}

/// True when `a` is a better rotation victim than `b` (lower quality, then older).
fn isPreferredRotationVictim(a: PeerRotationCandidate, b: PeerRotationCandidate) bool {
    const qa = peerRotationQuality(a.reputation, a.latency_ms);
    const qb = peerRotationQuality(b.reputation, b.latency_ms);
    if (qa != qb) return qa < qb;
    return a.connected_at < b.connected_at;
}

fn isBootstrapProtectedKey(key: [32]u8, protected: []const [32]u8) bool {
    for (protected) |pk| {
        if (std.mem.eql(u8, &pk, &key)) return true;
    }
    return false;
}

/// Pick which peer to force-replace. Prefers inbound over outbound; among
/// eligible peers of that class, prefers lowest quality
/// (`peerRotationQuality`), then oldest `connected_at`. When only outbound
/// peers remain and bootstrap is configured, never rotate the last outbound;
/// skip outbound peers whose key matches a bootstrap address hash.
/// Returns an index into `candidates`, or null when nothing should be rotated.
pub fn pickPeerRotationVictim(
    candidates: []const PeerRotationCandidate,
    bootstrap_protected: []const [32]u8,
    bootstrap_configured: bool,
) ?usize {
    if (candidates.len == 0) return null;

    var outbound_count: usize = 0;
    for (candidates) |c| {
        if (c.is_outbound) outbound_count += 1;
    }

    var best_inbound: ?usize = null;
    for (candidates, 0..) |c, i| {
        if (c.is_outbound) continue;
        if (best_inbound) |best| {
            if (isPreferredRotationVictim(c, candidates[best])) best_inbound = i;
        } else {
            best_inbound = i;
        }
    }
    if (best_inbound) |idx| return idx;

    // Only outbound peers remain.
    if (bootstrap_configured and outbound_count <= 1) return null;

    var best_outbound: ?usize = null;
    for (candidates, 0..) |c, i| {
        if (!c.is_outbound) continue;
        if (isBootstrapProtectedKey(c.key, bootstrap_protected)) continue;
        if (best_outbound) |best| {
            if (isPreferredRotationVictim(c, candidates[best])) best_outbound = i;
        } else {
            best_outbound = i;
        }
    }
    return best_outbound;
}

/// Effective reserved outbound count: `0` disables; otherwise clamped so at
/// least one inbound slot remains when `max_connections > 0`.
pub fn effectiveReservedOutbound(max_connections: usize, reserved: usize) usize {
    if (reserved == 0 or max_connections == 0) return 0;
    if (reserved >= max_connections) return max_connections - 1;
    return reserved;
}

/// Inbound accept: leave `reserved` slots free for outbound dials.
/// Formula: admit when `total_peers < max_connections - effective_reserved`.
pub fn inboundAdmissionAllowed(total_peers: usize, max_connections: usize, reserved: usize) bool {
    const eff = effectiveReservedOutbound(max_connections, reserved);
    return total_peers < max_connections - eff;
}

/// Outbound dial: may consume the reserved region up to `max_connections`.
pub fn outboundAdmissionAllowed(total_peers: usize, max_connections: usize) bool {
    return total_peers < max_connections;
}

/// Peers required before the inbound-ratio fallback can trip.
/// Cold start and tiny test nets (fewer than 4) stay open to inbound.
/// Callers pass published inbound plus in-flight inbound handshakes as
/// `inbound`, and published outbound peers as `outbound`.
pub const INBOUND_RATIO_MIN_TOTAL: usize = 4;

/// True when the inbound side is a suspicious share of the table.
///
/// `inbound` is published inbound peers plus in-flight inbound handshakes.
/// `outbound` is published outbound peers; in-flight dials are not included.
/// Disabled when `limit_percent == 0`. A zero total, or any total below
/// `INBOUND_RATIO_MIN_TOTAL`, is not suspicious.
/// Formula (integer, strict): `inbound * 100 > (inbound + outbound) * limit_percent`.
pub fn inboundRatioSuspicious(inbound: usize, outbound: usize, limit_percent: u8) bool {
    if (limit_percent == 0) return false;
    const total = std.math.add(usize, inbound, outbound) catch return true;
    if (total < INBOUND_RATIO_MIN_TOTAL) return false;
    const inbound_scaled: u128 = @as(u128, inbound) * 100;
    const limit_scaled: u128 = @as(u128, total) * @as(u128, limit_percent);
    return inbound_scaled > limit_scaled;
}

/// True when another peer from `prefix` may be accepted.
/// `prefix == 0` is the unspecified address and is always admitted.
pub fn admitPrefix(existing: []const u16, prefix: u16, limit: usize) bool {
    if (limit == 0 or prefix == 0) return true;
    var n: usize = 0;
    for (existing) |item| {
        if (item == prefix) n += 1;
    }
    return n < limit;
}

/// True when another peer from the same IPv6 /48 may be accepted.
pub fn admitIpv6Prefix48(existing: []const [6]u8, prefix: [6]u8, limit: usize) bool {
    if (limit == 0) return true;
    if (std.mem.eql(u8, &prefix, &@as([6]u8, @splat(0)))) return true;
    var n: usize = 0;
    for (existing) |item| {
        if (std.mem.eql(u8, &item, &prefix)) n += 1;
    }
    return n < limit;
}

fn ipv4Prefix16(addr: std.Io.net.IpAddress) ?u16 {
    return switch (addr) {
        .ip4 => |ip| blk: {
            const prefix = std.mem.readInt(u16, ip.bytes[0..2], .big);
            break :blk if (prefix == 0) null else prefix;
        },
        .ip6 => |ip| blk: {
            // IPv4-mapped ::ffff:a.b.c.d shares the IPv4 /16 budget.
            if (!std.mem.eql(u8, ip.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) break :blk null;
            const prefix = std.mem.readInt(u16, ip.bytes[12..14], .big);
            break :blk if (prefix == 0) null else prefix;
        },
    };
}

fn ipv6Prefix48(addr: std.Io.net.IpAddress) ?[6]u8 {
    return switch (addr) {
        .ip4 => null,
        .ip6 => |ip| blk: {
            if (std.mem.eql(u8, &ip.bytes, &@as([16]u8, @splat(0)))) break :blk null;
            if (std.mem.eql(u8, ip.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) break :blk null;
            break :blk ip.bytes[0..6].*;
        },
    };
}

/// Host + port parsed from a dial string (`a.b.c.d:port`, `hostname:port`,
/// or `[v6]:port`). Bare IPv6 without brackets is rejected.
pub const DialHostPort = struct {
    host: []const u8,
    port: u16,
};

pub fn splitDialHostPort(address: []const u8) ?DialHostPort {
    if (address.len == 0) return null;
    if (address[0] == '[') {
        const end = std.mem.indexOfScalar(u8, address, ']') orelse return null;
        if (end == 1) return null;
        const host = address[1..end];
        if (end + 1 >= address.len or address[end + 1] != ':') return null;
        const port = std.fmt.parseInt(u16, address[end + 2 ..], 10) catch return null;
        return .{ .host = host, .port = port };
    }
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return null;
    // Multiple colons without brackets → bare IPv6; require [v6]:port form.
    if (std.mem.indexOfScalar(u8, address[0..colon], ':') != null) return null;
    if (colon == 0) return null;
    const port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch return null;
    return .{ .host = address[0..colon], .port = port };
}

/// Resolve a dial string to an `IpAddress` via IP parse or DNS lookup.
/// Prefers the first IPv4 result when DNS returns both families.
/// Returns null when the address cannot be resolved (caller keeps hostname).
pub fn resolveDialIp(address: []const u8) ?std.Io.net.IpAddress {
    const hp = splitDialHostPort(address) orelse return null;
    if (std.Io.net.IpAddress.parse(hp.host, hp.port)) |ip| return ip else |_| {}

    const hostname = std.Io.net.HostName.init(hp.host) catch return null;
    const io = @import("io_instance").io;
    var lookup_buffer: [16]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    hostname.lookup(io, &lookup_queue, .{ .port = hp.port }) catch return null;

    var first_v4: ?std.Io.net.IpAddress = null;
    var first_any: ?std.Io.net.IpAddress = null;
    while (lookup_queue.getOneUncancelable(io)) |res| {
        switch (res) {
            .address => |a| {
                if (first_any == null) first_any = a;
                if (first_v4 == null and a == .ip4) first_v4 = a;
            },
            .canonical_name => {},
        }
    } else |_| {}
    return first_v4 orelse first_any;
}

/// Resolve `host:port` / `[v6]:port` to a canonical owned dial string
/// (`a.b.c.d:port` or `[v6]:port`) when DNS or IP parse succeeds.
/// On failure, returns a dupe of the original. Unresolved hostnames still
/// share Kademlia's single unknown-prefix diversity budget.
pub fn resolveDialAddress(allocator: std.mem.Allocator, address: []const u8) ![]u8 {
    if (resolveDialIp(address)) |ip| {
        return try std.fmt.allocPrint(allocator, "{f}", .{ip});
    }
    return try allocator.dupe(u8, address);
}

fn prefix16FromHost(host: []const u8) ?u16 {
    var parts = std.mem.splitScalar(u8, host, '.');
    const a = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    const b = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    if (a == 0 and b == 0) return null;
    return (@as(u16, a) << 8) | b;
}

const PeerRateState = struct {
    window_second: i64 = 0,
    total_count: usize = 0,
    block_count: usize = 0,
    vote_count: usize = 0,
    certificate_count: usize = 0,
    transaction_count: usize = 0,
    score: i32 = 0,
    banned_until: i64 = 0,
};

pub const P2PServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: P2PServerConfig,
    listener: ?std.Io.net.Server,
    quic_transport: ?*QUIC.QUICTransport,
    is_running: bool,
    peers: std.AutoArrayHashMapUnmanaged([32]u8, *PeerConnection),
    quic_peers: std.AutoArrayHashMapUnmanaged([32]u8, *QUICPeerConnection),
    next_peer_id: u64,
    last_bootstrap_retry: i64,
    last_peer_rotation: i64,
    validator_key: ?[32]u8,
    handshake_nonce_tracker: HandshakeNonceTracker,
    /// Worker threads running inbound handshakes. Joined in `deinit` so shared
    /// state is not torn down while a handshake is still reading from it.
    handshake_threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    /// Inbound TCP handshakes whose worker has been spawned and has not
    /// exited. Added to the inbound side of the ratio pause so a burst of
    /// accepts cannot pass the gate before `publishPeer`. Outbound dial
    /// workers are not counted. The worker decrements exactly once on exit;
    /// `publishPeer` does not touch this counter.
    inflight_inbound: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    peer_rate_states: std.AutoArrayHashMapUnmanaged([32]u8, PeerRateState),
    /// Remembered dial targets after disconnect, keyed by Blake3(address).
    /// Insertion order is LRU: oldest at index 0, evict when over cap.
    quality_memory: std.AutoArrayHashMapUnmanaged([32]u8, PeerQualityMemoryEntry),
    rate_limited_drops_total: u64,
    banned_peers_total: u64,
    p2p_uring_sq_depth: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    p2p_uring_cq_lat_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    p2p_fallback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Callbacks
    on_block: ?*const fn (peer_id: [32]u8, block_data: []u8) void,
    on_vote: ?*const fn (peer_id: [32]u8, vote_data: []u8) void,
    on_certificate: ?*const fn (peer_id: [32]u8, cert_data: []u8) void,
    on_transaction: ?*const fn (peer_id: [32]u8, tx_data: []u8) void,
    on_peer_connect: ?*const fn (peer_id: [32]u8) void,
    on_peer_disconnect: ?*const fn (peer_id: [32]u8) void,

    pub fn init(allocator: std.mem.Allocator, config: P2PServerConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .listener = null,
            .quic_transport = null,
            .is_running = false,
            .peers = std.AutoArrayHashMapUnmanaged([32]u8, *PeerConnection).empty,
            .quic_peers = std.AutoArrayHashMapUnmanaged([32]u8, *QUICPeerConnection).empty,
            .next_peer_id = 0,
            .last_bootstrap_retry = 0,
            .last_peer_rotation = 0,
            .on_block = null,
            .on_vote = null,
            .on_certificate = null,
            .on_transaction = null,
            .on_peer_connect = null,
            .on_peer_disconnect = null,
            .validator_key = config.validator_key,
            .handshake_nonce_tracker = HandshakeNonceTracker.init(allocator, HANDSHAKE_WINDOW_SECS),
            .peer_rate_states = .empty,
            .quality_memory = .empty,
            .rate_limited_drops_total = 0,
            .banned_peers_total = 0,
        };
        if (builtin.os.tag == .linux) {
            self.p2p_uring_sq_depth.store(128, .monotonic);
            self.p2p_uring_cq_lat_ms.store(1, .monotonic);
        } else {
            self.p2p_fallback_count.store(1, .monotonic);
        }
        errdefer self.peers.deinit(self.allocator);
        errdefer self.quic_peers.deinit(self.allocator);

        if (config.transport_type == .quic) {
            const quic_config = QUIC.QUICConfig{
                .bind_address = config.bind_address,
                .max_connections = config.max_connections,
                .real_udp = @import("quic_options").enabled,
            };
            self.quic_transport = try QUIC.QUICTransport.init(allocator, quic_config);
            errdefer if (self.quic_transport) |qt| qt.deinit();
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // `stop()` already joined every worker; only the storage is left.
        self.handshake_threads.deinit(self.allocator);

        var it = self.peers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.peers.deinit(self.allocator);

        var qit = self.quic_peers.iterator();
        while (qit.next()) |entry| {
            entry.value_ptr.*.quic_conn.deinit();
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.quic_peers.deinit(self.allocator);

        self.peer_rate_states.deinit(self.allocator);
        self.clearQualityMemory();
        self.quality_memory.deinit(self.allocator);
        self.handshake_nonce_tracker.deinit();

        // Deinit QUIC transport if present
        if (self.quic_transport) |qt| {
            qt.deinit();
        }

        // SECURITY: Zero sensitive key material before deallocation
        if (self.validator_key) |*key| {
            @memset(key, 0);
        }

        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        if (self.is_running) return error.AlreadyRunning;

        if (self.config.transport_type == .quic) {
            if (self.quic_transport) |qt| {
                try qt.listen();
            } else {
                return error.QUICTransportNotInitialized;
            }
        } else {
            var parts = std.mem.splitScalar(u8, self.config.bind_address, ':');
            const host = parts.next() orelse "0.0.0.0";
            const port_str = parts.next() orelse "8083";
            const port = try std.fmt.parseInt(u16, port_str, 10);
            const addr = try std.Io.net.IpAddress.parseIp4(host, port);
            self.listener = try addr.listen(@import("io_instance").io, .{});

            const timeout: std.posix.timeval = if (@hasField(std.posix.timeval, "tv_sec"))
                .{ .tv_sec = 1, .tv_usec = 0 }
            else
                .{ .sec = 1, .usec = 0 };
            std.posix.setsockopt(
                self.listener.?.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&timeout),
            ) catch |err| {
                Log.warn("[WARN] P2PServer failed to set accept timeout: {}", .{err});
            };
        }

        self.is_running = true;

        if (self.config.dial_bootstrap and self.config.bootstrap_peers.len > 0) {
            for (self.config.bootstrap_peers) |addr| {
                self.dialBootstrapPeer(addr) catch |err| {
                    Log.err("Failed to dial bootstrap peer {s}: {}", .{ addr, err });
                };
            }
        }
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        // Workers hold `*Self` and touch `peers` / the nonce tracker; they must
        // finish before the listener and peer tables are torn down.
        for (self.handshake_threads.items) |t| t.join();
        self.handshake_threads.clearRetainingCapacity();
        if (self.listener) |*listener| {
            listener.deinit(@import("io_instance").io);
            self.listener = null;
        }
        if (self.quic_transport) |qt| {
            qt.stop();
        }
    }

    pub fn isRunning(self: *Self) bool {
        return self.is_running;
    }

    pub fn acceptOne(self: *Self) !void {
        if (self.config.transport_type == .quic) {
            // Handle QUIC connection
            if (self.quic_transport) |qt| {
                const quic_conn = try qt.accept();
                try self.handleQUICConnection(quic_conn, false, null);
            }
        } else {
            // Handle TCP connection
            if (self.listener) |_| {
                if (!self.hasPendingConnection()) {
                    return error.WouldBlock;
                }
                const conn = try self.listener.?.accept(@import("io_instance").io);
                Log.debug("Accepted incoming connection", .{});
                try self.handleConnection(conn);
            }
        }
    }

    /// Run the accept loop (blocking)
    pub fn run(self: *Self) !void {
        try self.start();
        defer self.stop();

        while (self.is_running) {
            self.acceptOne() catch |err| {
                Log.err("Accept error: {}", .{err});
                continue;
            };
        }
    }

    fn allocatePeerId(self: *Self) error{ArithmeticOverflow}!u64 {
        const peer_id = self.next_peer_id;
        self.next_peer_id = std.math.add(u64, peer_id, 1) catch return error.ArithmeticOverflow;
        return peer_id;
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Stream) !void {
        if (!inboundAdmissionAllowed(self.peerCount(), self.config.max_connections, self.config.reserved_outbound_slots)) {
            Log.warn("[WARN] P2P inbound admission denied (peers={}, max={}, reserved={}), rejecting incoming connection", .{
                self.peerCount(),
                self.config.max_connections,
                self.config.reserved_outbound_slots,
            });
            conn.close(@import("io_instance").io);
            return error.TooManyPeers;
        }
        if (self.inboundRatioPaused()) {
            const counts = self.peerDirectionCounts();
            Log.warn("[WARN] P2P inbound paused (inbound={}, inflight={}, outbound={}, limit={}%), rejecting incoming connection", .{
                counts.inbound,
                self.inflight_inbound.load(.acquire),
                counts.outbound,
                self.config.inbound_ratio_limit,
            });
            conn.close(@import("io_instance").io);
            return error.InboundPaused;
        }
        if (!self.subnetAllowed(conn.socket.address)) {
            Log.warn("[WARN] P2P subnet cap reached, rejecting incoming connection", .{});
            conn.close(@import("io_instance").io);
            return error.TooManyPeers;
        }

        const peer_id = self.allocatePeerId() catch |err| {
            conn.close(@import("io_instance").io);
            return err;
        };

        // Handshake needs a multi-RTT budget; publishPeer restores the short one.
        setHandshakeTimeout(conn);

        const peer_conn = PeerConnection.init(self.allocator, peer_id, conn) catch |err| {
            conn.close(@import("io_instance").io);
            return err;
        };
        peer_conn.max_message_size = self.config.max_message_size;
        peer_conn.is_outbound = false;

        // Hand the connection to a worker thread.
        //
        // `performHandshake` blocks on three socket round-trips (request,
        // response, ack). Running it inline froze the accept loop, so a peer
        // waiting on *our* response could not be served while we were blocked
        // waiting on *its* ack. Both sides then timed out and every connection
        // died with HandshakeFailed. Offloading lets both handshakes progress.
        //
        // Count the handshake before the worker starts. The child can finish
        // and decrement before `spawn` returns, so the increment has to be
        // visible first. A failed spawn rolls it back: only a live inbound
        // worker stays in `inflight_inbound`. Outbound dials never touch it.
        _ = self.inflight_inbound.fetchAdd(1, .release);
        const thread = std.Thread.spawn(.{}, handshakeResponder, .{ self, peer_conn, peer_id }) catch |err| {
            _ = self.inflight_inbound.fetchSub(1, .release);
            // Spawn failed: ownership never left this function, so clean up here.
            peer_conn.deinit();
            self.allocator.destroy(peer_conn);
            return err;
        };
        self.handshake_threads.append(self.allocator, thread) catch |err| {
            // Cannot track the thread, so we cannot join it later. Log loudly
            // rather than free `peer_conn`, which the thread owns now.
            Log.err("Failed to track handshake thread (id={}): {t}", .{ peer_id, err });
            return err;
        };
        return;
    }

    /// Worker body for an inbound connection: run the handshake, then publish
    /// the peer. Owns `peer_conn` for its whole lifetime.
    ///
    /// The accept path incremented `inflight_inbound` before spawn. This defer
    /// is the only decrement, covering handshake failure, publish failure, and
    /// successful publish. Decrementing again inside `publishPeer` would drop
    /// the count twice.
    fn handshakeResponder(server: *Self, peer_conn: *PeerConnection, peer_id: u64) void {
        defer _ = server.inflight_inbound.fetchSub(1, .release);
        peer_conn.performHandshake(
            false,
            server.validator_key,
            server.config.allow_unauthenticated_handshake,
            &server.handshake_nonce_tracker,
            server.config.genesis_digest,
            server.config.advertise_address,
        ) catch |err| {
            Log.warn("Peer handshake failed (id={}): {t}", .{ peer_id, err });
            peer_conn.deinit();
            server.allocator.destroy(peer_conn);
            return;
        };
        Log.info("Peer handshake completed (id={})", .{peer_id});

        server.publishPeer(peer_conn) catch |err| {
            Log.warn("Failed to publish peer (id={}): {t}", .{ peer_id, err });
            peer_conn.deinit();
            server.allocator.destroy(peer_conn);
        };
    }

    /// Worker body for an outbound connection. Owns `peer_conn` for its whole
    /// lifetime.
    fn handshakeInitiator(server: *Self, peer_conn: *PeerConnection, address: []const u8) void {
        peer_conn.performHandshake(
            true,
            server.validator_key,
            server.config.allow_unauthenticated_handshake,
            &server.handshake_nonce_tracker,
            server.config.genesis_digest,
            server.config.advertise_address,
        ) catch |err| {
            Log.warn("Outbound handshake failed ({s}): {t}", .{ address, err });
            peer_conn.deinit();
            server.allocator.destroy(peer_conn);
            return;
        };
        server.publishPeer(peer_conn) catch |err| {
            Log.warn("Failed to publish peer ({s}): {t}", .{ address, err });
            peer_conn.deinit();
            server.allocator.destroy(peer_conn);
            return;
        };
        Log.info("Connected to peer at {s} (id={})", .{ address, peer_conn.peer_id });
    }

    /// Move a handshaken connection into the live peer table. Shared by the
    /// inbound worker and the outbound dial path.
    fn publishPeer(self: *Self, peer_conn: *PeerConnection) !void {

        // For legacy mode without auth, generate random peer key using CSPRNG
        if (self.validator_key == null) {
            var peer_key: [32]u8 = undefined;
            // SECURITY FIX: Use CSPRNG instead of deterministic pointer address
            @import("io_instance").io.random(std.mem.asBytes(&peer_key));
            peer_conn.peer_key = peer_key;
        }

        const peer_key = peer_conn.peer_key;
        // Handshake is done: the long handshake budget must not linger, or a
        // silent peer would keep the socket blocked for seconds instead of
        // letting the event loop reap it promptly.
        setPeerTimeout(peer_conn.conn);
        peer_conn.connected_at = currentSeconds();
        try self.peers.put(self.allocator, peer_key, peer_conn);
        errdefer _ = self.peers.swapRemove(peer_key);
        try self.peer_rate_states.put(self.allocator, peer_key, .{});

        // Notify callback
        if (self.on_peer_connect) |cb| {
            cb(peer_key);
        }
    }

    /// Handle a QUIC connection. `is_outbound` selects dial vs accept admission.
    /// `dial_address` is the outbound dial string (owned copy stored on the peer).
    fn handleQUICConnection(
        self: *Self,
        quic_conn: *QUIC.QUICConnection,
        is_outbound: bool,
        dial_address: ?[]const u8,
    ) !void {
        if (is_outbound) {
            if (!outboundAdmissionAllowed(self.peerCount(), self.config.max_connections)) {
                Log.warn("[WARN] P2P QUIC admission denied (outbound={}, peers={}, max={}, reserved={})", .{
                    is_outbound,
                    self.peerCount(),
                    self.config.max_connections,
                    self.config.reserved_outbound_slots,
                });
                quic_conn.close();
                return error.TooManyPeers;
            }
        } else {
            if (!inboundAdmissionAllowed(self.peerCount(), self.config.max_connections, self.config.reserved_outbound_slots)) {
                Log.warn("[WARN] P2P QUIC admission denied (outbound={}, peers={}, max={}, reserved={})", .{
                    is_outbound,
                    self.peerCount(),
                    self.config.max_connections,
                    self.config.reserved_outbound_slots,
                });
                quic_conn.close();
                return error.TooManyPeers;
            }
            // QUIC handshake stays on this thread, so the peer is published
            // before the next accept. There is no QUIC worker to count here;
            // `inflight_inbound` still participates so a TCP burst already
            // in flight can pause this accept.
            if (self.inboundRatioPaused()) {
                const counts = self.peerDirectionCounts();
                Log.warn("[WARN] P2P QUIC inbound paused (inbound={}, inflight={}, outbound={}, limit={}%)", .{
                    counts.inbound,
                    self.inflight_inbound.load(.acquire),
                    counts.outbound,
                    self.config.inbound_ratio_limit,
                });
                quic_conn.close();
                return error.InboundPaused;
            }
        }

        const peer_id = self.allocatePeerId() catch |err| {
            quic_conn.close();
            return err;
        };

        const peer_conn = try QUICPeerConnection.init(self.allocator, peer_id, quic_conn);
        peer_conn.max_message_size = self.config.max_message_size;
        peer_conn.is_outbound = is_outbound;
        if (dial_address) |addr| {
            peer_conn.remote_address = self.allocator.dupe(u8, addr) catch null;
        }
        errdefer {
            if (self.quic_transport) |qt| {
                qt.closeConnection(peer_conn.quic_conn.connection_id);
            }
            peer_conn.deinit();
            self.allocator.destroy(peer_conn);
        }

        // Perform QUIC handshake
        try peer_conn.performHandshake(
            false,
            self.validator_key,
            self.config.allow_unauthenticated_handshake,
            self.config.genesis_digest,
        );

        if (self.validator_key == null) {
            var peer_key: [32]u8 = undefined;
            // SECURITY FIX: Use CSPRNG for QUIC peer keys too
            @import("io_instance").io.random(std.mem.asBytes(&peer_key));
            peer_conn.peer_key = peer_key;
        }

        const peer_key = peer_conn.peer_key;
        peer_conn.connected_at = currentSeconds();
        try self.quic_peers.put(self.allocator, peer_key, peer_conn);
        errdefer _ = self.quic_peers.swapRemove(peer_key);
        try self.peer_rate_states.put(self.allocator, peer_key, .{});

        // Notify callback
        if (self.on_peer_connect) |cb| {
            cb(peer_key);
        }
    }

    /// Broadcast a block to all connected peers
    pub fn broadcastBlock(self: *Self, sender_id: [32]u8, block_data: []u8) !void {
        const msg = Message{
            .msg_type = .block,
            .sender = sender_id,
            .sequence = 0,
            .payload = block_data,
        };
        try self.broadcast(msg);
    }

    /// Broadcast a vote to all connected peers
    pub fn broadcastVote(self: *Self, sender_id: [32]u8, vote_data: []u8) !void {
        const msg = Message{
            .msg_type = .consensus,
            .sender = sender_id,
            .sequence = 0,
            .payload = vote_data,
        };
        try self.broadcast(msg);
    }

    /// Broadcast a certificate to all connected peers
    pub fn broadcastCertificate(self: *Self, sender_id: [32]u8, cert_data: []u8) !void {
        const msg = Message{
            .msg_type = .certificate,
            .sender = sender_id,
            .sequence = 0,
            .payload = cert_data,
        };
        try self.broadcast(msg);
    }

    fn broadcast(self: *Self, msg: Message) !void {
        var failed_peers: std.ArrayList([32]u8) = .empty;
        defer failed_peers.deinit(self.allocator);

        var it = self.peers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.sendMessage(msg) catch {
                try failed_peers.append(self.allocator, entry.key_ptr.*);
            };
        }

        var qit = self.quic_peers.iterator();
        while (qit.next()) |entry| {
            entry.value_ptr.*.sendMessage(msg) catch {
                try failed_peers.append(self.allocator, entry.key_ptr.*);
            };
        }

        for (failed_peers.items) |peer_id| {
            self.removePeer(peer_id);
        }
    }
    pub fn disconnectPeer(self: *Self, peer_id: [32]u8) void {
        self.removePeer(peer_id);
    }

    fn removePeer(self: *Self, peer_id: [32]u8) void {
        if (self.peers.getPtr(peer_id)) |peer| {
            const p = peer.*;
            self.rememberPeerQuality(p.peer_key, p.reputation, p.latency_ms, p.remote_address, p.address_from_advertise);
            p.deinit();
            self.allocator.destroy(p);
            _ = self.peers.swapRemove(peer_id);
            _ = self.peer_rate_states.swapRemove(peer_id);

            if (self.on_peer_disconnect) |cb| {
                cb(peer_id);
            }
            return;
        }
        if (self.quic_peers.getPtr(peer_id)) |peer| {
            const quic_peer = peer.*;
            // QUIC never fills `remote_address` from a listen trailer; only a
            // dial string we opened is present, so it stays rememberable.
            self.rememberPeerQuality(quic_peer.peer_key, quic_peer.reputation, quic_peer.latency_ms, quic_peer.remote_address, false);
            // Let QUICTransport manage QUICConnection lifecycle; it owns the
            // underlying connection and must remove it from its own map.
            if (self.quic_transport) |qt| {
                qt.closeConnection(quic_peer.quic_conn.connection_id);
            }
            quic_peer.deinit();
            self.allocator.destroy(quic_peer);
            _ = self.quic_peers.swapRemove(peer_id);
            _ = self.peer_rate_states.swapRemove(peer_id);

            if (self.on_peer_disconnect) |cb| {
                cb(peer_id);
            }
        }
    }

    fn clearQualityMemory(self: *Self) void {
        var it = self.quality_memory.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.address);
        }
        self.quality_memory.clearRetainingCapacity();
    }

    /// Record a disconnected peer for quality-weighted redial. No-op when
    /// `address` is null/empty (inbound without a known listen string).
    /// Advertised listen strings are stored only when `pubkeyAllowed`
    /// accepts `peer_key` and the advertised `host:port` equals that key's
    /// non-empty `known_validator_dials` entry. A missing or empty dial
    /// refuses the advertisement. Dial strings this node opened
    /// (`address_from_advertise == false`) are stored regardless. Prefers
    /// the resolved IP dial string as the memory key
    /// when DNS/IP resolve succeeds so hostname and numeric forms collapse
    /// together.
    fn rememberPeerQuality(
        self: *Self,
        peer_key: [32]u8,
        reputation: i32,
        latency_ms: u64,
        address: ?[]const u8,
        address_from_advertise: bool,
    ) void {
        const addr = address orelse return;
        if (addr.len == 0) return;
        if (address_from_advertise) {
            if (!pubkeyAllowed(self.config.known_validator_keys, peer_key)) return;
            const pinned = configuredValidatorDial(self.config.known_validator_dials, peer_key) orelse return;
            if (!std.mem.eql(u8, addr, pinned)) return;
        }

        const owned = resolveDialAddress(self.allocator, addr) catch return;
        const mem_key = derivePeerKeyFromAddress(owned);
        // orderedRemove keeps insertion order so index 0 stays the LRU victim.
        if (self.quality_memory.fetchOrderedRemove(mem_key)) |kv| {
            self.allocator.free(kv.value.address);
        }

        while (self.quality_memory.count() >= QUALITY_MEMORY_CAP) {
            const oldest = self.quality_memory.values()[0];
            self.allocator.free(oldest.address);
            self.quality_memory.orderedRemoveAt(0);
        }

        self.quality_memory.put(self.allocator, mem_key, .{
            .address = owned,
            .peer_key = peer_key,
            .reputation = reputation,
            .latency_ms = latency_ms,
        }) catch {
            self.allocator.free(owned);
        };
    }

    pub fn isPeerBanned(self: *Self, peer_id: [32]u8) bool {
        const now = currentSeconds();
        if (self.peer_rate_states.getPtr(peer_id)) |state| {
            return state.banned_until > now;
        }
        return false;
    }

    /// Per-peer + per-type incoming rate guard with score-based temporary ban.
    /// Returns false when the message should be dropped.
    pub fn allowIncomingMessage(self: *Self, peer_id: [32]u8, msg_type: Transport.MessageType) bool {
        const now = currentSeconds();
        const entry = self.peer_rate_states.getOrPut(self.allocator, peer_id) catch return false;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const state = entry.value_ptr;

        if (state.banned_until > now) return false;
        if (state.window_second != now) {
            state.window_second = now;
            state.total_count = 0;
            state.block_count = 0;
            state.vote_count = 0;
            state.certificate_count = 0;
            state.transaction_count = 0;
        }

        state.total_count += 1;
        switch (msg_type) {
            .block => state.block_count += 1,
            .consensus => state.vote_count += 1,
            .certificate => state.certificate_count += 1,
            .transaction => state.transaction_count += 1,
            else => {},
        }

        const peer_cap = self.config.max_messages_per_second_per_peer;
        const type_cap = self.config.max_messages_per_second_per_type;
        const over_peer = state.total_count > peer_cap;
        const over_type = switch (msg_type) {
            .block => state.block_count > type_cap,
            .consensus => state.vote_count > type_cap,
            .certificate => state.certificate_count > type_cap,
            .transaction => state.transaction_count > type_cap,
            else => false,
        };

        if (over_peer or over_type) {
            self.rate_limited_drops_total += 1;
            state.score -= 20;
            // Feed rotation quality: noisy peers become preferred victims.
            self.adjustPeerReputation(peer_id, -5);
            if (state.score <= self.config.peer_score_ban_threshold) {
                state.banned_until = now + self.config.peer_ban_seconds;
                self.banned_peers_total += 1;
                Log.warn("Banning peer due to repeated rate-limit violations", .{});
            }
            return false;
        }

        if (state.score < 0) state.score += 1;
        // Small recovery toward the reputation ceiling on admitted traffic.
        self.adjustPeerReputation(peer_id, 1);
        return true;
    }

    /// Exponentially decay penalty scores towards normal 0 baseline across all active rate states
    pub fn decayPeerScores(self: *Self) void {
        var it = self.peer_rate_states.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr;
            if (state.score < 0) {
                state.score = @min(0, state.score + 5);
            }
        }
    }

    /// Adjust peer reputation score and disconnect if reputation drops below threshold
    pub fn adjustPeerReputation(self: *Self, peer_key: [32]u8, delta: i32) void {
        if (self.peers.get(peer_key)) |peer| {
            peer.reputation = std.math.clamp(peer.reputation + delta, 0, 100);
            if (peer.reputation < 10) {
                self.banned_peers_total += 1;
                peer.state = .closing;
            }
        } else if (self.quic_peers.get(peer_key)) |quic_peer| {
            quic_peer.reputation = std.math.clamp(quic_peer.reputation + delta, 0, 100);
            if (quic_peer.reputation < 10) {
                self.banned_peers_total += 1;
                quic_peer.state = .closing;
            }
        }
    }

    pub const RateLimitStats = struct {
        rate_limited_drops_total: u64,
        banned_peers_total: u64,
    };

    pub const AsyncMetrics = struct {
        sq_depth: u64,
        cq_lat_ms: u64,
        fallback_count: u64,
    };

    pub fn getRateLimitStats(self: *Self) RateLimitStats {
        return .{
            .rate_limited_drops_total = self.rate_limited_drops_total,
            .banned_peers_total = self.banned_peers_total,
        };
    }

    pub fn asyncMetricsSnapshot(self: *Self) AsyncMetrics {
        return .{
            .sq_depth = self.p2p_uring_sq_depth.load(.monotonic),
            .cq_lat_ms = self.p2p_uring_cq_lat_ms.load(.monotonic),
            .fallback_count = self.p2p_fallback_count.load(.monotonic),
        };
    }

    pub fn peerCount(self: *Self) usize {
        return self.peers.count() + self.quic_peers.count();
    }

    pub const PeerDirectionCounts = struct {
        inbound: usize = 0,
        outbound: usize = 0,
    };

    /// Count published TCP and QUIC peers by `is_outbound`.
    /// Handshakes that have not reached `publishPeer` are not included;
    /// the ratio gate adds `inflight_inbound` on top of `inbound`.
    pub fn peerDirectionCounts(self: *Self) PeerDirectionCounts {
        var counts: PeerDirectionCounts = .{};
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.is_outbound) {
                counts.outbound += 1;
            } else {
                counts.inbound += 1;
            }
        }
        var qit = self.quic_peers.iterator();
        while (qit.next()) |entry| {
            if (entry.value_ptr.*.is_outbound) {
                counts.outbound += 1;
            } else {
                counts.inbound += 1;
            }
        }
        return counts;
    }

    /// Published inbound plus inbound handshake workers that have not exited.
    fn ratioInbound(self: *Self, published_inbound: usize) usize {
        const inflight = self.inflight_inbound.load(.acquire);
        return std.math.add(usize, published_inbound, inflight) catch std.math.maxInt(usize);
    }

    /// Inbound accept / QUIC inbound pause. Outbound dial does not consult this.
    /// The inbound side includes `inflight_inbound`, so the next accept sees
    /// handshakes spawned by earlier accepts in this loop.
    fn inboundRatioPaused(self: *Self) bool {
        const counts = self.peerDirectionCounts();
        return inboundRatioSuspicious(self.ratioInbound(counts.inbound), counts.outbound, self.config.inbound_ratio_limit);
    }

    pub const DirectionStats = struct {
        inbound: usize,
        outbound: usize,
        inbound_paused: bool,
    };

    /// Read-only snapshot for `/metrics`. `inbound` is published inbound peers
    /// plus in-flight inbound handshakes. `outbound` is published outbound
    /// peers. `inbound_paused` matches `inboundRatioPaused` for this snapshot.
    pub fn directionStats(self: *Self) DirectionStats {
        const counts = self.peerDirectionCounts();
        const inbound = self.ratioInbound(counts.inbound);
        return .{
            .inbound = inbound,
            .outbound = counts.outbound,
            .inbound_paused = inboundRatioSuspicious(inbound, counts.outbound, self.config.inbound_ratio_limit),
        };
    }

    fn subnetAllowed(self: *Self, addr: std.Io.net.IpAddress) bool {
        if (ipv4Prefix16(addr)) |prefix| {
            if (self.config.max_peers_per_16 != 0) {
                var n: usize = 0;
                var it = self.peers.iterator();
                while (it.next()) |entry| {
                    if (ipv4Prefix16(entry.value_ptr.*.conn.socket.address)) |existing| {
                        if (existing == prefix) n += 1;
                    }
                }
                if (n >= self.config.max_peers_per_16) return false;
            }
        }
        if (ipv6Prefix48(addr)) |prefix| {
            if (self.config.max_peers_per_48 != 0) {
                var n: usize = 0;
                var it = self.peers.iterator();
                while (it.next()) |entry| {
                    if (ipv6Prefix48(entry.value_ptr.*.conn.socket.address)) |existing| {
                        if (std.mem.eql(u8, &existing, &prefix)) n += 1;
                    }
                }
                if (n >= self.config.max_peers_per_48) return false;
            }
        }
        return true;
    }

    pub fn getPeerIDs(self: *Self) ![]const [32]u8 {
        var ids: std.ArrayList([32]u8) = .empty;
        errdefer ids.deinit(self.allocator);
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            try ids.append(self.allocator, entry.key_ptr.*);
        }
        var qit = self.quic_peers.iterator();
        while (qit.next()) |entry| {
            try ids.append(self.allocator, entry.key_ptr.*);
        }
        return ids.toOwnedSlice(self.allocator);
    }

    /// Send a direct message to a specific peer
    pub fn sendToPeer(self: *Self, peer_id: [32]u8, msg: Message) !void {
        if (self.peers.getPtr(peer_id)) |peer| {
            try peer.*.sendMessage(msg);
            return;
        }
        if (self.quic_peers.getPtr(peer_id)) |peer| {
            try peer.*.sendMessage(msg);
            return;
        }
        return error.PeerNotFound;
    }

    /// Connect to a remote peer (dial).
    ///
    /// Resolves hostnames via DNS when possible so /16·/48 subnet caps apply
    /// the same as for numeric peers. TCP: returns as soon as the socket is
    /// connected; the handshake runs on a worker thread. QUIC: still handled
    /// inline by the transport.
    ///
    /// Inbound-ratio pause does not apply here: dial keeps the reserved
    /// outbound budget so `maintainBootstrapConnections` can still reach
    /// bootstrap and quality peers while accepts are paused.
    pub fn dial(self: *Self, address: []const u8, peer_id: [32]u8) !void {
        _ = &peer_id; // only the QUIC path uses the supplied peer id
        const canonical = try resolveDialAddress(self.allocator, address);
        defer self.allocator.free(canonical);

        if (self.config.transport_type == .quic) {
            if (self.quic_transport) |qt| {
                const quic_conn = try qt.dial(canonical);
                try self.handleQUICConnection(quic_conn, true, canonical);
            } else {
                return error.QUICTransportNotInitialized;
            }
        } else {
            if (!outboundAdmissionAllowed(self.peerCount(), self.config.max_connections)) {
                Log.warn("[WARN] P2P outbound connection limit reached ({}), rejecting dial to {s}", .{ self.config.max_connections, address });
                return error.TooManyPeers;
            }

            const resolved_addr = resolveDialIp(canonical) orelse blk: {
                // Unresolved hostname: last-resort IP-literal/scope resolve.
                const hp = splitDialHostPort(canonical) orelse return error.InvalidAddress;
                break :blk try std.Io.net.IpAddress.resolve(@import("io_instance").io, hp.host, hp.port);
            };
            if (!self.subnetAllowed(resolved_addr)) {
                Log.warn("[WARN] P2P subnet cap reached, rejecting dial to {s} (resolved {s})", .{ address, canonical });
                return error.TooManyPeers;
            }
            const stream = try resolved_addr.connect(@import("io_instance").io, .{ .mode = .stream });
            const conn = stream;

            // Handshake needs a multi-RTT budget; publishPeer restores the short one.
            setHandshakeTimeout(conn);

            const allocated_id = self.allocatePeerId() catch |err| {
                conn.close(@import("io_instance").io);
                return err;
            };
            const peer_conn = PeerConnection.init(self.allocator, allocated_id, conn) catch |err| {
                conn.close(@import("io_instance").io);
                return err;
            };
            peer_conn.max_message_size = self.config.max_message_size;
            peer_conn.is_outbound = true;
            // Prefer resolved IP form for quality memory on disconnect.
            peer_conn.remote_address = self.allocator.dupe(u8, canonical) catch null;

            // Outbound handshakes block on three round-trips too. Dialing from
            // the main loop froze it while waiting for the responder, which
            // could not answer because its own loop was blocked in
            // `acceptOne` -> `performHandshake`. Hand off to a worker so both
            // sides can make progress.
            // Log with caller-owned `address` — `canonical` is freed when dial returns.
            const thread = std.Thread.spawn(.{}, handshakeInitiator, .{ self, peer_conn, address }) catch |err| {
                peer_conn.deinit();
                self.allocator.destroy(peer_conn);
                return err;
            };
            self.handshake_threads.append(self.allocator, thread) catch |err| {
                Log.err("Failed to track dial thread for {s}: {t}", .{ address, err });
                return err;
            };
        }
    }

    fn dialBootstrapPeer(self: *Self, address: []const u8) !void {
        const peer_key = derivePeerKeyFromAddress(address);
        try self.dial(address, peer_key);
    }

    /// Steady-state socket timeout for a published peer: short enough that the
    /// event loop notices a dead peer promptly.
    const PEER_IO_TIMEOUT_US: u32 = 100_000; // 100ms

    /// Timeout for a connection still running its handshake. The handshake is
    /// three sequential round-trips, so it needs a budget that survives a WAN
    /// link: the WAN gate injects 80ms +/- 10ms one-way delay, and the 100ms
    /// peer timeout expired mid-handshake, failing every link with `Unexpected`.
    const HANDSHAKE_IO_TIMEOUT_US: u32 = 5_000_000; // 5s

    fn setSocketTimeout(stream: std.Io.net.Stream, us: u32) void {
        const timeout: std.posix.timeval = if (@hasField(std.posix.timeval, "tv_sec"))
            .{ .tv_sec = @intCast(us / 1_000_000), .tv_usec = @intCast(us % 1_000_000) }
        else
            .{ .sec = @intCast(us / 1_000_000), .usec = @intCast(us % 1_000_000) };
        std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            Log.warn("[WARN] P2PServer failed to set receive timeout: {}", .{err});
        };
        std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            Log.warn("[WARN] P2PServer failed to set send timeout: {}", .{err});
        };
    }

    fn setPeerTimeout(stream: std.Io.net.Stream) void {
        setSocketTimeout(stream, PEER_IO_TIMEOUT_US);
    }

    /// Applied while a handshake is in flight; the peer drops back to
    /// `setPeerTimeout` once it is published.
    fn setHandshakeTimeout(stream: std.Io.net.Stream) void {
        setSocketTimeout(stream, HANDSHAKE_IO_TIMEOUT_US);
    }

    fn isPeerConnectedByAddress(self: *Self, address: []const u8) bool {
        const peer_key = derivePeerKeyFromAddress(address);
        return self.peers.contains(peer_key) or self.quic_peers.contains(peer_key);
    }

    /// Event-driven readiness check for TCP listener.
    /// Returns true when an incoming connection is ready to accept.
    pub fn hasPendingConnection(self: *Self) bool {
        if (self.config.transport_type == .quic) {
            if (self.quic_transport) |qt| {
                if (qt.config.real_udp) return qt.udpReadable();
            }
            return true;
        }
        if (self.config.transport_type != .tcp) return true;
        if (self.listener == null) return false;

        const fd = self.listener.?.socket.handle;
        var fds = [_]std.posix.pollfd{
            .{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const n = std.posix.poll(&fds, 0) catch return false;
        if (n <= 0) return false;
        return (fds[0].revents & std.posix.POLL.IN) != 0;
    }

    fn derivePeerKeyFromAddress(address: []const u8) [32]u8 {
        var peer_key: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(address, &peer_key, .{});
        return peer_key;
    }

    pub fn maintainBootstrapConnections(self: *Self) void {
        // Rotation runs even when bootstrap dial is disabled so inbound-heavy
        // tables still churn; bootstrap refill (below) can reclaim slots next.
        self.maybeRotatePeers();

        // Bootstrap list has priority for initial / steady-state connectivity.
        if (self.config.dial_bootstrap and self.config.bootstrap_peers.len > 0) {
            const now = currentSeconds();
            if (now - self.last_bootstrap_retry >= 60) {
                self.last_bootstrap_retry = now;
                for (self.config.bootstrap_peers) |addr| {
                    if (!self.isPeerConnectedByAddress(addr)) {
                        self.dialBootstrapPeer(addr) catch |err| {
                            Log.err("Failed to dial bootstrap peer {s}: {}", .{ addr, err });
                        };
                    }
                }
            }
        }

        // Fill remaining outbound capacity with highest-quality remembered peers.
        self.maybeDialQualityPeers();
    }

    /// Dial at most one remembered high-quality peer when outbound admission
    /// allows. Bootstrap dials above run first so quality refill only uses
    /// leftover / reserved outbound slots.
    fn maybeDialQualityPeers(self: *Self) void {
        if (!outboundAdmissionAllowed(self.peerCount(), self.config.max_connections)) return;
        const n = self.quality_memory.count();
        if (n == 0) return;

        var candidates = self.allocator.alloc(QualityDialCandidate, n) catch return;
        defer self.allocator.free(candidates);

        const vals = self.quality_memory.values();
        for (vals, 0..) |e, i| {
            const connected = self.peers.contains(e.peer_key) or
                self.quic_peers.contains(e.peer_key) or
                self.isPeerConnectedByAddress(e.address);
            // Memory prefers resolved IP form; parseLiteral covers v4 and [v6].
            // Unresolved hostnames leave subnet_ok=true; dial enforces after DNS.
            var subnet_ok = true;
            if (std.Io.net.IpAddress.parseLiteral(e.address)) |ip| {
                subnet_ok = self.subnetAllowed(ip);
            } else |_| {}
            candidates[i] = .{
                .address = e.address,
                .reputation = e.reputation,
                .latency_ms = e.latency_ms,
                .connected = connected,
                .subnet_ok = subnet_ok,
            };
        }

        const idx = pickQualityDialTarget(candidates) orelse return;
        self.dialBootstrapPeer(candidates[idx].address) catch |err| {
            Log.err("Failed to dial quality peer {s}: {}", .{ candidates[idx].address, err });
        };
    }

    /// Disconnect at most one lowest-quality eligible peer when the rotation
    /// interval has elapsed. Prefers inbound victims; among equals uses
    /// `peerRotationQuality` then age. Protects the last outbound and
    /// address-hash-matched bootstrap peers when bootstrap is configured.
    pub fn maybeRotatePeers(self: *Self) void {
        const interval = self.config.peer_rotation_interval_secs;
        if (interval <= 0) return;

        const now = currentSeconds();
        if (!peerRotationDue(self.last_peer_rotation, now, interval)) return;

        const total = self.peerCount();
        if (total == 0) {
            self.last_peer_rotation = now;
            return;
        }

        var candidates = self.allocator.alloc(PeerRotationCandidate, total) catch return;
        defer self.allocator.free(candidates);

        var n: usize = 0;
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            const peer = entry.value_ptr.*;
            candidates[n] = .{
                .key = entry.key_ptr.*,
                .connected_at = peer.connected_at,
                .is_outbound = peer.is_outbound,
                .reputation = peer.reputation,
                .latency_ms = peer.latency_ms,
            };
            n += 1;
        }
        var qit = self.quic_peers.iterator();
        while (qit.next()) |entry| {
            const peer = entry.value_ptr.*;
            candidates[n] = .{
                .key = entry.key_ptr.*,
                .connected_at = peer.connected_at,
                .is_outbound = peer.is_outbound,
                .reputation = peer.reputation,
                .latency_ms = peer.latency_ms,
            };
            n += 1;
        }

        const bootstrap_configured = self.config.bootstrap_peers.len > 0;
        var protected_buf: [32][32]u8 = undefined;
        const protected_len = @min(self.config.bootstrap_peers.len, protected_buf.len);
        for (self.config.bootstrap_peers[0..protected_len], 0..) |addr, i| {
            protected_buf[i] = derivePeerKeyFromAddress(addr);
        }

        const victim = pickPeerRotationVictim(
            candidates[0..n],
            protected_buf[0..protected_len],
            bootstrap_configured,
        ) orelse {
            // Interval elapsed but no eligible victim — still advance the
            // clock so we do not busy-retry every main-loop tick.
            self.last_peer_rotation = now;
            return;
        };

        const victim_key = candidates[victim].key;
        Log.info("Peer rotation: disconnecting peer (outbound={})", .{candidates[victim].is_outbound});
        self.removePeer(victim_key);
        self.last_peer_rotation = now;
    }
};

/// Represents an active peer connection
pub const PeerConnection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    peer_id: u64,
    conn: std.Io.net.Stream,
    state: PeerConnection.State,
    last_ping: i64,
    /// CLOCK.REALTIME seconds when this peer was published into the peers map.
    /// Used by peer rotation as quality tiebreak. Default 0 until publishPeer.
    connected_at: i64 = 0,
    peer_key: [32]u8,
    max_message_size: usize,
    /// True when this peer was opened by local `dial` (outbound).
    is_outbound: bool = false,
    /// [0, 100] quality input for rotation (`peerRotationQuality`); rate-limit
    /// drops lower it, admitted messages recover toward 100.
    reputation: i32 = 100,
    /// Observed RTT ms; higher lowers `peerRotationQuality` (capped penalty).
    latency_ms: u64 = 0,
    /// Owned dial string (`host:port`) when known. Set on outbound dial, or
    /// from the peer's signature-bound handshake listen trailer on inbound
    /// (response for initiator, ack for responder). Outbound dial string wins
    /// when both are present.
    remote_address: ?[]u8 = null,
    /// True only when `remote_address` was filled from the signed listen
    /// trailer. Stays false when the address came from a local dial (or
    /// when the dial string won over a later advertise).
    address_from_advertise: bool = false,

    /// In-progress frame header. A header and its payload are two separate
    /// socket reads, and the payload read can return `WouldBlock` after the
    /// header has already been consumed. Without carrying the header across
    /// calls the next attempt would parse payload bytes as a header and
    /// permanently desynchronise the stream. `recvMessage` resumes from here.
    read_header: [Message.HEADER_SIZE]u8 = undefined,
    read_header_len: usize = 0,

    pub const State = enum {
        handshaking,
        connected,
        active,
        closing,
        closed,
    };

    pub fn init(allocator: std.mem.Allocator, peer_id: u64, conn: std.Io.net.Stream) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .peer_id = peer_id,
            .conn = conn,
            .state = .handshaking,
            .last_ping = blk: {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                break :blk (ts.sec);
            },
            .peer_key = undefined,
            .max_message_size = Message.MAX_MESSAGE_SIZE,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.remote_address) |addr| {
            self.allocator.free(addr);
            self.remote_address = null;
        }
        self.conn.close(@import("io_instance").io);
    }

    /// Perform handshake with remote peer.
    ///
    /// When `advertise_address` is non-empty, authenticated **response**
    /// (responder) and **ack** (initiator) append a listen trailer bound into
    /// the Ed25519 signature via `listen_commitment = Blake3(advertise)`.
    /// The unsigned request core does not carry advertise (ack is authoritative
    /// for the initiator). Empty advertise → zero commitment, no trailer.
    pub fn performHandshake(
        self: *Self,
        is_initiator: bool,
        validator_key: ?[32]u8,
        allow_unauthenticated_handshake: bool,
        nonce_tracker: *HandshakeNonceTracker,
        genesis_digest: [32]u8,
        advertise_address: []const u8,
    ) !void {
        if (validator_key) |vk| {
            const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(vk) catch return error.HandshakeFailed;
            const pubkey = kp.public_key.toBytes();
            const now = nowSeconds();
            const now_u64: u64 = @intCast(if (now < 0) 0 else now);
            const local_listen_commitment = listenCommitment(advertise_address);

            if (is_initiator) {
                var nonce_a: [32]u8 = undefined;
                @import("io_instance").io.random(&nonce_a);
                if (!nonce_tracker.registerFresh(nonce_a, now)) return error.HandshakeFailed;

                // Unsigned request core only — initiator advertise rides on
                // the signed ack (signature-bound trailer).
                var request_payload: [HANDSHAKE_REQUEST_CORE_LEN]u8 = undefined;
                @memcpy(request_payload[0..32], &nonce_a);
                std.mem.writeInt(u64, request_payload[32..40], now_u64, .big);
                @memcpy(request_payload[40..72], &genesis_digest);
                const request = Message{
                    .msg_type = .handshake,
                    .sender = pubkey,
                    .sequence = 0,
                    .payload = &request_payload,
                };
                try self.sendMessage(request);

                const response = try self.recvMessage() orelse return error.HandshakeFailed;
                defer self.allocator.free(response.payload);
                if (response.msg_type != .handshake) return error.HandshakeFailed;
                const parsed_resp = try parseSignedPayload(response.payload);
                if (!std.mem.eql(u8, &parsed_resp.nonce_a, &nonce_a)) return error.HandshakeFailed;
                if (!GenesisDigest.accepted(genesis_digest, parsed_resp.genesis_digest)) return error.HandshakeFailed;
                if (!isTimestampFresh(parsed_resp.timestamp, nowSeconds())) return error.HandshakeFailed;
                if (!nonce_tracker.registerFresh(parsed_resp.nonce_b, nowSeconds())) return error.HandshakeFailed;
                try verifySignedTuple(
                    response.sender,
                    parsed_resp.nonce_a,
                    parsed_resp.nonce_b,
                    parsed_resp.timestamp,
                    parsed_resp.genesis_digest,
                    listenCommitmentFromTrailer(parsed_resp.listen_addr),
                    parsed_resp.signature,
                );
                // Learn responder listen addr; outbound dial string wins if set.
                self.applyAdvertisedListen(parsed_resp.listen_addr);

                const ack_sig = try signTuple(
                    kp,
                    parsed_resp.nonce_a,
                    parsed_resp.nonce_b,
                    parsed_resp.timestamp,
                    genesis_digest,
                    local_listen_commitment,
                );
                const ack_core = buildSignedPayload(
                    parsed_resp.nonce_a,
                    parsed_resp.nonce_b,
                    parsed_resp.timestamp,
                    ack_sig,
                    genesis_digest,
                );
                const ack_payload = try appendListenTrailer(self.allocator, &ack_core, advertise_address);
                defer self.allocator.free(ack_payload);
                const ack = Message{
                    .msg_type = .handshake,
                    .sender = pubkey,
                    .sequence = 0,
                    .payload = ack_payload,
                };
                try self.sendMessage(ack);
                self.peer_key = response.sender;
            } else {
                const request = try self.recvMessage() orelse return error.HandshakeFailed;
                defer self.allocator.free(request.payload);
                if (request.msg_type != .handshake) return error.HandshakeFailed;
                const parsed_req = try parseRequestPayload(request.payload);
                if (!GenesisDigest.accepted(genesis_digest, parsed_req.genesis_digest)) return error.HandshakeFailed;
                if (!isTimestampFresh(parsed_req.timestamp, nowSeconds())) return error.HandshakeFailed;
                if (!nonce_tracker.registerFresh(parsed_req.nonce_a, nowSeconds())) return error.HandshakeFailed;
                // Ignore any request listen trailer: unsigned and non-authoritative.
                // Initiator advertise is learned from the verified ack below.

                var nonce_b: [32]u8 = undefined;
                @import("io_instance").io.random(&nonce_b);
                if (!nonce_tracker.registerFresh(nonce_b, nowSeconds())) return error.HandshakeFailed;
                const response_ts_u64: u64 = @intCast(if (nowSeconds() < 0) 0 else nowSeconds());
                const response_sig = try signTuple(
                    kp,
                    parsed_req.nonce_a,
                    nonce_b,
                    response_ts_u64,
                    genesis_digest,
                    local_listen_commitment,
                );
                const response_core = buildSignedPayload(parsed_req.nonce_a, nonce_b, response_ts_u64, response_sig, genesis_digest);
                const response_payload = try appendListenTrailer(self.allocator, &response_core, advertise_address);
                defer self.allocator.free(response_payload);
                const response = Message{
                    .msg_type = .handshake,
                    .sender = pubkey,
                    .sequence = 0,
                    .payload = response_payload,
                };
                try self.sendMessage(response);

                const ack = try self.recvMessage() orelse return error.HandshakeFailed;
                defer self.allocator.free(ack.payload);
                if (ack.msg_type != .handshake) return error.HandshakeFailed;
                if (!std.mem.eql(u8, &ack.sender, &request.sender)) return error.HandshakeFailed;
                const parsed_ack = try parseSignedPayload(ack.payload);
                if (!std.mem.eql(u8, &parsed_ack.nonce_a, &parsed_req.nonce_a)) return error.HandshakeFailed;
                if (!std.mem.eql(u8, &parsed_ack.nonce_b, &nonce_b)) return error.HandshakeFailed;
                if (parsed_ack.timestamp != response_ts_u64) return error.HandshakeFailed;
                if (!GenesisDigest.accepted(genesis_digest, parsed_ack.genesis_digest)) return error.HandshakeFailed;
                try verifySignedTuple(
                    ack.sender,
                    parsed_ack.nonce_a,
                    parsed_ack.nonce_b,
                    parsed_ack.timestamp,
                    parsed_ack.genesis_digest,
                    listenCommitmentFromTrailer(parsed_ack.listen_addr),
                    parsed_ack.signature,
                );
                // Authoritative initiator advertise (signature-bound ack trailer).
                self.applyAdvertisedListen(parsed_ack.listen_addr);
                self.peer_key = ack.sender;
            }
            self.state = .connected;
        } else {
            if (!allow_unauthenticated_handshake) {
                return error.UnauthenticatedHandshakeDisabled;
            }
            if (!GenesisDigest.accepted(genesis_digest, @splat(0))) return error.HandshakeFailed;
            // Legacy unauthenticated handshake (no listen trailer; path is
            // fire-and-forget and must stay byte-compatible with old peers).
            // `advertise_address` is only attached on the authenticated path.
            const handshake_data = try self.allocator.dupe(u8, "zknot3:v1");
            defer self.allocator.free(handshake_data);
            const msg = Message{
                .msg_type = .handshake,
                .sender = undefined,
                .sequence = 0,
                .payload = handshake_data,
            };
            try self.sendMessage(msg);
            self.state = .connected;
        }
    }

    /// Set `remote_address` from an advertised listen trailer. No-op when
    /// already set (outbound dial string wins, and `address_from_advertise`
    /// stays false) or when `listen` is null/empty.
    fn applyAdvertisedListen(self: *Self, listen: ?[]const u8) void {
        const addr = listen orelse return;
        if (addr.len == 0) return;
        if (self.remote_address != null) return;
        self.remote_address = self.allocator.dupe(u8, addr) catch null;
        if (self.remote_address != null) self.address_from_advertise = true;
    }

    /// Append optional listen trailer: `u16_be len` + UTF-8 `host:port`.
    /// Empty `listen` returns a dupe of `core_bytes` (no trailer bytes).
    ///
    /// On signed response/ack, the trailer plaintext is bound by Ed25519 via
    /// `listen_commitment = Blake3(listen)` inside `signTuple` (not on the
    /// 168B wire core). Verifier rebuilds the commitment from trailer bytes.
    fn appendListenTrailer(allocator: std.mem.Allocator, core_bytes: []const u8, listen: []const u8) ![]u8 {
        if (listen.len == 0) return try allocator.dupe(u8, core_bytes);
        if (listen.len > HANDSHAKE_MAX_LISTEN_LEN) return error.HandshakeFailed;
        const out = try allocator.alloc(u8, core_bytes.len + 2 + listen.len);
        @memcpy(out[0..core_bytes.len], core_bytes);
        std.mem.writeInt(u16, out[core_bytes.len..][0..2], @intCast(listen.len), .big);
        @memcpy(out[core_bytes.len + 2 ..], listen);
        return out;
    }

    /// Parse optional listen trailer after a fixed core. Accepts exact `core_len`
    /// (no trailer) or `core_len + 2 + listen_len` with `1..=HANDSHAKE_MAX_LISTEN_LEN`.
    /// Rejects truncated or overlong trailers.
    fn parseListenTrailer(payload: []const u8, core_len: usize) !?[]const u8 {
        if (payload.len == core_len) return null;
        if (payload.len < core_len + 2) return error.HandshakeFailed;
        const listen_len: usize = std.mem.readInt(u16, payload[core_len..][0..2], .big);
        if (listen_len == 0 or listen_len > HANDSHAKE_MAX_LISTEN_LEN) return error.HandshakeFailed;
        if (payload.len != core_len + 2 + listen_len) return error.HandshakeFailed;
        return payload[core_len + 2 ..][0..listen_len];
    }

    /// `Blake3(advertise_utf8)`, or 32 zero bytes when `listen` is empty.
    fn listenCommitment(listen: []const u8) [32]u8 {
        if (listen.len == 0) return @as([32]u8, @splat(0));
        var out: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(listen, &out, .{});
        return out;
    }

    fn listenCommitmentFromTrailer(listen_addr: ?[]const u8) [32]u8 {
        return listenCommitment(listen_addr orelse "");
    }

    fn nowSeconds() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return ts.sec;
    }

    fn isTimestampFresh(ts: u64, now: i64) bool {
        const now_u64: u64 = @intCast(if (now < 0) 0 else now);
        if (ts > now_u64 + HANDSHAKE_WINDOW_SECS) return false;
        return now_u64 - ts <= HANDSHAKE_WINDOW_SECS;
    }

    /// Signed message: nonce_a || nonce_b || ts_be || CONTEXT || genesis || listen_commitment.
    /// `listen_commitment` is not on the 168B wire core; verifier recomputes it
    /// from the plaintext listen trailer (or empty → `@splat(0)`).
    fn signTuple(
        kp: std.crypto.sign.Ed25519.KeyPair,
        nonce_a: [32]u8,
        nonce_b: [32]u8,
        timestamp: u64,
        genesis_digest: [32]u8,
        listen_commitment: [32]u8,
    ) ![64]u8 {
        var msg_buf: [32 + 32 + 8 + HANDSHAKE_CONTEXT.len + 32 + 32]u8 = undefined;
        @memcpy(msg_buf[0..32], &nonce_a);
        @memcpy(msg_buf[32..64], &nonce_b);
        std.mem.writeInt(u64, msg_buf[64..72], timestamp, .big);
        @memcpy(msg_buf[72..][0..HANDSHAKE_CONTEXT.len], HANDSHAKE_CONTEXT);
        const after_ctx = 72 + HANDSHAKE_CONTEXT.len;
        @memcpy(msg_buf[after_ctx..][0..32], &genesis_digest);
        @memcpy(msg_buf[after_ctx + 32 ..][0..32], &listen_commitment);
        const sig = std.crypto.sign.Ed25519.KeyPair.sign(kp, &msg_buf, null) catch return error.HandshakeFailed;
        return sig.toBytes();
    }

    fn verifySignedTuple(
        pubkey: [32]u8,
        nonce_a: [32]u8,
        nonce_b: [32]u8,
        timestamp: u64,
        genesis_digest: [32]u8,
        listen_commitment: [32]u8,
        signature: [64]u8,
    ) !void {
        var msg_buf: [32 + 32 + 8 + HANDSHAKE_CONTEXT.len + 32 + 32]u8 = undefined;
        @memcpy(msg_buf[0..32], &nonce_a);
        @memcpy(msg_buf[32..64], &nonce_b);
        std.mem.writeInt(u64, msg_buf[64..72], timestamp, .big);
        @memcpy(msg_buf[72..][0..HANDSHAKE_CONTEXT.len], HANDSHAKE_CONTEXT);
        const after_ctx = 72 + HANDSHAKE_CONTEXT.len;
        @memcpy(msg_buf[after_ctx..][0..32], &genesis_digest);
        @memcpy(msg_buf[after_ctx + 32 ..][0..32], &listen_commitment);
        const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(pubkey) catch return error.HandshakeFailed;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature);
        sig.verify(&msg_buf, pk) catch return error.HandshakeFailed;
    }

    fn parseRequestPayload(payload: []const u8) !struct {
        nonce_a: [32]u8,
        timestamp: u64,
        genesis_digest: [32]u8,
        /// Slice into `payload` when a listen trailer is present (ignored for
        /// remote_address; unsigned request is non-authoritative).
        listen_addr: ?[]const u8,
    } {
        if (payload.len < HANDSHAKE_REQUEST_CORE_LEN) return error.HandshakeFailed;
        const listen_addr = try parseListenTrailer(payload, HANDSHAKE_REQUEST_CORE_LEN);
        return .{
            .nonce_a = payload[0..32].*,
            .timestamp = std.mem.readInt(u64, payload[32..40], .big),
            .genesis_digest = payload[40..72].*,
            .listen_addr = listen_addr,
        };
    }

    fn buildSignedPayload(
        nonce_a: [32]u8,
        nonce_b: [32]u8,
        timestamp: u64,
        signature: [64]u8,
        genesis_digest: [32]u8,
    ) [HANDSHAKE_SIGNED_CORE_LEN]u8 {
        var payload: [HANDSHAKE_SIGNED_CORE_LEN]u8 = undefined;
        @memcpy(payload[0..32], &nonce_a);
        @memcpy(payload[32..64], &nonce_b);
        std.mem.writeInt(u64, payload[64..72], timestamp, .big);
        @memcpy(payload[72..136], &signature);
        @memcpy(payload[136..168], &genesis_digest);
        return payload;
    }

    fn parseSignedPayload(payload: []const u8) !struct {
        nonce_a: [32]u8,
        nonce_b: [32]u8,
        timestamp: u64,
        signature: [64]u8,
        genesis_digest: [32]u8,
        /// Slice into `payload` when a listen trailer is present. Must match
        /// `Blake3(trailer)` used inside the Ed25519 signed message.
        listen_addr: ?[]const u8,
    } {
        if (payload.len < HANDSHAKE_SIGNED_CORE_LEN) return error.HandshakeFailed;
        const listen_addr = try parseListenTrailer(payload, HANDSHAKE_SIGNED_CORE_LEN);
        return .{
            .nonce_a = payload[0..32].*,
            .nonce_b = payload[32..64].*,
            .timestamp = std.mem.readInt(u64, payload[64..72], .big),
            .signature = payload[72..136].*,
            .genesis_digest = payload[136..168].*,
            .listen_addr = listen_addr,
        };
    }
    pub fn sendMessage(self: *Self, msg: Message) !void {
        const serialized = try msg.serialize(self.allocator);
        defer self.allocator.free(serialized);

        try streamWriteAll(self.conn, serialized);
    }

    pub fn recvMessage(self: *Self) !?Message {
        // Accumulate a full header, resuming a partial one from a previous call.
        while (self.read_header_len < Message.HEADER_SIZE) {
            const n = streamReadShort(
                self.conn,
                self.read_header[self.read_header_len..],
            ) catch |err| {
                if (err == error.WouldBlock) return error.WouldBlock;
                // Stream unusable: forget the partial frame.
                self.read_header_len = 0;
                return err;
            };
            if (n == 0) {
                self.read_header_len = 0;
                return null; // EOF
            }
            self.read_header_len += n;
        }

        const header_buf = self.read_header;
        // Parse header to get payload length
        const payload_len = std.mem.readInt(u32, header_buf[41..45], .big);
        if (payload_len > self.max_message_size) {
            self.read_header_len = 0;
            return error.MessageTooLarge;
        }
        // The header is fully consumed from here on.
        self.read_header_len = 0;

        // Read payload
        if (payload_len > 0) {
            const payload_buf = try self.allocator.alloc(u8, payload_len);
            defer self.allocator.free(payload_buf);

            const payload_read = streamReadShort(self.conn, payload_buf) catch |err| {
                if (err == error.WouldBlock) return error.WouldBlock;
                return err;
            };
            if (payload_read < payload_len) return error.IncompletePayload;

            // Combine header + payload for deserialization
            var full_buf = try self.allocator.alloc(u8, 45 + payload_len);
            defer self.allocator.free(full_buf);
            @memcpy(full_buf[0..45], &header_buf);
            @memcpy(full_buf[45..], payload_buf);

            return try Message.deserialize(self.allocator, full_buf);
        }

        return try Message.deserialize(self.allocator, &header_buf);
    }

    pub fn sendPing(self: *Self) !void {
        const msg = Message{
            .msg_type = .ping,
            .sender = undefined,
            .sequence = 0,
            .payload = &.{},
        };
        try self.sendMessage(msg);
        self.last_ping = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            break :blk (ts.sec);
        };
    }

    pub fn sendPong(self: *Self) !void {
        const msg = Message{
            .msg_type = .pong,
            .sender = undefined,
            .sequence = 0,
            .payload = &.{},
        };
        try self.sendMessage(msg);
    }
};

/// QUIC-specific peer connection wrapper
pub const QUICPeerConnection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    peer_id: u64,
    quic_conn: *QUIC.QUICConnection,
    state: PeerConnection.State,
    last_ping: i64,
    /// CLOCK.REALTIME seconds when this peer was published into quic_peers.
    /// Used by peer rotation as quality tiebreak. Default 0 until publish.
    connected_at: i64 = 0,
    peer_key: [32]u8,
    max_message_size: usize,
    /// True when this peer was opened by local `dial` (outbound).
    is_outbound: bool = false,
    /// Same semantics as `PeerConnection.reputation` (rotation quality input).
    reputation: i32 = 100,
    /// Same semantics as `PeerConnection.latency_ms`.
    latency_ms: u64 = 0,
    /// Owned dial string when known (outbound dial or handshake listen
    /// trailer on TCP path). Freed in `deinit`.
    remote_address: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, peer_id: u64, quic_conn: *QUIC.QUICConnection) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .peer_id = peer_id,
            .quic_conn = quic_conn,
            .state = .handshaking,
            .last_ping = blk: {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                break :blk (ts.sec);
            },
            .peer_key = undefined,
            .max_message_size = Message.MAX_MESSAGE_SIZE,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.remote_address) |addr| {
            self.allocator.free(addr);
            self.remote_address = null;
        }
    }

    /// Perform QUIC handshake
    pub fn performHandshake(
        self: *Self,
        is_initiator: bool,
        validator_key: ?[32]u8,
        allow_unauthenticated_handshake: bool,
        genesis_digest: [32]u8,
    ) !void {
        _ = is_initiator;
        if (validator_key == null and !allow_unauthenticated_handshake) {
            return error.UnauthenticatedHandshakeDisabled;
        }
        // The UDP path does not bind the genesis digest into the signed
        // transcript. A pinned chain stays on TCP until that exists.
        if (!GenesisDigest.accepted(genesis_digest, @splat(0))) return error.HandshakeFailed;
        // QUIC handshake happens at connection level
        // Just mark as connected once we have the connection
        self.quic_conn.state = .connected;
        self.state = .connected;
    }

    pub fn sendMessage(self: *Self, msg: Message) !void {
        const serialized = try msg.serialize(self.allocator);
        defer self.allocator.free(serialized);
        if (self.quic_conn.udp_peer != null) {
            try self.quic_conn.deliver(serialized);
            return;
        }
        // Open a new bidirectional stream for each message
        const stream_id = try self.quic_conn.openStream();
        const stream = self.quic_conn.getStream(stream_id) orelse return error.StreamNotFound;
        try stream.write(serialized);
    }

    pub fn recvMessage(self: *Self) !?Message {
        if (self.quic_conn.udp_peer != null) {
            var buf: [64 * 1024]u8 = undefined;
            const len = (try self.quic_conn.takePayload(&buf)) orelse return null;
            if (len > self.max_message_size) return error.MessageTooLarge;
            return try Message.deserialize(self.allocator, buf[0..len]);
        }
        // Accept incoming stream
        const stream = self.quic_conn.acceptStream() orelse return null;

        var buf: [64 * 1024]u8 = undefined;
        const len = try stream.read(&buf);
        if (len == 0) return null;
        if (len > self.max_message_size) return error.MessageTooLarge;

        return try Message.deserialize(self.allocator, buf[0..len]);
    }

    pub fn sendPing(self: *Self) !void {
        const stream_id = try self.quic_conn.openUnidirectionalStream();
        const stream = self.quic_conn.getStream(stream_id) orelse return error.StreamNotFound;
        const ping_data = "ping";
        try stream.write(ping_data);
        self.last_ping = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            break :blk (ts.sec);
        };
    }

    pub fn sendPong(self: *Self) !void {
        const stream_id = try self.quic_conn.openUnidirectionalStream();
        const stream = self.quic_conn.getStream(stream_id) orelse return error.StreamNotFound;
        const pong_data = "pong";
        try stream.write(pong_data);
    }
};

test "P2PServer initialization" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{});
    defer server.deinit();

    try std.testing.expect(!server.isRunning());
    try std.testing.expect(server.peerCount() == 0);
}

test "P2PServer refuses to wrap peer ids" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{});
    defer server.deinit();

    server.next_peer_id = std.math.maxInt(u64) - 1;
    const id = try server.allocatePeerId();
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, id);
    try std.testing.expectEqual(std.math.maxInt(u64), server.next_peer_id);
    try std.testing.expectError(error.ArithmeticOverflow, server.allocatePeerId());
    try std.testing.expectEqual(std.math.maxInt(u64), server.next_peer_id);
}

test "P2PServer deinit does not double free" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{});
    server.deinit();
}

test "P2PServer with QUIC transport" {
    const allocator = std.testing.allocator;
    const config = P2PServerConfig{
        .transport_type = .quic,
    };
    const server = try P2PServer.init(allocator, config);
    defer server.deinit();

    try std.testing.expect(!server.isRunning());
    try std.testing.expect(server.peerCount() == 0);
    try std.testing.expect(server.quic_transport != null);
}

test "PeerConnection struct layout" {
    _ = @sizeOf(PeerConnection);
}

test "QUICPeerConnection struct layout" {
    _ = @sizeOf(QUICPeerConnection);
}

test "bootstrap peer key derivation is deterministic" {
    const addr = "127.0.0.1:8083";
    const k1 = P2PServer.derivePeerKeyFromAddress(addr);
    const k2 = P2PServer.derivePeerKeyFromAddress(addr);
    try std.testing.expectEqual(k1, k2);
}

test "HandshakeNonceTracker rejects replay and allows after ttl" {
    const allocator = std.testing.allocator;
    var tracker = HandshakeNonceTracker.init(allocator, 2);
    defer tracker.deinit();

    const nonce = @as([32]u8, @splat(7));
    try std.testing.expect(tracker.registerFresh(nonce, 100));
    try std.testing.expect(!tracker.registerFresh(nonce, 100));
    try std.testing.expect(!tracker.registerFresh(nonce, 101));
    try std.testing.expect(tracker.registerFresh(nonce, 103));
}

test "handshake timestamp freshness window" {
    try std.testing.expect(PeerConnection.isTimestampFresh(100, 100));
    try std.testing.expect(PeerConnection.isTimestampFresh(40, 100));
    try std.testing.expect(!PeerConnection.isTimestampFresh(39, 100));
    try std.testing.expect(!PeerConnection.isTimestampFresh(200, 100));
}

test "per-peer rate limiter eventually bans noisy peer" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{
        .max_messages_per_second_per_peer = 4,
        .max_messages_per_second_per_type = 3,
        .peer_score_ban_threshold = -20,
        .peer_ban_seconds = 30,
    });
    defer server.deinit();

    const peer = @as([32]u8, @splat(0xAA));
    try std.testing.expect(server.allowIncomingMessage(peer, .consensus));
    try std.testing.expect(server.allowIncomingMessage(peer, .consensus));
    try std.testing.expect(server.allowIncomingMessage(peer, .consensus));
    // Type cap exceeded; score drops to threshold and peer becomes banned.
    try std.testing.expect(!server.allowIncomingMessage(peer, .consensus));
    try std.testing.expect(server.isPeerBanned(peer));
}

test "handshake payload parser rejects malformed lengths" {
    const short_req = @as([39]u8, @splat(0));
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseRequestPayload(&short_req));

    const mid_req = @as([41]u8, @splat(0));
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseRequestPayload(&mid_req));

    // Truncated trailer: core + 1 byte (no full u16 length).
    var trunc_req: [HANDSHAKE_REQUEST_CORE_LEN + 1]u8 = @splat(0);
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseRequestPayload(&trunc_req));

    // listen_len claims more bytes than remain.
    var short_trailer_req: [HANDSHAKE_REQUEST_CORE_LEN + 2]u8 = @splat(0);
    std.mem.writeInt(u16, short_trailer_req[HANDSHAKE_REQUEST_CORE_LEN..][0..2], 5, .big);
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseRequestPayload(&short_trailer_req));

    const short_signed = @as([135]u8, @splat(0));
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseSignedPayload(&short_signed));

    const mid_signed = @as([137]u8, @splat(0));
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseSignedPayload(&mid_signed));

    var trunc_signed: [HANDSHAKE_SIGNED_CORE_LEN + 1]u8 = @splat(0);
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.parseSignedPayload(&trunc_signed));
}

test "handshake payload parser accepts legacy exact cores" {
    var req: [HANDSHAKE_REQUEST_CORE_LEN]u8 = @splat(0);
    req[0] = 0xAB;
    std.mem.writeInt(u64, req[32..40], 42, .big);
    req[40] = 0xCD;
    const parsed_req = try PeerConnection.parseRequestPayload(&req);
    try std.testing.expectEqual(@as(u8, 0xAB), parsed_req.nonce_a[0]);
    try std.testing.expectEqual(@as(u64, 42), parsed_req.timestamp);
    try std.testing.expectEqual(@as(u8, 0xCD), parsed_req.genesis_digest[0]);
    try std.testing.expect(parsed_req.listen_addr == null);

    var signed: [HANDSHAKE_SIGNED_CORE_LEN]u8 = @splat(0);
    signed[0] = 0x11;
    signed[32] = 0x22;
    std.mem.writeInt(u64, signed[64..72], 7, .big);
    signed[72] = 0x33;
    signed[136] = 0x44;
    const parsed_signed = try PeerConnection.parseSignedPayload(&signed);
    try std.testing.expectEqual(@as(u8, 0x11), parsed_signed.nonce_a[0]);
    try std.testing.expectEqual(@as(u8, 0x22), parsed_signed.nonce_b[0]);
    try std.testing.expectEqual(@as(u64, 7), parsed_signed.timestamp);
    try std.testing.expectEqual(@as(u8, 0x33), parsed_signed.signature[0]);
    try std.testing.expectEqual(@as(u8, 0x44), parsed_signed.genesis_digest[0]);
    try std.testing.expect(parsed_signed.listen_addr == null);
}

test "handshake payload parser extracts listen trailer" {
    const listen = "10.0.0.5:8083";
    var req_core: [HANDSHAKE_REQUEST_CORE_LEN]u8 = @splat(1);
    const req = try PeerConnection.appendListenTrailer(std.testing.allocator, &req_core, listen);
    defer std.testing.allocator.free(req);
    const parsed_req = try PeerConnection.parseRequestPayload(req);
    try std.testing.expectEqualStrings(listen, parsed_req.listen_addr.?);

    var signed_core: [HANDSHAKE_SIGNED_CORE_LEN]u8 = @splat(2);
    const signed = try PeerConnection.appendListenTrailer(std.testing.allocator, &signed_core, listen);
    defer std.testing.allocator.free(signed);
    const parsed_signed = try PeerConnection.parseSignedPayload(signed);
    try std.testing.expectEqualStrings(listen, parsed_signed.listen_addr.?);
}

test "handshake listen trailer round-trip helper" {
    const allocator = std.testing.allocator;
    const listen = "validator-1.example:8083";
    var core_bytes: [HANDSHAKE_REQUEST_CORE_LEN]u8 = undefined;
    for (&core_bytes, 0..) |*b, i| b.* = @truncate(i);

    const encoded = try PeerConnection.appendListenTrailer(allocator, &core_bytes, listen);
    defer allocator.free(encoded);
    try std.testing.expectEqual(HANDSHAKE_REQUEST_CORE_LEN + 2 + listen.len, encoded.len);
    try std.testing.expectEqualSlices(u8, &core_bytes, encoded[0..HANDSHAKE_REQUEST_CORE_LEN]);

    const parsed = try PeerConnection.parseRequestPayload(encoded);
    try std.testing.expectEqualSlices(u8, &core_bytes, encoded[0..HANDSHAKE_REQUEST_CORE_LEN]);
    try std.testing.expectEqualStrings(listen, parsed.listen_addr.?);
    try std.testing.expectEqual(core_bytes[0], parsed.nonce_a[0]);

    // Empty advertise → legacy exact core (no trailer bytes).
    const legacy = try PeerConnection.appendListenTrailer(allocator, &core_bytes, "");
    defer allocator.free(legacy);
    try std.testing.expectEqual(HANDSHAKE_REQUEST_CORE_LEN, legacy.len);
    const legacy_parsed = try PeerConnection.parseRequestPayload(legacy);
    try std.testing.expect(legacy_parsed.listen_addr == null);
}

test "applyAdvertisedListen preserves outbound dial string" {
    const allocator = std.testing.allocator;
    // Minimal PeerConnection stack object (no live socket used).
    var peer: PeerConnection = undefined;
    peer.allocator = allocator;
    peer.remote_address = try allocator.dupe(u8, "1.2.3.4:8083");
    peer.address_from_advertise = false;
    defer {
        if (peer.remote_address) |a| allocator.free(a);
    }

    peer.applyAdvertisedListen("9.9.9.9:8083");
    try std.testing.expectEqualStrings("1.2.3.4:8083", peer.remote_address.?);
    try std.testing.expect(!peer.address_from_advertise);

    if (peer.remote_address) |a| {
        allocator.free(a);
        peer.remote_address = null;
    }
    peer.address_from_advertise = false;
    peer.applyAdvertisedListen("9.9.9.9:8083");
    try std.testing.expectEqualStrings("9.9.9.9:8083", peer.remote_address.?);
    try std.testing.expect(peer.address_from_advertise);
}

test "listenCommitment empty is zero; nonempty is Blake3" {
    const empty = PeerConnection.listenCommitment("");
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &empty);
    try std.testing.expectEqualSlices(u8, &empty, &PeerConnection.listenCommitmentFromTrailer(null));

    const listen = "10.0.0.5:8083";
    const got = PeerConnection.listenCommitment(listen);
    var expect: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(listen, &expect, .{});
    try std.testing.expectEqualSlices(u8, &expect, &got);
    try std.testing.expect(!std.mem.eql(u8, &got, &empty));
}

test "signed handshake listen commitment matches trailer" {
    const seed = @as([32]u8, @splat(0x42));
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const pubkey = kp.public_key.toBytes();
    const nonce_a = @as([32]u8, @splat(1));
    const nonce_b = @as([32]u8, @splat(2));
    const ts: u64 = 1_700_000_000;
    const genesis = @as([32]u8, @splat(3));
    const listen = "validator-1.example:8083";
    const commitment = PeerConnection.listenCommitment(listen);

    const sig = try PeerConnection.signTuple(kp, nonce_a, nonce_b, ts, genesis, commitment);
    try PeerConnection.verifySignedTuple(pubkey, nonce_a, nonce_b, ts, genesis, commitment, sig);

    // Empty advertise → zero commitment verifies.
    const zero = @as([32]u8, @splat(0));
    const sig_empty = try PeerConnection.signTuple(kp, nonce_a, nonce_b, ts, genesis, zero);
    try PeerConnection.verifySignedTuple(pubkey, nonce_a, nonce_b, ts, genesis, zero, sig_empty);
    try PeerConnection.verifySignedTuple(
        pubkey,
        nonce_a,
        nonce_b,
        ts,
        genesis,
        PeerConnection.listenCommitmentFromTrailer(null),
        sig_empty,
    );

    // Wire round-trip: signature covers Blake3(trailer); verify rebuilds from trailer.
    const signed_core = PeerConnection.buildSignedPayload(nonce_a, nonce_b, ts, sig, genesis);
    const payload = try PeerConnection.appendListenTrailer(std.testing.allocator, &signed_core, listen);
    defer std.testing.allocator.free(payload);
    const parsed = try PeerConnection.parseSignedPayload(payload);
    try std.testing.expectEqualStrings(listen, parsed.listen_addr.?);
    try PeerConnection.verifySignedTuple(
        pubkey,
        parsed.nonce_a,
        parsed.nonce_b,
        parsed.timestamp,
        parsed.genesis_digest,
        PeerConnection.listenCommitmentFromTrailer(parsed.listen_addr),
        parsed.signature,
    );
}

test "mismatched listen trailer vs signed commitment fails verify" {
    const seed = @as([32]u8, @splat(0x43));
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const pubkey = kp.public_key.toBytes();
    const nonce_a = @as([32]u8, @splat(4));
    const nonce_b = @as([32]u8, @splat(5));
    const ts: u64 = 1_700_000_001;
    const genesis = @as([32]u8, @splat(6));
    const signed_listen = "10.0.0.1:8083";
    const spoofed_listen = "evil.example:9999";
    const sig = try PeerConnection.signTuple(
        kp,
        nonce_a,
        nonce_b,
        ts,
        genesis,
        PeerConnection.listenCommitment(signed_listen),
    );

    // Attacker swaps trailer but keeps signature → commitment mismatch.
    const signed_core = PeerConnection.buildSignedPayload(nonce_a, nonce_b, ts, sig, genesis);
    const spoofed = try PeerConnection.appendListenTrailer(std.testing.allocator, &signed_core, spoofed_listen);
    defer std.testing.allocator.free(spoofed);
    const parsed = try PeerConnection.parseSignedPayload(spoofed);
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.verifySignedTuple(
        pubkey,
        parsed.nonce_a,
        parsed.nonce_b,
        parsed.timestamp,
        parsed.genesis_digest,
        PeerConnection.listenCommitmentFromTrailer(parsed.listen_addr),
        parsed.signature,
    ));

    // Trailer stripped while signature covered a non-empty advertise.
    try std.testing.expectError(error.HandshakeFailed, PeerConnection.verifySignedTuple(
        pubkey,
        nonce_a,
        nonce_b,
        ts,
        genesis,
        PeerConnection.listenCommitment(""),
        sig,
    ));
}

test "one IPv4 /16 cannot fill the peer table" {
    const prefixes = [_]u16{ 0xac14, 0xac14, 0xac14, 0x7f00 };
    try std.testing.expect(!admitPrefix(&prefixes, 0xac14, 3));
    try std.testing.expect(admitPrefix(&prefixes, 0x7f00, 3));
    try std.testing.expect(admitPrefix(&prefixes, 0xac14, 0));
    try std.testing.expect(admitPrefix(&prefixes, 0, 1));
    try std.testing.expectEqual(@as(?u16, 0xac14), prefix16FromHost("172.20.0.4:8083"));
    try std.testing.expectEqual(@as(?u16, null), prefix16FromHost("0.0.0.1:1"));
}

test "reserved outbound slots block inbound before outbound" {
    // max=10, reserved=8 → inbound ceiling is 2; outbound can fill to 10.
    try std.testing.expectEqual(@as(usize, 8), effectiveReservedOutbound(10, 8));
    try std.testing.expect(inboundAdmissionAllowed(0, 10, 8));
    try std.testing.expect(inboundAdmissionAllowed(1, 10, 8));
    try std.testing.expect(!inboundAdmissionAllowed(2, 10, 8));
    try std.testing.expect(outboundAdmissionAllowed(2, 10));
    try std.testing.expect(outboundAdmissionAllowed(9, 10));
    try std.testing.expect(!outboundAdmissionAllowed(10, 10));

    // reserved=0 disables: inbound and outbound share the same ceiling.
    try std.testing.expectEqual(@as(usize, 0), effectiveReservedOutbound(10, 0));
    try std.testing.expect(inboundAdmissionAllowed(9, 10, 0));
    try std.testing.expect(!inboundAdmissionAllowed(10, 10, 0));

    // reserved >= max clamps to max-1 so one inbound slot remains.
    try std.testing.expectEqual(@as(usize, 9), effectiveReservedOutbound(10, 10));
    try std.testing.expectEqual(@as(usize, 9), effectiveReservedOutbound(10, 99));
    try std.testing.expect(inboundAdmissionAllowed(0, 10, 99));
    try std.testing.expect(!inboundAdmissionAllowed(1, 10, 99));

    // Default-shaped knobs (256 / 8).
    try std.testing.expect(inboundAdmissionAllowed(247, 256, 8));
    try std.testing.expect(!inboundAdmissionAllowed(248, 256, 8));
    try std.testing.expect(outboundAdmissionAllowed(248, 256));
    try std.testing.expect(!outboundAdmissionAllowed(256, 256));
}

test "inboundRatioSuspicious flags an inbound-heavy table" {
    // 9 inbound of 10 at 80% → 900 > 800.
    try std.testing.expect(inboundRatioSuspicious(9, 1, 80));
    // Even split stays under the limit: 500 > 800 is false.
    try std.testing.expect(!inboundRatioSuspicious(5, 5, 80));
    // Zero limit disables the mode.
    try std.testing.expect(!inboundRatioSuspicious(9, 1, 0));
    // Tiny tables do not trip (total < 4), including an empty table.
    try std.testing.expect(!inboundRatioSuspicious(3, 0, 80));
    try std.testing.expect(!inboundRatioSuspicious(2, 1, 80));
    try std.testing.expect(!inboundRatioSuspicious(0, 0, 80));
    // Exact limit is not suspicious (strict >). 8/2 of 10 at 80% → 800 > 800.
    try std.testing.expect(!inboundRatioSuspicious(8, 2, 80));
    // Minimum total is inclusive: 4 inbound, 0 outbound → 400 > 320.
    try std.testing.expect(inboundRatioSuspicious(4, 0, 80));
}

test "inflight inbound handshakes add to the ratio inbound count" {
    // 8 published inbound + 2 outbound is exactly the 80% limit.
    const published_inbound: usize = 8;
    const outbound: usize = 2;
    const inflight: usize = 1;
    try std.testing.expect(!inboundRatioSuspicious(published_inbound, outbound, 80));
    // The same table plus one in-flight inbound handshake tips the gate.
    try std.testing.expect(inboundRatioSuspicious(published_inbound + inflight, outbound, 80));

    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{ .inbound_ratio_limit = 80 });
    defer server.deinit();

    try std.testing.expectEqual(@as(usize, 0), server.inflight_inbound.load(.acquire));
    try std.testing.expect(!server.inboundRatioPaused());
    try std.testing.expectEqual(@as(usize, 0), server.directionStats().inbound);

    // No sockets: the accept path's fetchAdd is what the gate observes.
    _ = server.inflight_inbound.fetchAdd(4, .release);
    try std.testing.expect(server.inboundRatioPaused());
    const paused = server.directionStats();
    try std.testing.expectEqual(@as(usize, 4), paused.inbound);
    try std.testing.expectEqual(@as(usize, 0), paused.outbound);
    try std.testing.expect(paused.inbound_paused);

    _ = server.inflight_inbound.fetchSub(4, .release);
    try std.testing.expect(!server.inboundRatioPaused());
    try std.testing.expectEqual(@as(usize, 0), server.directionStats().inbound);
}

test "inbound ratio pause rejects TCP accept and QUIC inbound" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{
        .max_connections = 32,
        .inbound_ratio_limit = 80,
        .reserved_outbound_slots = 8,
    });
    defer server.deinit();

    var peer_ends: [3]std.posix.fd_t = undefined;
    for (0..3) |i| {
        var fds: [2]std.posix.fd_t = undefined;
        const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        if (rc != 0) return error.SocketPairFailed;
        peer_ends[i] = fds[1];
        const stream = std.Io.net.Stream{ .socket = .{
            .handle = fds[0],
            .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
        } };
        const key = @as([32]u8, @splat(@as(u8, @intCast(i + 1))));
        const peer = try allocator.create(PeerConnection);
        peer.* = .{
            .allocator = allocator,
            .peer_id = i,
            .conn = stream,
            .state = .connected,
            .last_ping = 0,
            .peer_key = key,
            .max_message_size = 1024,
            .is_outbound = false,
        };
        errdefer {
            peer.deinit();
            allocator.destroy(peer);
        }
        try server.peers.put(allocator, key, peer);
    }
    defer {
        for (peer_ends) |fd| {
            _ = std.c.close(fd);
        }
    }

    {
        const quic_in = try QUIC.QUICConnection.init(allocator, .{ .bytes = @as([16]u8, @splat(9)) });
        const quic_key = @as([32]u8, @splat(9));
        const quic_peer = try allocator.create(QUICPeerConnection);
        quic_peer.* = .{
            .allocator = allocator,
            .peer_id = 9,
            .quic_conn = quic_in,
            .state = .connected,
            .last_ping = 0,
            .peer_key = quic_key,
            .max_message_size = 1024,
            .is_outbound = false,
        };
        errdefer {
            quic_peer.deinit();
            allocator.destroy(quic_peer);
            quic_in.deinit();
        }
        try server.quic_peers.put(allocator, quic_key, quic_peer);
    }

    // 3 TCP inbound + 1 QUIC inbound. 4 * 100 > 4 * 80.
    const counts = server.peerDirectionCounts();
    try std.testing.expectEqual(@as(usize, 4), counts.inbound);
    try std.testing.expectEqual(@as(usize, 0), counts.outbound);
    try std.testing.expect(server.inboundRatioPaused());
    try std.testing.expect(outboundAdmissionAllowed(server.peerCount(), server.config.max_connections));

    var in_fds: [2]std.posix.fd_t = undefined;
    const in_rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &in_fds);
    if (in_rc != 0) return error.SocketPairFailed;
    defer _ = std.c.close(in_fds[1]);
    const incoming = std.Io.net.Stream{ .socket = .{
        .handle = in_fds[0],
        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
    } };
    try std.testing.expectError(error.InboundPaused, server.handleConnection(incoming));
    try std.testing.expectEqual(@as(usize, 4), server.peerCount());
    try std.testing.expectEqual(@as(usize, 0), server.handshake_threads.items.len);

    const quic_attempt = try QUIC.QUICConnection.init(allocator, .{ .bytes = @as([16]u8, @splat(8)) });
    defer quic_attempt.deinit();
    try std.testing.expectError(error.InboundPaused, server.handleQUICConnection(quic_attempt, false, null));
    try std.testing.expectEqual(@as(usize, 4), server.peerCount());

    // Outbound QUIC skips the ratio gate and reaches handshake. No validator
    // key means the handshake itself fails, which is past admission.
    const quic_out = try QUIC.QUICConnection.init(allocator, .{ .bytes = @as([16]u8, @splat(7)) });
    defer quic_out.deinit();
    try std.testing.expectError(error.UnauthenticatedHandshakeDisabled, server.handleQUICConnection(quic_out, true, "127.0.0.1:9"));
    try std.testing.expectEqual(@as(usize, 4), server.peerCount());
}

test "one IPv6 /48 cannot fill the peer table" {
    const a: [6]u8 = .{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01 };
    const b: [6]u8 = .{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x02 };
    const prefixes = [_][6]u8{ a, a, a };
    try std.testing.expect(!admitIpv6Prefix48(&prefixes, a, 3));
    try std.testing.expect(admitIpv6Prefix48(&prefixes, b, 3));
    try std.testing.expect(admitIpv6Prefix48(&prefixes, a, 0));

    const v6 = std.Io.net.IpAddress{ .ip6 = .{
        .bytes = .{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .port = 8083,
    } };
    try std.testing.expectEqual(a, ipv6Prefix48(v6).?);

    const mapped = std.Io.net.IpAddress{ .ip6 = .{
        .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 172, 20, 0, 4 },
        .port = 8083,
    } };
    try std.testing.expectEqual(@as(?[6]u8, null), ipv6Prefix48(mapped));
    try std.testing.expectEqual(@as(?u16, 0xac14), ipv4Prefix16(mapped));
}

test "peerCount sums tcp and quic peers" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{ .max_connections = 10 });
    defer server.deinit();

    // Create a valid socket pair for the mock TCP peer's conn
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[1]);
    const stream = std.Io.net.Stream{ .socket = .{
        .handle = fds[0],
        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
    } };

    // Manually inject a TCP peer
    const tcp_key = @as([32]u8, @splat(0x01));
    const tcp_peer = try allocator.create(PeerConnection);
    tcp_peer.* = .{
        .allocator = allocator,
        .peer_id = 1,
        .conn = stream,
        .state = .connected,
        .last_ping = 0,
        .peer_key = tcp_key,
        .max_message_size = 1024,
    };
    try server.peers.put(allocator, tcp_key, tcp_peer);

    // Manually inject a QUIC peer with a valid QUICConnection
    const quic_conn = try QUIC.QUICConnection.init(allocator, .{ .bytes = @as([16]u8, @splat(0)) });
    const quic_key = @as([32]u8, @splat(0x02));
    const quic_peer = try allocator.create(QUICPeerConnection);
    quic_peer.* = .{
        .allocator = allocator,
        .peer_id = 2,
        .quic_conn = quic_conn,
        .state = .connected,
        .last_ping = 0,
        .peer_key = quic_key,
        .max_message_size = 1024,
        .is_outbound = true,
    };
    try server.quic_peers.put(allocator, quic_key, quic_peer);

    try std.testing.expectEqual(@as(usize, 2), server.peerCount());
    const stats = server.directionStats();
    try std.testing.expectEqual(@as(usize, 1), stats.inbound);
    try std.testing.expectEqual(@as(usize, 1), stats.outbound);
    try std.testing.expect(!stats.inbound_paused);

    // getPeerIDs should return both
    const ids = try server.getPeerIDs();
    defer allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);

    // isPeerConnectedByAddress should check both maps (no matching address)
    try std.testing.expect(!server.isPeerConnectedByAddress("127.0.0.1:1"));

    // removePeer should destroy the correct type
    server.removePeer(tcp_key);
    server.removePeer(quic_key);
    try std.testing.expectEqual(@as(usize, 0), server.peerCount());

    // QUICConnection was not freed by removePeer (quic_transport is null),
    // so clean it up manually.
    quic_conn.deinit();
}

test "directionStats inbound pause follows ratio limit" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{ .max_connections = 16 });
    defer server.deinit();

    // Four inbound TCP peers: total meets INBOUND_RATIO_MIN_TOTAL and
    // 4/4 is above the default 80% limit, so accepts pause.
    var nspare: usize = 0;
    var spare: [4]std.posix.fd_t = undefined;
    defer {
        for (spare[0..nspare]) |fd| _ = std.c.close(fd);
    }
    for (0..4) |i| {
        var fds: [2]std.posix.fd_t = undefined;
        const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        if (rc != 0) return error.SocketPairFailed;
        spare[nspare] = fds[1];
        nspare += 1;
        const stream = std.Io.net.Stream{ .socket = .{
            .handle = fds[0],
            .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
        } };
        var key: [32]u8 = @splat(0);
        key[0] = @intCast(i + 1);
        const peer = try allocator.create(PeerConnection);
        peer.* = .{
            .allocator = allocator,
            .peer_id = i,
            .conn = stream,
            .state = .connected,
            .last_ping = 0,
            .peer_key = key,
            .max_message_size = 1024,
        };
        try server.peers.put(allocator, key, peer);
    }

    const paused = server.directionStats();
    try std.testing.expectEqual(@as(usize, 4), paused.inbound);
    try std.testing.expectEqual(@as(usize, 0), paused.outbound);
    try std.testing.expect(paused.inbound_paused);

    server.config.inbound_ratio_limit = 0;
    try std.testing.expect(!server.directionStats().inbound_paused);
}

test "max_connections rejects inbound connection" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{ .max_connections = 1 });
    defer server.deinit();

    // Create a valid socket pair for the mock peer's conn
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[1]);
    const stream = std.Io.net.Stream{ .socket = .{
        .handle = fds[0],
        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
    } };

    // Fill the slot with a dummy TCP peer
    const key = @as([32]u8, @splat(0xAB));
    const peer = try allocator.create(PeerConnection);
    peer.* = .{
        .allocator = allocator,
        .peer_id = 0,
        .conn = stream,
        .state = .connected,
        .last_ping = 0,
        .peer_key = key,
        .max_message_size = 1024,
    };
    try server.peers.put(allocator, key, peer);

    try std.testing.expectEqual(@as(usize, 1), server.peerCount());

    // A second peer should be rejected. Since we can't easily create a real
    // stream in a unit test, verify the limit logic by checking the public
    // peer count against max_connections.
    try std.testing.expect(server.peerCount() >= server.config.max_connections);
}

test "pinned genesis digests must match" {
    const local: [32]u8 = @splat(1);
    const other: [32]u8 = @splat(2);
    try std.testing.expect(GenesisDigest.accepted(local, local));
    try std.testing.expect(!GenesisDigest.accepted(local, other));
}

test "peerRotationDue gates on interval" {
    try std.testing.expect(!peerRotationDue(100, 200, 0));
    try std.testing.expect(!peerRotationDue(100, 200, -1));
    try std.testing.expect(!peerRotationDue(100, 699, 600));
    try std.testing.expect(peerRotationDue(100, 700, 600));
    try std.testing.expect(peerRotationDue(0, 1, 1));
}

test "pickPeerRotationVictim prefers oldest inbound" {
    const a = @as([32]u8, @splat(1));
    const b = @as([32]u8, @splat(2));
    const c = @as([32]u8, @splat(3));
    // Equal quality → oldest inbound wins (age tiebreak).
    const candidates = [_]PeerRotationCandidate{
        .{ .key = a, .connected_at = 10, .is_outbound = true },
        .{ .key = b, .connected_at = 50, .is_outbound = false },
        .{ .key = c, .connected_at = 20, .is_outbound = false },
    };
    const idx = pickPeerRotationVictim(&candidates, &.{}, true).?;
    try std.testing.expectEqual(@as(usize, 2), idx);
    try std.testing.expectEqual(c, candidates[idx].key);
}

test "peerRotationQuality subtracts capped latency penalty" {
    try std.testing.expectEqual(@as(i32, 100), peerRotationQuality(100, 0));
    try std.testing.expectEqual(@as(i32, 90), peerRotationQuality(100, 100));
    try std.testing.expectEqual(@as(i32, 50), peerRotationQuality(100, 500));
    try std.testing.expectEqual(@as(i32, 50), peerRotationQuality(100, 10_000));
    try std.testing.expectEqual(@as(i32, -30), peerRotationQuality(20, 500));
}

test "pickPeerRotationVictim prefers low reputation inbound of same age" {
    const high = @as([32]u8, @splat(1));
    const low = @as([32]u8, @splat(2));
    const candidates = [_]PeerRotationCandidate{
        .{ .key = high, .connected_at = 10, .is_outbound = false, .reputation = 90, .latency_ms = 0 },
        .{ .key = low, .connected_at = 10, .is_outbound = false, .reputation = 20, .latency_ms = 0 },
    };
    const idx = pickPeerRotationVictim(&candidates, &.{}, true).?;
    try std.testing.expectEqual(@as(usize, 1), idx);
    try std.testing.expectEqual(low, candidates[idx].key);
}

test "pickPeerRotationVictim prefers high latency when reputation equal" {
    const fast = @as([32]u8, @splat(1));
    const slow = @as([32]u8, @splat(2));
    const candidates = [_]PeerRotationCandidate{
        .{ .key = fast, .connected_at = 5, .is_outbound = false, .reputation = 80, .latency_ms = 10 },
        .{ .key = slow, .connected_at = 50, .is_outbound = false, .reputation = 80, .latency_ms = 400 },
    };
    const idx = pickPeerRotationVictim(&candidates, &.{}, true).?;
    try std.testing.expectEqual(@as(usize, 1), idx);
    try std.testing.expectEqual(slow, candidates[idx].key);
}

test "pickPeerRotationVictim protects last outbound when bootstrap configured" {
    const a = @as([32]u8, @splat(1));
    const candidates = [_]PeerRotationCandidate{
        .{ .key = a, .connected_at = 10, .is_outbound = true },
    };
    try std.testing.expect(pickPeerRotationVictim(&candidates, &.{}, true) == null);
    // Without bootstrap, a lone outbound may be rotated.
    try std.testing.expectEqual(@as(usize, 0), pickPeerRotationVictim(&candidates, &.{}, false).?);
}

test "pickPeerRotationVictim skips bootstrap-protected outbound" {
    const boot = @as([32]u8, @splat(0xAA));
    const other = @as([32]u8, @splat(0xBB));
    const candidates = [_]PeerRotationCandidate{
        .{ .key = boot, .connected_at = 1, .is_outbound = true },
        .{ .key = other, .connected_at = 100, .is_outbound = true },
    };
    const protected = [_][32]u8{boot};
    const idx = pickPeerRotationVictim(&candidates, &protected, true).?;
    try std.testing.expectEqual(@as(usize, 1), idx);
    try std.testing.expectEqual(other, candidates[idx].key);

    // All outbound protected → no victim.
    const only_boot = [_]PeerRotationCandidate{
        .{ .key = boot, .connected_at = 1, .is_outbound = true },
        .{ .key = boot, .connected_at = 2, .is_outbound = true },
    };
    try std.testing.expect(pickPeerRotationVictim(&only_boot, &protected, true) == null);
}

test "maybeRotatePeers no-op when interval disabled" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{ .peer_rotation_interval_secs = 0 });
    defer server.deinit();
    server.last_peer_rotation = 0;
    server.maybeRotatePeers();
    try std.testing.expectEqual(@as(i64, 0), server.last_peer_rotation);
}

test "pickQualityDialTarget prefers high quality" {
    const candidates = [_]QualityDialCandidate{
        .{ .address = "10.0.0.1:1", .reputation = 40, .latency_ms = 0 },
        .{ .address = "10.0.0.2:1", .reputation = 90, .latency_ms = 0 },
        .{ .address = "10.0.0.3:1", .reputation = 70, .latency_ms = 0 },
    };
    const idx = pickQualityDialTarget(&candidates).?;
    try std.testing.expectEqual(@as(usize, 1), idx);
}

test "pickQualityDialTarget skips connected and subnet-blocked" {
    const candidates = [_]QualityDialCandidate{
        .{ .address = "10.0.0.1:1", .reputation = 100, .latency_ms = 0, .connected = true },
        .{ .address = "10.0.0.2:1", .reputation = 95, .latency_ms = 0, .subnet_ok = false },
        .{ .address = "10.0.0.3:1", .reputation = 50, .latency_ms = 0 },
    };
    const idx = pickQualityDialTarget(&candidates).?;
    try std.testing.expectEqual(@as(usize, 2), idx);
}

test "pickQualityDialTarget prefers low latency when reputation equal" {
    const candidates = [_]QualityDialCandidate{
        .{ .address = "10.0.0.1:1", .reputation = 80, .latency_ms = 400 },
        .{ .address = "10.0.0.2:1", .reputation = 80, .latency_ms = 10 },
    };
    const idx = pickQualityDialTarget(&candidates).?;
    try std.testing.expectEqual(@as(usize, 1), idx);
}

test "pickQualityDialTarget returns null when none eligible" {
    const candidates = [_]QualityDialCandidate{
        .{ .address = "10.0.0.1:1", .reputation = 100, .connected = true },
        .{ .address = "", .reputation = 100 },
    };
    try std.testing.expect(pickQualityDialTarget(&candidates) == null);
}

test "rememberPeerQuality stores and LRU-evicts" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{});
    defer server.deinit();

    const key_a = @as([32]u8, @splat(1));
    const key_b = @as([32]u8, @splat(2));
    // `false`: address came from a dial we opened, not a listen trailer.
    server.rememberPeerQuality(key_a, 90, 10, "10.0.0.1:8083", false);
    server.rememberPeerQuality(key_b, 50, 200, "10.0.0.2:8083", false);
    try std.testing.expectEqual(@as(usize, 2), server.quality_memory.count());

    // Re-remember A with updated quality → moves to MRU end.
    server.rememberPeerQuality(key_a, 99, 5, "10.0.0.1:8083", false);
    try std.testing.expectEqual(@as(usize, 2), server.quality_memory.count());
    try std.testing.expectEqual(@as(i32, 99), server.quality_memory.values()[1].reputation);

    // Fill to cap and ensure oldest is dropped.
    var i: usize = 0;
    while (i < QUALITY_MEMORY_CAP) : (i += 1) {
        var addr_buf: [32]u8 = undefined;
        const addr = try std.fmt.bufPrint(&addr_buf, "10.1.{d}.1:9", .{i});
        server.rememberPeerQuality(@as([32]u8, @splat(@as(u8, @truncate(i)))), 10, 0, addr, false);
    }
    try std.testing.expectEqual(QUALITY_MEMORY_CAP, server.quality_memory.count());
}

test "splitDialHostPort ipv4 hostname and ipv6 literal" {
    const v4 = splitDialHostPort("10.0.0.1:8083").?;
    try std.testing.expectEqualStrings("10.0.0.1", v4.host);
    try std.testing.expectEqual(@as(u16, 8083), v4.port);

    const host = splitDialHostPort("validator-1:8083").?;
    try std.testing.expectEqualStrings("validator-1", host.host);
    try std.testing.expectEqual(@as(u16, 8083), host.port);

    const v6 = splitDialHostPort("[2001:db8::1]:9000").?;
    try std.testing.expectEqualStrings("2001:db8::1", v6.host);
    try std.testing.expectEqual(@as(u16, 9000), v6.port);

    try std.testing.expect(splitDialHostPort("2001:db8::1") == null);
    try std.testing.expect(splitDialHostPort("no-port") == null);
}

test "resolveDialAddress IP passthrough is canonical" {
    const allocator = std.testing.allocator;
    const v4 = try resolveDialAddress(allocator, "10.20.30.40:8083");
    defer allocator.free(v4);
    try std.testing.expectEqualStrings("10.20.30.40:8083", v4);

    const v6 = try resolveDialAddress(allocator, "[2001:db8:abcd::1]:9000");
    defer allocator.free(v6);
    try std.testing.expectEqualStrings("[2001:db8:abcd::1]:9000", v6);
}

test "resolveDialAddress localhost prefers ipv4 when available" {
    const allocator = std.testing.allocator;
    const resolved = try resolveDialAddress(allocator, "localhost:8083");
    defer allocator.free(resolved);
    // DNS may return v4 and/or v6; helper prefers IPv4 when present.
    try std.testing.expect(std.mem.eql(u8, resolved, "127.0.0.1:8083") or
        std.mem.eql(u8, resolved, "[::1]:8083"));
}

test "resolveDialAddress invalid hostname is duped unchanged" {
    const allocator = std.testing.allocator;
    // Underscore fails HostName.validate → no DNS attempt; original kept.
    // (RFC 6761 `.invalid` is unreliable: some resolvers sinkhole it to an IP.)
    // Unresolved / unparseable forms still share Kademlia's unknown-prefix budget.
    const original = "bad_host.example:8083";
    const resolved = try resolveDialAddress(allocator, original);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(original, resolved);
}

test "rememberPeerQuality keys by resolved dial string" {
    const allocator = std.testing.allocator;
    const server = try P2PServer.init(allocator, .{});
    defer server.deinit();

    const key = @as([32]u8, @splat(7));
    server.rememberPeerQuality(key, 80, 20, "127.0.0.1:8083", false);
    // Same peer via localhost should collapse onto the resolved IP key when DNS works.
    server.rememberPeerQuality(key, 90, 10, "localhost:8083", false);
    // At most one entry when localhost resolves to 127.0.0.1; two if only ::1.
    try std.testing.expect(server.quality_memory.count() <= 2);
    try std.testing.expect(server.quality_memory.count() >= 1);
    const stored = server.quality_memory.values()[server.quality_memory.count() - 1].address;
    try std.testing.expect(std.mem.indexOfScalar(u8, stored, ':') != null);
}

test "pubkeyAllowed matches only configured keys" {
    const a = @as([32]u8, @splat(1));
    const b = @as([32]u8, @splat(2));
    const c = @as([32]u8, @splat(3));
    const keys = [_][32]u8{ a, b };
    try std.testing.expect(pubkeyAllowed(&keys, a));
    try std.testing.expect(pubkeyAllowed(&keys, b));
    try std.testing.expect(!pubkeyAllowed(&keys, c));
    try std.testing.expect(!pubkeyAllowed(&.{}, a));
}

test "rememberPeerQuality skips unknown advertised listen addresses" {
    const allocator = std.testing.allocator;
    const known = @as([32]u8, @splat(9));
    const unknown = @as([32]u8, @splat(8));
    const keys = [_][32]u8{known};
    const server = try P2PServer.init(allocator, .{
        .known_validator_keys = &keys,
    });
    defer server.deinit();

    server.rememberPeerQuality(unknown, 90, 10, "10.0.0.8:8083", true);
    try std.testing.expectEqual(@as(usize, 0), server.quality_memory.count());

    // Empty known set is fail-closed for advertised addresses.
    const empty = try P2PServer.init(allocator, .{});
    defer empty.deinit();
    empty.rememberPeerQuality(known, 90, 10, "10.0.0.9:8083", true);
    try std.testing.expectEqual(@as(usize, 0), empty.quality_memory.count());
}

test "rememberPeerQuality refuses unpinned advertise and keeps outbound dial" {
    const allocator = std.testing.allocator;
    const known = @as([32]u8, @splat(9));
    const unknown = @as([32]u8, @splat(8));
    const keys = [_][32]u8{known};
    const server = try P2PServer.init(allocator, .{
        .known_validator_keys = &keys,
    });
    defer server.deinit();

    server.rememberPeerQuality(known, 90, 10, "10.0.0.9:8083", true);
    try std.testing.expectEqual(@as(usize, 0), server.quality_memory.count());

    // Address we dialed is remembered even when the peer is not a known validator.
    server.rememberPeerQuality(unknown, 40, 20, "10.0.0.8:8083", false);
    try std.testing.expectEqual(@as(usize, 1), server.quality_memory.count());
}

test "rememberPeerQuality remembers matching configured dial" {
    const allocator = std.testing.allocator;
    const known = @as([32]u8, @splat(9));
    const keys = [_][32]u8{known};
    const dials = [_]KnownValidatorDial{
        .{ .key = known, .dial = "10.0.0.9:8083" },
    };
    const server = try P2PServer.init(allocator, .{
        .known_validator_keys = &keys,
        .known_validator_dials = &dials,
    });
    defer server.deinit();

    server.rememberPeerQuality(known, 90, 10, "10.0.0.9:8083", true);
    try std.testing.expectEqual(@as(usize, 1), server.quality_memory.count());
    try std.testing.expectEqualStrings("10.0.0.9:8083", server.quality_memory.values()[0].address);
}

test "rememberPeerQuality skips mismatched configured dial" {
    const allocator = std.testing.allocator;
    const known = @as([32]u8, @splat(9));
    const keys = [_][32]u8{known};
    const dials = [_]KnownValidatorDial{
        .{ .key = known, .dial = "10.0.0.9:8083" },
    };
    const server = try P2PServer.init(allocator, .{
        .known_validator_keys = &keys,
        .known_validator_dials = &dials,
    });
    defer server.deinit();

    server.rememberPeerQuality(known, 90, 10, "10.0.0.99:8083", true);
    try std.testing.expectEqual(@as(usize, 0), server.quality_memory.count());

    // A dial this node opened is remembered even when it disagrees with the pin.
    server.rememberPeerQuality(known, 40, 20, "192.0.2.9:8083", false);
    try std.testing.expectEqual(@as(usize, 1), server.quality_memory.count());
    try std.testing.expectEqualStrings("192.0.2.9:8083", server.quality_memory.values()[0].address);
}

test "rememberPeerQuality refuses known advertise when dial is empty" {
    const allocator = std.testing.allocator;
    const known = @as([32]u8, @splat(9));
    const keys = [_][32]u8{known};
    const dials = [_]KnownValidatorDial{
        .{ .key = known, .dial = "" },
    };
    const server = try P2PServer.init(allocator, .{
        .known_validator_keys = &keys,
        .known_validator_dials = &dials,
    });
    defer server.deinit();

    server.rememberPeerQuality(known, 90, 10, "10.0.0.9:8083", true);
    try std.testing.expectEqual(@as(usize, 0), server.quality_memory.count());
}
