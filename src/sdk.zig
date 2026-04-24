//! Zig Client SDK (runtime)
//!
//! This is a runtime client (not the multi-language generator in `src/app/ClientSDK.zig`).
//! It provides typed JSON-RPC calls and proof verification utilities.

pub const rpc = @import("sdk/rpc.zig");
pub const types = @import("sdk/types.zig");
pub const proof = @import("sdk/proof.zig");
pub const errors = @import("sdk/errors.zig");

