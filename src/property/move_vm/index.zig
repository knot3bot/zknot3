//! Move VM module - Move bytecode execution with linear types

pub const Gas = @import("Gas.zig");
pub const Resource = @import("Resource.zig").Resource;
pub const ResourceTracker = @import("Resource.zig").ResourceTracker;
pub const Bytecode = @import("Bytecode.zig");
pub const Interpreter = @import("Interpreter.zig").Interpreter;
