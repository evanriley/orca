//! Chromaprint, AcoustID's fingerprinter, built from source for liborca.
//!
//! Chromaprint's own code is MIT and KissFFT is BSD-3-Clause, but the
//! repository also carries FFmpeg's LGPL resampler (`src/avresample`). liborca
//! may only contain permissively licensed code, so that resampler is never
//! compiled: `config.h` leaves `USE_INTERNAL_AVRESAMPLE` undefined, Chromaprint
//! then accepts only 11025 Hz input, and Orca resamples with libsamplerate
//! before feeding it. `build/licence_check.zig` fails the build if any source
//! compiled here carries a GPL or LGPL notice.

const std = @import("std");

pub fn addTo(b: *std.Build, module: *std.Build.Module) *std.Build.Step {
    const chromaprint = b.dependency("chromaprint", .{});
    const config = b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        .HAVE_ROUND = 1,
        .HAVE_LRINTF = 1,
        .USE_KISSFFT = 1,
    });
    module.addConfigHeader(config);
    module.addIncludePath(chromaprint.path("src"));
    module.addIncludePath(chromaprint.path("src/3rdparty/kissfft"));
    module.link_libcpp = true;
    module.addCSourceFiles(.{
        .root = chromaprint.path("src"),
        .files = &cpp_sources,
        .flags = &(common_flags ++ .{ "-std=c++14", "-fno-exceptions", "-fno-rtti" }),
    });
    module.addCSourceFiles(.{
        .root = chromaprint.path("src"),
        .files = &c_sources,
        .flags = &(common_flags ++ .{"-std=c99"}),
    });
    module.addCSourceFile(.{
        .file = b.path("liborca/analysis/chromaprint_shim.c"),
        .flags = &.{ "-std=c11", "-DNDEBUG" },
    });

    const licence_check = b.addRunArtifact(b.addExecutable(.{
        .name = "licence-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/licence_check.zig"),
            .target = b.graph.host,
        }),
    }));
    licence_check.setName("check Chromaprint licences");
    for (cpp_sources ++ c_sources) |source| {
        const sub_path = b.fmt("src/{s}", .{source});
        licence_check.addArg(sub_path);
        licence_check.addFileArg(chromaprint.path(sub_path));
    }
    licence_check.expectExitCode(0);
    return &licence_check.step;
}

const common_flags = [_][]const u8{
    "-DNDEBUG",
    "-DHAVE_CONFIG_H",
    "-D_USE_MATH_DEFINES",
    "-D__STDC_LIMIT_MACROS",
    "-D__STDC_CONSTANT_MACROS",
    "-DCHROMAPRINT_NODLL",
    "-fvisibility=hidden",
    "-w",
};

const cpp_sources = [_][]const u8{
    "chromaprint.cpp",
    "audio_processor.cpp",
    "chroma.cpp",
    "chroma_resampler.cpp",
    "chroma_filter.cpp",
    "spectrum.cpp",
    "fft.cpp",
    "fft_lib_kissfft.cpp",
    "fingerprinter.cpp",
    "image_builder.cpp",
    "simhash.cpp",
    "silence_remover.cpp",
    "fingerprint_calculator.cpp",
    "fingerprint_compressor.cpp",
    "fingerprint_decompressor.cpp",
    "fingerprinter_configuration.cpp",
    "fingerprint_matcher.cpp",
    "utils/base64.cpp",
};

const c_sources = [_][]const u8{
    "3rdparty/kissfft/kiss_fft.c",
    "3rdparty/kissfft/kiss_fftr.c",
};
