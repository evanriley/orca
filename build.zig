const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const acoustid_key = b.option(
        []const u8,
        "acoustid-key",
        "AcoustID application key orca-cli and orca-gtk use for lookups and submissions",
    ) orelse "AqlfLksN1K";
    const provider_contact = b.option(
        []const u8,
        "provider-contact",
        "Contact orca-cli and orca-gtk give MusicBrainz, AcoustID and ListenBrainz in their User-Agent",
    ) orelse "evan@evanriley.com";
    const app_options = b.addOptions();
    app_options.addOption([]const u8, "acoustid_key", acoustid_key);
    app_options.addOption([]const u8, "provider_contact", provider_contact);
    const app_options_module = app_options.createModule();

    const sqlite_translate = b.addTranslateC(.{
        .root_source_file = b.path("liborca/database/sqlite_import.h"),
        .target = target,
        .optimize = optimize,
    });
    for (pkgConfigIncludePaths(b, "sqlite3")) |include_path| {
        sqlite_translate.addSystemIncludePath(include_path);
    }
    const sqlite_module = sqlite_translate.createModule();
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const liborca_module = b.addModule("liborca", .{
        .root_source_file = b.path("liborca/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_module },
            .{ .name = "build_options", .module = version_options.createModule() },
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
    // The reference QOA decoder, vendored like minimp3.
    liborca_module.addCSourceFile(.{
        .file = b.path("liborca/codec/qoa_shim.c"),
        .flags = &.{ "-std=c11", "-DNDEBUG" },
    });
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
    for ([_][]const u8{ "ogg", "opus" }) |package| {
        liborca_module.addSystemIncludePath(pkgConfigIncludeDir(b, package));
    }
    addAlac(b, liborca_module);
    @import("build/libxaac.zig").addTo(b, liborca_module);
    const chromaprint_licences = @import("build/chromaprint.zig").addTo(b, liborca_module);
    liborca_module.addCSourceFile(.{
        .file = b.path("liborca/audio/samplerate_shim.c"),
        .flags = &.{ "-std=c11", "-DNDEBUG" },
    });
    liborca_module.linkSystemLibrary("samplerate", .{ .use_pkg_config = .yes });
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
    excludeCFromFuzzing(b, liborca_module);

    const liborca = b.addLibrary(.{
        .name = "orca",
        .linkage = .static,
        .root_module = liborca_module,
    });
    liborca.installHeader(b.path("liborca/orca.h"), "orca/orca.h");
    installLicenses(b);
    b.getInstallStep().dependOn(chromaprint_licences);
    b.installArtifact(liborca);
    const lib_step = b.step("lib", "Build the static liborca and orca.h");
    lib_step.dependOn(&b.addInstallArtifact(liborca, .{}).step);

    const header = @embedFile("liborca/orca.h");
    const liborca_shared = b.addLibrary(.{
        .name = "orca",
        .linkage = .dynamic,
        .root_module = liborca_module,
        .version = .{ .major = abiVersion(header), .minor = 0, .patch = 0 },
    });
    if (target.result.ofmt == .elf) {
        const version_script = b.addWriteFiles().add("orca.map", versionScript(b, header));
        liborca_shared.setVersionScript(version_script);
        // Zig's own ELF linker ignores version scripts.
        liborca_shared.use_llvm = true;
        liborca_shared.use_lld = true;
    }
    b.installArtifact(liborca_shared);
    const pkg_config = b.addInstallFile(
        b.addWriteFiles().add("orca.pc", pkgConfigFile(b, target.result.os.tag)),
        "lib/pkgconfig/orca.pc",
    );
    b.getInstallStep().dependOn(&pkg_config.step);
    lib_step.dependOn(&pkg_config.step);

    const cli = b.addExecutable(.{
        .name = "orca-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "liborca", .module = liborca_module },
                .{ .name = "build_options", .module = app_options_module },
            },
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

    const orca_header_translate = b.addTranslateC(.{
        .root_source_file = b.path("liborca/orca.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const integration_options = b.addOptions();
    integration_options.addOptionPath("orca_cli", cli.getEmittedBin());
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "liborca", .module = liborca_module },
                .{ .name = "integration_options", .module = integration_options.createModule() },
                .{ .name = "orca_h", .module = orca_header_translate.createModule() },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const released_header_translate = b.addTranslateC(.{
        .root_source_file = b.path("tests/abi/orca-0.8.1.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const abi_compat_module = b.createModule(.{
        .root_source_file = b.path("tests/abi/compat.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "orca_h", .module = orca_header_translate.createModule() },
            .{ .name = "orca_h_released", .module = released_header_translate.createModule() },
        },
    });
    abi_compat_module.linkLibrary(liborca);
    const abi_compat_tests = b.addTest(.{
        .name = "abi-compat",
        .root_module = abi_compat_module,
    });
    const run_abi_compat_tests = b.addRunArtifact(abi_compat_tests);

    const released_client_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    released_client_module.addCSourceFile(.{
        .file = b.path("tests/abi/scan_stats_0_8_1.c"),
        .flags = &.{"-std=c11"},
    });
    released_client_module.addIncludePath(b.path("tests/abi"));
    released_client_module.linkLibrary(liborca);
    const released_client = b.addExecutable(.{
        .name = "abi-0.8.1-scan-stats",
        .root_module = released_client_module,
    });
    const run_released_client = b.addRunArtifact(released_client);

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
    if (target.result.os.tag == .linux) {
        // The smoke test plays audio and refuses to run on Linux without a
        // silent sink, since the default output is somebody's speakers.
        const silent_sink = b.addSystemCommand(&.{ "sh", "-c", "ORCA_CLI=\"$1\" exec \"$0\"" });
        silent_sink.addFileArg(b.path("scripts/silent-sink.sh"));
        silent_sink.addArtifactArg(cli);
        silent_sink.has_side_effects = true;
        run_c_abi_smoke.addFileArg(silent_sink.captureStdOut(.{}));
    }

    const test_step = b.step("test", "Run all unit and integration tests");
    test_step.dependOn(chromaprint_licences);
    test_step.dependOn(&run_unit_tests.step);
    // Built as its own project, so the documented way to embed liborca as a
    // Zig package dependency is exercised rather than asserted.
    const embed_example = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    embed_example.setCwd(b.path("examples/embed"));
    test_step.dependOn(&embed_example.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_c_abi_smoke.step);
    const abi_compat_step = b.step("abi-compat", "Check orca.h keeps the layouts, values and functions of the released 0.8.1 header");
    abi_compat_step.dependOn(&run_abi_compat_tests.step);
    abi_compat_step.dependOn(&run_released_client.step);
    test_step.dependOn(&run_abi_compat_tests.step);
    test_step.dependOn(&run_released_client.step);
    if (target.result.os.tag == .linux) {
        const check_exports = b.addSystemCommand(&.{"bash"});
        check_exports.addFileArg(b.path("scripts/check-exports.sh"));
        check_exports.addArtifactArg(liborca_shared);
        check_exports.addFileArg(b.path("liborca/orca.h"));
        const abi_exports_step = b.step("abi-exports", "Check liborca.so exports exactly the functions orca.h declares");
        abi_exports_step.dependOn(&check_exports.step);
        test_step.dependOn(&check_exports.step);
    }
    const check_abi_coverage = b.addSystemCommand(&.{"bash"});
    check_abi_coverage.addFileArg(b.path("scripts/check-abi-coverage.sh"));
    check_abi_coverage.addFileArg(b.path("liborca/core/runtime.zig"));
    check_abi_coverage.addFileArg(b.path("liborca/c_api.zig"));
    const abi_coverage_step = b.step("abi-coverage", "Check every Runtime method has a C ABI path or a stated reason it has none");
    abi_coverage_step.dependOn(&check_abi_coverage.step);
    test_step.dependOn(&check_abi_coverage.step);
    const check_cli_stdio = b.addSystemCommand(&.{"bash"});
    check_cli_stdio.addFileArg(b.path("scripts/check-cli-stdio.sh"));
    check_cli_stdio.addArtifactArg(cli);
    _ = check_cli_stdio.addOutputDirectoryArg("cli-stdio");
    test_step.dependOn(&check_cli_stdio.step);
    if (target.result.os.tag == .linux) {
        const check_output_fail_closed = b.addSystemCommand(&.{"bash"});
        check_output_fail_closed.addFileArg(b.path("scripts/check-output-fail-closed.sh"));
        check_output_fail_closed.addArtifactArg(cli);
        _ = check_output_fail_closed.addOutputDirectoryArg("output-fail-closed");
        check_output_fail_closed.has_side_effects = true;
        test_step.dependOn(&check_output_fail_closed.step);
    }

    const manifest = @import("build.zig.zon");
    const check_package = b.addSystemCommand(&.{"bash"});
    check_package.addFileArg(b.path("scripts/check-package.sh"));
    check_package.addArgs(&.{ b.graph.zig_exe, b.pathFromRoot("."), manifest.version });
    inline for (@typeInfo(@TypeOf(manifest.dependencies)).@"struct".fields) |field| {
        const dependency = @field(manifest.dependencies, field.name);
        if (@hasField(@TypeOf(dependency), "hash")) {
            check_package.addArg(b.graph.global_cache_root.join(b.allocator, &.{ "p", dependency.hash ++ ".tar.gz" }) catch @panic("OOM"));
        }
    }
    check_package.has_side_effects = true;
    const package_check_step = b.step("package-check", "Build examples/embed and a standalone install against the fetched build.zig.zon package");
    package_check_step.dependOn(&check_package.step);

    const fuzz_tests = b.addTest(.{
        .root_module = liborca_module,
        .filters = &.{"fuzz:"},
        .use_llvm = true,
        .test_runner = .{ .path = b.path("build/test_runner.zig"), .mode = .server },
    });
    const fuzz_step = b.step("fuzz", "Replay fuzz seeds; add --fuzz to fuzz");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

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
            .imports = &.{
                .{ .name = "liborca", .module = liborca_module },
                .{ .name = "build_options", .module = app_options_module },
            },
        });
        linux_app_module.addAnonymousImport("hd650.txt", .{ .root_source_file = b.path("fixtures/eq/hd650.txt") });
        linux_app_module.linkSystemLibrary("gtk-4", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("libadwaita-1", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("libsecret-1", .{ .use_pkg_config = .yes });
        // Cover art is decoded at a bounded size through gdk-pixbuf's
        // scaling loader. GTK4 depends on it, but the frontend calls it
        // directly, so it has to be linked directly.
        linux_app_module.linkSystemLibrary("gdk-pixbuf-2.0", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("cairo", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("pango", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("gobject-2.0", .{ .use_pkg_config = .yes });
        linux_app_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .yes });
        const linux_app = b.addExecutable(.{
            .name = "orca-gtk",
            .root_module = linux_app_module,
        });
        b.installArtifact(linux_app);
        const signal_path_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("apps/linux/signal_path.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "liborca", .module = liborca_module }},
        }) });
        test_step.dependOn(&b.addRunArtifact(signal_path_tests).step);
        const browse_model_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("apps/linux/browse_model.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "liborca", .module = liborca_module }},
        }) });
        test_step.dependOn(&b.addRunArtifact(browse_model_tests).step);
        b.installFile("apps/linux/data/org.orca_music.Orca.desktop", "share/applications/org.orca_music.Orca.desktop");
        b.installFile("apps/linux/data/org.orca_music.Orca.svg", "share/icons/hicolor/scalable/apps/org.orca_music.Orca.svg");
        for ([_][]const u8{
            "orca-heart-filled-symbolic", "orca-heart-outline-symbolic",    "orca-pulse-symbolic",
            "orca-albums-symbolic",       "orca-artists-symbolic",          "orca-tracks-symbolic",
            "orca-genres-symbolic",       "orca-folders-symbolic",          "orca-loved-symbolic",
            "orca-playlists-symbolic",    "orca-now-playing-symbolic",      "orca-queue-symbolic",
            "orca-health-symbolic",       "orca-matches-symbolic",          "orca-settings-symbolic",
            "orca-signal-symbolic",       "orca-search-symbolic",           "orca-back-symbolic",
            "orca-forward-symbolic",      "orca-chevron-down-symbolic",     "orca-shuffle-symbolic",
            "orca-repeat-symbolic",       "orca-repeat-one-symbolic",       "orca-previous-symbolic",
            "orca-next-symbolic",         "orca-play-symbolic",             "orca-pause-symbolic",
            "orca-volume-high-symbolic",  "orca-volume-low-symbolic",       "orca-volume-muted-symbolic",
            "orca-filter-symbolic",       "orca-grid-symbolic",             "orca-list-symbolic",
            "orca-star-symbolic",         "orca-more-symbolic",             "orca-columns-symbolic",
            "orca-arrow-down-symbolic",   "orca-arrow-up-symbolic",         "orca-close-symbolic",
            "orca-plus-symbolic",         "orca-grip-symbolic",             "orca-sparkle-symbolic",
            "orca-pin-symbolic",          "orca-minus-symbolic",            "orca-chevron-right-symbolic",
            "orca-file-symbolic",         "orca-image-symbolic",            "orca-external-link-symbolic",
            "orca-check-symbolic",        "orca-device-dac-symbolic",       "orca-device-speaker-symbolic",
            "orca-device-tv-symbolic",    "orca-device-bluetooth-symbolic", "orca-refresh-symbolic",
            "orca-gain-symbolic",         "orca-engine-symbolic",           "orca-system-symbolic",
            "orca-info-symbolic",         "orca-undo-symbolic",             "orca-alert-symbolic",
            "orca-pen-symbolic",          "orca-type-symbolic",             "orca-wave-symbolic",
            "orca-clock-symbolic",        "orca-drive-off-symbolic",        "orca-shield-symbolic",
        }) |icon| {
            b.installFile(
                b.fmt("apps/linux/data/{s}.svg", .{icon}),
                b.fmt("share/icons/hicolor/scalable/actions/{s}.svg", .{icon}),
            );
        }
        for ([_][]const u8{ "Newsreader[opsz,wght].ttf", "Newsreader-Italic[opsz,wght].ttf", "Geist[wght].ttf", "GeistMono[wght].ttf", "Newsreader-OFL.txt", "Geist-OFL.txt", "GeistMono-OFL.txt" }) |font_file| {
            b.installFile(b.fmt("apps/linux/data/fonts/{s}", .{font_file}), b.fmt("share/orca/fonts/{s}", .{font_file}));
        }
        const run_linux_app = b.addRunArtifact(linux_app);
        run_linux_app.step.dependOn(b.getInstallStep());
        run_linux_app.setEnvironmentVariable("XDG_DATA_DIRS", if (b.graph.environ_map.get("XDG_DATA_DIRS")) |existing|
            b.fmt("{s}/share:{s}", .{ b.install_prefix, existing })
        else
            b.fmt("{s}/share:/usr/local/share:/usr/share", .{b.install_prefix}));
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

fn abiVersion(header: []const u8) u32 {
    const marker = "#define ORCA_ABI_VERSION ";
    const start = (std.mem.indexOf(u8, header, marker) orelse @panic("orca.h defines no ORCA_ABI_VERSION")) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, header, start, '\n') orelse header.len;
    return std.fmt.parseInt(u32, std.mem.trim(u8, header[start..end], " \t\r"), 10) catch
        @panic("ORCA_ABI_VERSION in orca.h is not a number");
}

fn declaredFunctions(b: *std.Build, header: []const u8) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or !(std.ascii.isAlphabetic(line[0]) or line[0] == '_')) continue;
        if (std.mem.startsWith(u8, line, "typedef")) continue;
        const open = std.mem.indexOfScalar(u8, line, '(') orelse continue;
        var start = open;
        while (start > 0 and (std.ascii.isAlphanumeric(line[start - 1]) or line[start - 1] == '_')) start -= 1;
        const name = line[start..open];
        if (!std.mem.startsWith(u8, name, "orca_")) continue;
        names.append(b.allocator, name) catch @panic("OOM");
    }
    return names.items;
}

