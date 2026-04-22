const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tsan = b.option(bool, "tsan", "Enable thread-sanitizer oriented test profile") orelse false;
    _ = tsan;
    const blst_dep = b.dependency("blst", .{
        .target = target,
        .optimize = optimize,
    });
    const blst_mod = blst_dep.module("blst");

    const WireImports = struct {
        fn attach(module: *std.Build.Module, bld: *std.Build, dep_mod: *std.Build.Module) void {
            module.addAnonymousImport("io_instance", .{ .root_source_file = bld.path("src/io_instance.zig") });
            module.addImport("blst", dep_mod);
        }
    };

    // Main library module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    WireImports.attach(root_module, b, blst_mod);

    // Static library
    const lib = b.addLibrary(.{
        .name = "zknot3",
        .root_module = root_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ========================================================================
    // Test Configuration
    // ========================================================================

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    WireImports.attach(test_module, b, blst_mod);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const unit_test_step = b.step("test-unit", "Run unit tests");
    unit_test_step.dependOn(&unit_tests.step);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = test_module,
    });

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&integration_tests.step);

    // All tests
    const all_tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&all_tests.step);

    // ========================================================================
    // Formal Specification Export
    // ========================================================================

    const formal_module = b.createModule(.{
        .root_source_file = b.path("tools/formal/export.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    WireImports.attach(formal_module, b, blst_mod);

    const formal_exporter = b.addExecutable(.{
        .name = "zknot3-formal-export",
        .root_module = formal_module,
    });
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
        .link_libc = true,
    });
    WireImports.attach(profiler_module, b, blst_mod);
    const profiler = b.addExecutable(.{
        .name = "zknot3-profiler",
        .root_module = profiler_module,
    });
    b.installArtifact(profiler);

    // Fast build (ReleaseFast)
    const fast_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    WireImports.attach(fast_module, b, blst_mod);
    const release_fast = b.addExecutable(.{
        .name = "zknot3-node-fast",
        .root_module = fast_module,
    });
    b.installArtifact(release_fast);

    // Safe build (ReleaseSafe)
    const safe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    WireImports.attach(safe_module, b, blst_mod);
    const release_safe = b.addExecutable(.{
        .name = "zknot3-node-safe",
        .root_module = safe_module,
    });
    b.installArtifact(release_safe);

    // Debug build (Debug)
    const debug_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    WireImports.attach(debug_module, b, blst_mod);
    const debug_exe = b.addExecutable(.{
        .name = "zknot3-node-debug",
        .root_module = debug_module,
    });
    b.installArtifact(debug_exe);
}
