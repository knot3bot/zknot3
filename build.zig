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

    // Vendored httpz QUIC (ngtcp2 + OpenSSL). Off by default so CI does not
    // need those libraries. `zig build -Dquic` links them and the node uses
    // UDP for `transport_type = quic`.
    const enable_quic = b.option(bool, "quic", "Link vendored httpz QUIC (ngtcp2 + OpenSSL)") orelse false;
    const openssl_include = b.option([]const u8, "openssl-include", "OpenSSL headers") orelse "/opt/homebrew/opt/openssl@3/include";
    const ngtcp2_include = b.option([]const u8, "ngtcp2-include", "ngtcp2 headers") orelse "/opt/homebrew/opt/libngtcp2/include";
    const openssl_lib = b.option([]const u8, "openssl-lib", "OpenSSL libraries") orelse "/opt/homebrew/opt/openssl@3/lib";
    const ngtcp2_lib = b.option([]const u8, "ngtcp2-lib", "ngtcp2 libraries") orelse "/opt/homebrew/opt/libngtcp2/lib";

    const quic_options = b.addOptions();
    quic_options.addOption(bool, "enabled", enable_quic);

    const httpz_quic_mod: ?*std.Build.Module = if (!enable_quic) null else blk: {
        const openssl_c = b.addTranslateC(.{
            .root_source_file = b.path("vendor/httpz/src/openssl.h"),
            .target = target,
            .optimize = optimize,
        });
        openssl_c.addIncludePath(.{ .cwd_relative = openssl_include });

        const ngtcp2_h = b.addTranslateC(.{
            .root_source_file = b.path("vendor/httpz/src/h3/ngtcp2.h"),
            .target = target,
            .optimize = optimize,
        });
        ngtcp2_h.addIncludePath(.{ .cwd_relative = ngtcp2_include });
        ngtcp2_h.addIncludePath(.{ .cwd_relative = openssl_include });

        const mod = b.createModule(.{
            .root_source_file = b.path("vendor/httpz/src/h3/quic.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addImport("openssl_c", openssl_c.createModule());
        mod.addImport("ngtcp2_c", ngtcp2_h.createModule());
        mod.addLibraryPath(.{ .cwd_relative = openssl_lib });
        mod.addLibraryPath(.{ .cwd_relative = ngtcp2_lib });
        mod.addRPath(.{ .cwd_relative = openssl_lib });
        mod.addRPath(.{ .cwd_relative = ngtcp2_lib });
        // pkg-config on this machine resolves `ssl` to OpenSSL 4, while
        // libngtcp2_crypto_ossl is built against OpenSSL 3. Force the 3.x paths.
        const lib_opts: std.Build.Module.LinkSystemLibraryOptions = .{ .use_pkg_config = .no };
        mod.linkSystemLibrary("ssl", lib_opts);
        mod.linkSystemLibrary("crypto", lib_opts);
        mod.linkSystemLibrary("ngtcp2", lib_opts);
        mod.linkSystemLibrary("ngtcp2_crypto_ossl", lib_opts);
        break :blk mod;
    };

    const Wire = struct {
        quic_options: *std.Build.Module,
        httpz: ?*std.Build.Module,
        openssl_lib: []const u8,
        ngtcp2_lib: []const u8,

        fn attach(self: @This(), module: *std.Build.Module, bld: *std.Build, dep_mod: *std.Build.Module) void {
            module.addAnonymousImport("io_instance", .{ .root_source_file = bld.path("src/io_instance.zig") });
            module.addImport("blst", dep_mod);
            module.addImport("quic_options", self.quic_options);
            if (self.httpz) |quic_mod| {
                module.addImport("httpz_quic", quic_mod);
                module.addLibraryPath(.{ .cwd_relative = self.openssl_lib });
                module.addLibraryPath(.{ .cwd_relative = self.ngtcp2_lib });
                module.addRPath(.{ .cwd_relative = self.openssl_lib });
                module.addRPath(.{ .cwd_relative = self.ngtcp2_lib });
                const lib_opts: std.Build.Module.LinkSystemLibraryOptions = .{ .use_pkg_config = .no };
                module.linkSystemLibrary("ssl", lib_opts);
                module.linkSystemLibrary("crypto", lib_opts);
                module.linkSystemLibrary("ngtcp2", lib_opts);
                module.linkSystemLibrary("ngtcp2_crypto_ossl", lib_opts);
            }
        }
    };
    const wire = Wire{
        .quic_options = quic_options.createModule(),
        .httpz = httpz_quic_mod,
        .openssl_lib = openssl_lib,
        .ngtcp2_lib = ngtcp2_lib,
    };

    // Main library module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wire.attach(root_module, b, blst_mod);

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
    wire.attach(test_module, b, blst_mod);

    // Unit-only tests — fast, no filesystem/network dependencies
    const unit_module = b.createModule(.{
        .root_source_file = b.path("tests_unit.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    wire.attach(unit_module, b, blst_mod);
    const unit_tests = b.addTest(.{ .root_module = unit_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("test-unit", "Run unit tests (fast, no I/O)");
    unit_test_step.dependOn(&run_unit_tests.step);

    // Integration tests — full suite including I/O-dependent tests
    const integration_tests = b.addTest(.{ .root_module = test_module });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run full test suite");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Combined test suite
    const all_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_all_tests = b.addRunArtifact(all_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_all_tests.step);

    // Executable proofs — exhaustive machine verification of core safety
    // properties (quorum intersection, BFT bound, lattice order, leader
    // election). See tools/formal/proofs.zig.
    const formal_proofs_module = b.createModule(.{
        .root_source_file = b.path("tools/formal/proofs.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    wire.attach(formal_proofs_module, b, blst_mod);
    const formal_proofs = b.addTest(.{ .root_module = formal_proofs_module });
    const run_formal_proofs = b.addRunArtifact(formal_proofs);
    const formal_step = b.step("test-formal", "Run executable formal proofs");
    formal_step.dependOn(&run_formal_proofs.step);
    test_step.dependOn(&run_formal_proofs.step);

    // ========================================================================
    // Formal Specification Export
    // ========================================================================

    const formal_module = b.createModule(.{
        .root_source_file = b.path("tools/formal/export.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    wire.attach(formal_module, b, blst_mod);

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

    // Benchmark step — unit tests in ReleaseFast for throughput measurement.
    // (A 0.17.0-dev toolchain miscompile of odd-padded union fields required
    // a brief ReleaseSafe detour; fixed by padding Value.ResourceLoc to 40
    // bytes — see the comment there.)
    const bench_module = b.createModule(.{
        .root_source_file = b.path("tests_unit.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    wire.attach(bench_module, b, blst_mod);
    const bench_exe = b.addTest(.{ .root_module = bench_module });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("benchmark", "Run benchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // Profiler tool
    const profiler_module = b.createModule(.{
        .root_source_file = b.path("tools/profiler/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    wire.attach(profiler_module, b, blst_mod);
    const profiler = b.addExecutable(.{
        .name = "zknot3-profiler",
        .root_module = profiler_module,
    });
    b.installArtifact(profiler);

    const cutover_module = b.createModule(.{
        .root_source_file = b.path("src/cutover_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wire.attach(cutover_module, b, blst_mod);
    const cutover = b.addExecutable(.{
        .name = "zknot3-cutover",
        .root_module = cutover_module,
    });
    b.installArtifact(cutover);

    // Fast build (ReleaseFast)
    const fast_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    wire.attach(fast_module, b, blst_mod);
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
    wire.attach(safe_module, b, blst_mod);
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
    wire.attach(debug_module, b, blst_mod);
    const debug_exe = b.addExecutable(.{
        .name = "zknot3-node-debug",
        .root_module = debug_module,
    });
    b.installArtifact(debug_exe);
}
