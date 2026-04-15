const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addLibrary(.{
        .name = "zknot3",
        .root_module = root_module,
        .linkage = .static,
    });
    lib.linkLibC();
    b.installArtifact(lib);

    // ========================================================================
    // Test Configuration
    // ========================================================================

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
    });

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    unit_tests.linkLibC();

    const unit_test_step = b.step("test-unit", "Run unit tests");
    unit_test_step.dependOn(&unit_tests.step);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = test_module,
    });
    integration_tests.linkLibC();

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&integration_tests.step);

    // All tests
    const all_tests = b.addTest(.{
        .root_module = test_module,
    });
    all_tests.linkLibC();

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&all_tests.step);

    // ========================================================================
    // Formal Specification Export
    // ========================================================================

    const formal_module = b.createModule(.{
        .root_source_file = b.path("tools/formal/export.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const formal_exporter = b.addExecutable(.{
        .name = "zknot3-formal-export",
        .root_module = formal_module,
    });
    formal_exporter.linkLibC();
    b.installArtifact(formal_exporter);

    const export_coq_step = b.step("export-coq", "Export Coq formal specifications");
    export_coq_step.dependOn(&formal_exporter.step);

    // ========================================================================
    // Build Options
    // ========================================================================

    _ = b.option(bool, "export-formal", "Export formal specs to Coq/Lean") orelse false;
    _ = b.option(bool, "dev", "Enable dev mode with verbose logging") orelse false;

    // Install dev header files
    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("src"),
        .install_dir = .header,
        .install_subdir = "zknot3",
    });
    b.getInstallStep().dependOn(&install_headers.step);

    // ========================================================================
    // Executables
    // ========================================================================

    // Profiler tool
    const profiler_module = b.createModule(.{
        .root_source_file = b.path("tools/profiler/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const profiler = b.addExecutable(.{
        .name = "zknot3-profiler",
        .root_module = profiler_module,
    });
    profiler.linkLibC();
    b.installArtifact(profiler);

    // Fast build (ReleaseFast)
    const fast_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const release_fast = b.addExecutable(.{
        .name = "zknot3-node-fast",
        .root_module = fast_module,
    });
    release_fast.linkLibC();
    b.installArtifact(release_fast);

    // Safe build (ReleaseSafe)
    const safe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const release_safe = b.addExecutable(.{
        .name = "zknot3-node-safe",
        .root_module = safe_module,
    });
    release_safe.linkLibC();
    b.installArtifact(release_safe);

    // Debug build (Debug)
    const debug_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const debug_exe = b.addExecutable(.{
        .name = "zknot3-node-debug",
        .root_module = debug_module,
    });
    debug_exe.linkLibC();
    b.installArtifact(debug_exe);
}
