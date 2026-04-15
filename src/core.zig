//! Core abstraction layer - Taiji (太极) layer
//! Contains fundamental types: ObjectID, VersionLattice, Ownership

pub const ObjectID = @import("core/ObjectID.zig").ObjectID;
pub const VersionLattice = @import("core/VersionLattice.zig");
pub const Version = @import("core/VersionLattice.zig").Version;
pub const Ownership = @import("core/Ownership.zig");
pub const Errors = @import("core/Errors.zig");
