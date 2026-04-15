//! zknot3 - A Zig re-implementation of the Sui blockchain
//!
//! This module implements the "三源合恰" (Three Source Integration) framework:
//! - 形: Spatial topology and computational state
//! - 性: Intrinsic attributes and relation contracts
//! - 数: Quantitative measures and ordinal evolution

pub const core = @import("core.zig");
pub const form = @import("form.zig");
pub const property = @import("property.zig");
pub const metric = @import("metric.zig");
pub const pipeline = @import("pipeline.zig");
pub const app = @import("app.zig");
