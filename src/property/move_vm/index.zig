//! Move VM module - Move bytecode execution with linear types

pub const Gas = @import("Gas.zig");
pub const Resource = @import("Resource.zig").Resource;
pub const ResourceTracker = @import("Resource.zig").ResourceTracker;
pub const Bytecode = @import("Bytecode.zig");
pub const Interpreter = @import("Interpreter.zig").Interpreter;
pub const NativeFunction = @import("NativeFunction.zig");
pub const Registry = NativeFunction.Registry;
pub const TxContext = @import("TxContext.zig").TxContext;
pub const EventEmitter = @import("EventEmitter.zig");
pub const Event = EventEmitter.Event;
