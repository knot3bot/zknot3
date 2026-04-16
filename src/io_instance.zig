const std = @import("std");
const builtin = @import("builtin");
pub var io: std.Io = if (builtin.is_test) std.testing.io else undefined;