/// Exports only what orca.h declares. A declared function liborca does not
/// define fails the link.
fn versionScript(b: *std.Build, header: []const u8) []const u8 {
    var script: std.ArrayList(u8) = .empty;
    script.appendSlice(b.allocator, "{\n  global:\n") catch @panic("OOM");
    for (declaredFunctions(b, header)) |name| {
        script.print(b.allocator, "    {s};\n", .{name}) catch @panic("OOM");
    }
    script.appendSlice(b.allocator, "  local: *;\n};\n") catch @panic("OOM");
    return script.items;
}

fn pkgConfigFile(b: *std.Build, os: std.Target.Os.Tag) []const u8 {
    return b.fmt(
        \\prefix={s}
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: orca
        \\Description: Headless engine of the Orca music player
        \\Version: {s}
        \\Cflags: -I${{includedir}}
        \\Libs: -L${{libdir}} -lorca
        \\Requires.private: sqlite3 flac opusfile vorbisfile samplerate{s}
        \\Libs.private: -lc++ -lm
        \\
    , .{
        b.install_prefix,
        @import("build.zig.zon").version,
        if (os == .linux) " libpipewire-0.3" else "",
    });
}

// `-ffuzz` would give the C libraries clang's coverage tables, whose layout
// Zig's fuzzer runtime rejects at startup; they are not fuzz targets anyway.
fn excludeCFromFuzzing(b: *std.Build, module: *std.Build.Module) void {
    const flag: []const []const u8 = &.{"-fno-sanitize=fuzzer-no-link"};
    for (module.link_objects.items) |object| switch (object) {
        .c_source_file => |source| source.flags = std.mem.concat(b.allocator, []const u8, &.{ source.flags, flag }) catch @panic("OOM"),
        .c_source_files => |sources| sources.flags = std.mem.concat(b.allocator, []const u8, &.{ sources.flags, flag }) catch @panic("OOM"),
        else => {},
    };
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

fn pkgConfigIncludeDir(b: *std.Build, package: []const u8) std.Build.LazyPath {
    const output = b.run(&.{ "pkg-config", "--variable=includedir", package });
    return .{ .cwd_relative = std.mem.trim(u8, output, " \n") };
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
/// contain the code, and ALAC and libxaac are compiled into liborca; so do the
/// MIT and BSD licences of Chromaprint and KissFFT.
fn installLicenses(b: *std.Build) void {
    const directory = "share/doc/orca/licenses";
    b.installFile("LICENSE", directory ++ "/orca/LICENSE");
    b.installFile("liborca/codec/vendor/minimp3/LICENSE", directory ++ "/minimp3/LICENSE");
    b.installFile("liborca/codec/vendor/qoa/LICENSE", directory ++ "/qoa/LICENSE");
    const alac = b.dependency("alac", .{});
    b.getInstallStep().dependOn(&b.addInstallFile(alac.path("LICENSE"), directory ++ "/alac/LICENSE").step);
    const libxaac = b.dependency("libxaac", .{});
    b.getInstallStep().dependOn(&b.addInstallFile(libxaac.path("LICENSE"), directory ++ "/libxaac/LICENSE").step);
    b.getInstallStep().dependOn(&b.addInstallFile(libxaac.path("NOTICE"), directory ++ "/libxaac/NOTICE").step);
    const chromaprint = b.dependency("chromaprint", .{});
    b.getInstallStep().dependOn(&b.addInstallFile(chromaprint.path("LICENSE.md"), directory ++ "/chromaprint/LICENSE.md").step);
    b.getInstallStep().dependOn(&b.addInstallFile(
        chromaprint.path("src/3rdparty/kissfft/LICENSES/BSD-3-Clause"),
        directory ++ "/kissfft/BSD-3-Clause",
    ).step);
}
