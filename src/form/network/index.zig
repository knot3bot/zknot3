//! Network module - QUIC/TCP networking
//!
//! Re-exports all network submodules

pub const P2P = @import("P2P.zig");
pub const RPC = @import("RPC.zig");
pub const HTTPServer = @import("HTTPServer.zig").HTTPServer;
pub const Transport = @import("Transport.zig");
pub const Topology = @import("Topology.zig");
pub const P2PServer = @import("P2PServer.zig").P2PServer;
pub const Kademlia = @import("Kademlia.zig");
pub const QUIC = @import("QUIC.zig");
pub const Yamux = @import("Yamux.zig");
pub const Noise = @import("Noise.zig");

// Re-export commonly used types
pub const RPCServer = RPC.RPCServer;
pub const RPCContext = RPC.RPCContext;
pub const RPCResponse = RPC.RPCResponse;
pub const P2PNode = P2P.P2PNode;
pub const PeerManager = P2P.PeerManager;
pub const PeerConnection = P2PServer.PeerConnection;
pub const RoutingTable = Kademlia.RoutingTable;
pub const KBucket = Kademlia.KBucket;
pub const QUICTransport = QUIC.QUICTransport;
pub const QUICConnection = QUIC.QUICConnection;
pub const YamuxSession = Yamux.YamuxSession;
pub const NoiseSession = Noise.NoiseSession;
pub const NoiseKeypair = Noise.NoiseKeypair;
