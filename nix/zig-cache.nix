{
  stdenv,
  zig_0_17,
}:

stdenv.mkDerivation {
  pname = "zig-cache";
  inherit (zig_0_17) version;

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ zig_0_17.hook ];

  postConfigure = ''
    cat > build.zig <<'ZIG'
    const std = @import("std");

    pub fn build(b: *std.Build) void {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});
        const root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const translated = b.addTranslateC(.{
            .root_source_file = b.path("seed.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        root_module.addImport("seed_c", translated.createModule());
        b.installArtifact(b.addExecutable(.{ .name = "seed", .root_module = root_module }));
        b.installArtifact(b.addLibrary(.{ .name = "seed", .linkage = .dynamic, .root_module = root_module }));
    }
    ZIG
    cat > main.zig <<'ZIG'
    comptime {
        _ = @import("seed_c");
    }

    pub fn main() void {}
    ZIG
    echo 'int seed(void);' > seed.h
  '';

  installPhase = ''
    mkdir "$out"
    cp -r "$ZIG_GLOBAL_CACHE_DIR"/{b,h,o,z} "$out"
  '';
}
