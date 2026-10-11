const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const embeddings = b.option(bool, "embeddings", "Build liborca with audio embeddings; needs ONNX Runtime") orelse true;
    const orca = b.dependency("orca", .{ .target = target, .optimize = optimize, .embeddings = embeddings });

    const exe = b.addExecutable(.{
        .name = "orca-embed-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "liborca", .module = orca.module("liborca") }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "List a library's tracks").dependOn(&run.step);
}
