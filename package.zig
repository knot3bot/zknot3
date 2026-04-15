// package.zig - zknot3 package configuration
//
// This file provides helper functions for adding zknot3 as a dependency.

const std = @import("std");

/// Add zknot3 package to a build
pub fn package(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
    });
    exe.addModule("zknot3", mod);
}
