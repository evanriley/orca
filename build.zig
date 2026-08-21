const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_translate = b.addTranslateC(.{
        .root_source_file = b.path("liborca/database/sqlite_import.h"),
        .target = target,
        .optimize = optimize,
    });
    const sqlite_module = sqlite_translate.createModule();

    const liborca_module = b.addModule("liborca", .{
        .root_source_file = b.path("liborca/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "sqlite", .module = sqlite_module }},
    });
    liborca_module.linkSystemLibrary("sqlite3", .{ .use_pkg_config = .yes });
    if (target.result.os.tag == .linux) {
        liborca_module.addCSourceFile(.{
            .file = b.path("liborca/audio/backends/pipewire_shim.c"),
            .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-D_REENTRANT" },
        });
        liborca_module.addSystemIncludePath(
            b.graph.cwdRelativePath("/usr/include/pipewire-0.3"),
        );
        liborca_module.addSystemIncludePath(
            b.graph.cwdRelativePath("/usr/include/spa-0.2"),
        );
        liborca_module.linkSystemLibrary("pipewire-0.3", .{ .use_pkg_config = .no });
    }

    const liborca = b.addLibrary(.{
        .name = "orca",
        .linkage = .static,
        .root_module = liborca_module,
    });
    b.installArtifact(liborca);

    const cli = b.addExecutable(.{
        .name = "orca-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "liborca", .module = liborca_module }},
        }),
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    run_cli.addPassthruArgs();
    const run_step = b.step("run", "Run orca-cli");
    run_step.dependOn(&run_cli.step);

    const unit_tests = b.addTest(.{ .root_module = liborca_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "liborca", .module = liborca_module }},
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run all unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    if (target.result.os.tag == .linux) {
        const dependency_test_module = b.createModule(.{
            .root_source_file = b.path("tests/platform/pipewire_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        dependency_test_module.linkSystemLibrary("pipewire-0.3", .{
            // PipeWire currently emits compiler flags that Zig's development
            // pkg-config parser rejects. Library discovery still follows the
            // platform linker paths; adapter modules will own C include paths.
            .use_pkg_config = .no,
        });
        const dependency_tests = b.addTest(.{ .root_module = dependency_test_module });
        const run_dependency_tests = b.addRunArtifact(dependency_tests);
        test_step.dependOn(&run_dependency_tests.step);

        const dependency_step = b.step(
            "dependency-smoke",
            "Verify the Linux foreign-library linking pattern",
        );
        dependency_step.dependOn(&run_dependency_tests.step);

        const pipewire_live_smoke = b.addExecutable(.{
            .name = "pipewire-live-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/platform/pipewire_live_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "liborca", .module = liborca_module }},
            }),
        });
        const run_pipewire_live_smoke = b.addRunArtifact(pipewire_live_smoke);
        const pipewire_live_step = b.step(
            "pipewire-live-smoke",
            "Open a short silent stream against the current PipeWire server",
        );
        pipewire_live_step.dependOn(&run_pipewire_live_smoke.step);
    }

    const benchmark = b.addExecutable(.{
        .name = "orca-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "liborca", .module = liborca_module }},
        }),
    });
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.addPassthruArgs();
    const benchmark_step = b.step("bench", "Run Orca benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);
}
