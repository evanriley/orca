//! Apple's reference ALAC decoder, from the `evanriley/alac` fork that carries
//! Orca's bounds patches as commits. Only the decoding half is compiled, and
//! only `alac_shim.cpp` sees its C++ interface. The decoder relies on
//! two's-complement signed wraps and left shifts of negative values, so it is
//! built with `-fwrapv` and `-fno-sanitize=shift-base`; the rest of the
//! undefined-behaviour sanitizer, including shift-exponent, stays on so a Debug
//! build still traps any out-of-range shift the patches miss.

const std = @import("std");

pub fn addTo(b: *std.Build, module: *std.Build.Module) void {
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
        .flags = &.{ "-std=c99", "-DNDEBUG", "-w", "-fno-sanitize=shift-base", "-fwrapv" },
    });
    module.addCSourceFiles(.{
        .root = codec,
        .files = &.{"ALACDecoder.cpp"},
        .flags = &.{ "-std=c++11", "-DNDEBUG", "-fno-exceptions", "-fno-rtti", "-w", "-fno-sanitize=shift-base", "-fwrapv" },
    });
    module.addCSourceFile(.{
        .file = b.path("liborca/codec/alac_shim.cpp"),
        .flags = &.{ "-std=c++11", "-DNDEBUG", "-fno-exceptions", "-fno-rtti" },
    });
}
