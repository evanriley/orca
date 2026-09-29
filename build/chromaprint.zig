//! Chromaprint, AcoustID's fingerprinter, built from source for liborca.
//!
//! Chromaprint's own code is MIT and KissFFT is BSD-3-Clause, but the
//! repository also carries FFmpeg's LGPL resampler (`src/avresample`). liborca
//! may only contain permissively licensed code, so that resampler is never
//! compiled: `config.h` leaves `USE_INTERNAL_AVRESAMPLE` undefined, Chromaprint
//! then accepts only 11025 Hz input, and Orca resamples with libsamplerate
//! before feeding it. `LicenceCheck` fails the build if any source compiled
//! here carries a GPL or LGPL notice.

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

    const check = b.allocator.create(LicenceCheck) catch @panic("OOM");
    check.* = .{
        .step = .init(.{
            .id = .custom,
            .name = "check Chromaprint licences",
            .owner = b,
            .makeFn = LicenceCheck.make,
        }),
        .root = chromaprint.builder.build_root,
    };
    return &check.step;
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

/// Text that appears in every GPL and LGPL notice, in either the long form or
/// an SPDX identifier.
const copyleft_markers = [_][]const u8{ "General Public", "GPL" };

const LicenceCheck = struct {
    step: std.Build.Step,
    root: std.Build.Cache.Directory,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const self: *LicenceCheck = @fieldParentPtr("step", step);
        const io = step.owner.graph.io;
        for (cpp_sources ++ c_sources) |source| {
            const sub_path = try std.fs.path.join(options.gpa, &.{ "src", source });
            defer options.gpa.free(sub_path);
            const text = try self.root.handle.readFileAlloc(io, sub_path, options.gpa, .limited(1 << 20));
            defer options.gpa.free(text);
            for (copyleft_markers) |marker| {
                if (std.mem.indexOf(u8, text, marker) != null) return step.fail(
                    "Chromaprint source {s} contains \"{s}\"; liborca may only compile permissively licensed code. Remove it from build/chromaprint.zig.",
                    .{ sub_path, marker },
                );
            }
        }
    }
};
