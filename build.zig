const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const qoa_dependency = b.dependency("qoa", .{ .target = target, .optimize = optimize });

    const sqlite_translate = b.addTranslateC(.{
        .root_source_file = b.path("liborca/database/sqlite_import.h"),
        .target = target,
        .optimize = optimize,
    });
    for (pkgConfigIncludePaths(b, "sqlite3")) |include_path| {
        sqlite_translate.addSystemIncludePath(include_path);
    }
    const sqlite_module = sqlite_translate.createModule();

    const liborca_module = b.addModule("liborca", .{
        .root_source_file = b.path("liborca/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_module },
            .{ .name = "qoa", .module = qoa_dependency.module("qoa") },
        },
    });
    liborca_module.linkSystemLibrary("sqlite3", .{ .use_pkg_config = .yes });
    // Vendored minimp3 behind a narrow shim. Header-only and public domain,
    // so this is a source addition on every target and not a system linkage.
    liborca_module.addCSourceFile(.{
        .file = b.path("liborca/codec/mp3_shim.c"),
        .flags = &.{ "-std=c11", "-DNDEBUG" },
    });
    // libFLAC behind a narrow shim. The reference implementation is used
    // because FLAC's only promise is bit-exactness, and the pure-Zig package
    // this replaced did not keep it -- see `docs/codecs.md`.
    liborca_module.addCSourceFile(.{
        .file = b.path("liborca/codec/flac_shim.c"),
        .flags = &.{ "-std=c11", "-DNDEBUG" },
    });
    liborca_module.linkSystemLibrary("FLAC", .{ .use_pkg_config = .yes });
    liborca_module.addCSourceFile(.{
        .file = b.path("liborca/codec/opus_shim.c"),
        .flags = &.{ "-std=c11", "-DNDEBUG" },
    });
    liborca_module.linkSystemLibrary("opusfile", .{ .use_pkg_config = .yes });
    liborca_module.addCSourceFile(.{
        .file = b.path("liborca/codec/vorbis_shim.c"),
        .flags = &.{ "-std=c11", "-DNDEBUG" },
    });
    liborca_module.linkSystemLibrary("vorbisfile", .{ .use_pkg_config = .yes });
    addAlac(b, liborca_module);
    @import("build/libxaac.zig").addTo(b, liborca_module);
    liborca_module.addCSourceFile(.{
        .file = b.path("liborca/codec/aac_shim.c"),
        .flags = &.{ "-std=c11", "-DNDEBUG" },
    });
    if (target.result.os.tag == .linux) {
        liborca_module.addCSourceFile(.{
            .file = b.path("liborca/audio/backends/pipewire_shim.c"),
            .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-D_REENTRANT" },
        });
        for (pkgConfigIncludePaths(b, "libpipewire-0.3")) |include_path| {
            liborca_module.addSystemIncludePath(include_path);
        }
        liborca_module.linkSystemLibrary("pipewire-0.3", .{ .use_pkg_config = .no });
    }

    const liborca = b.addLibrary(.{
        .name = "orca",
        .linkage = .static,
        .root_module = liborca_module,
    });
    liborca.installHeader(b.path("liborca/orca.h"), "orca/orca.h");
    installLicenses(b);
    b.installArtifact(liborca);

    const liborca_shared = b.addLibrary(.{
        .name = "orca",
        .linkage = .dynamic,
        .root_module = liborca_module,
    });
    b.installArtifact(liborca_shared);

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
    if (b.args) |args| run_cli.addArgs(args);
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

    const c_abi_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_abi_module.addCSourceFile(.{
        .file = b.path("tests/c_abi_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    c_abi_module.addIncludePath(b.path("liborca"));
    const c_abi_smoke = b.addExecutable(.{
        .name = "c-abi-smoke",
        .root_module = c_abi_module,
    });
    c_abi_module.linkLibrary(liborca);
    const run_c_abi_smoke = b.addRunArtifact(c_abi_smoke);

    const test_step = b.step("test", "Run all unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_c_abi_smoke.step);

    if (target.result.os.tag == .linux) {
        // The GTK4 frontend is Zig and consumes liborca's Zig-facing API
        // directly. GTK itself is bound with hand-written `extern fn`
        // declarations in `apps/linux/gtk.zig`, so no C include paths are
        // needed here — only the linkage pkg-config resolves.
        const linux_app_module = b.createModule(.{
            .root_source_file = b.path("apps/linux/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "liborca", .module = liborca_module }},
        });
        linux_app_module.linkSystemLibrary("gtk-4", .{ .use_pkg_config = .yes });
        // Cover art is decoded at a bounded size through gdk-pixbuf's
        // scaling loader. GTK4 depends on it, but the frontend calls it
        // directly, so it has to be linked directly.
        linux_app_module.linkSystemLibrary("gdk-pixbuf-2.0", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("gobject-2.0", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .yes });
        const linux_app = b.addExecutable(.{
            .name = "orca-gtk",
            .root_module = linux_app_module,
        });
        b.installArtifact(linux_app);
        const run_linux_app = b.addRunArtifact(linux_app);
        const run_linux_step = b.step("run-linux", "Run the native GTK4 frontend");
        run_linux_step.dependOn(&run_linux_app.step);

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
    if (b.args) |args| run_benchmark.addArgs(args);
    const benchmark_step = b.step("bench", "Run Orca benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    const dsp_benchmark = b.addExecutable(.{
        .name = "orca-dsp-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/dsp.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "liborca", .module = liborca_module }},
        }),
    });
    const run_dsp_benchmark = b.addRunArtifact(dsp_benchmark);
    if (b.args) |args| run_dsp_benchmark.addArgs(args);
    const dsp_benchmark_step = b.step("dsp-bench", "Compare scalar and SIMD DSP kernels");
    dsp_benchmark_step.dependOn(&run_dsp_benchmark.step);
}

/// Only `-I` paths are taken from pkg-config: PipeWire's full `--cflags`
/// contain flags that Zig's pkg-config integration rejects.
fn pkgConfigIncludePaths(b: *std.Build, package: []const u8) []const std.Build.LazyPath {
    const output = b.run(&.{ "pkg-config", "--cflags-only-I", package });
    var include_paths: std.ArrayList(std.Build.LazyPath) = .empty;
    var flags = std.mem.tokenizeAny(u8, output, " \n");
    while (flags.next()) |flag| {
        if (!std.mem.startsWith(u8, flag, "-I")) continue;
        include_paths.append(b.allocator, .{ .cwd_relative = flag[2..] }) catch @panic("OOM");
    }
    return include_paths.items;
}

/// Apple's reference ALAC decoder, built from source. Only the decoding half
/// is compiled, and only `alac_shim.cpp` sees its C++ interface. The
/// reference left-shifts negative values, which two's-complement targets
/// define, so the undefined-behaviour sanitizer is off for its files only.
fn addAlac(b: *std.Build, module: *std.Build.Module) void {
    const alac = b.dependency("alac", .{});
    const codec = alac.path("codec");
    module.addIncludePath(codec);
    module.link_libcpp = true;
    module.addCSourceFiles(.{
        .root = codec,
        .files = &.{
            "ag_dec.c",
            "ALACBitUtilities.c",
            "dp_dec.c",
            "EndianPortable.c",
            "matrix_dec.c",
        },
        .flags = &.{ "-std=c99", "-DNDEBUG", "-w", "-fno-sanitize=undefined" },
    });
    module.addCSourceFiles(.{
        .root = codec,
        .files = &.{"ALACDecoder.cpp"},
        .flags = &.{ "-std=c++11", "-DNDEBUG", "-fno-exceptions", "-fno-rtti", "-w", "-fno-sanitize=undefined" },
    });
    module.addCSourceFile(.{
        .file = b.path("liborca/codec/alac_shim.cpp"),
        .flags = &.{ "-std=c++11", "-DNDEBUG", "-fno-exceptions", "-fno-rtti" },
    });
}

/// Apache-2.0 requires its licence and any NOTICE to travel with binaries that
/// contain the code, and ALAC and libxaac are compiled into liborca.
fn installLicenses(b: *std.Build) void {
    const directory = "share/doc/orca/licenses";
    b.installFile("LICENSE", directory ++ "/orca/LICENSE");
    b.installFile("liborca/codec/vendor/minimp3/LICENSE", directory ++ "/minimp3/LICENSE");
    const alac = b.dependency("alac", .{});
    b.getInstallStep().dependOn(&b.addInstallFile(alac.path("LICENSE"), directory ++ "/alac/LICENSE").step);
    const libxaac = b.dependency("libxaac", .{});
    b.getInstallStep().dependOn(&b.addInstallFile(libxaac.path("LICENSE"), directory ++ "/libxaac/LICENSE").step);
    b.getInstallStep().dependOn(&b.addInstallFile(libxaac.path("NOTICE"), directory ++ "/libxaac/NOTICE").step);
}
