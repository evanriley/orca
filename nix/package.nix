{
  lib,
  stdenv,
  zig_0_17,
  pkg-config,
  wrapGAppsHook4,
  sqlite,
  flac,
  libogg,
  libopus,
  opusfile,
  libvorbis,
  libsamplerate,
  pipewire,
  gtk4,
  libadwaita,
  libsecret,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "orca";
  version = builtins.head (
    builtins.match ''.*\.version = "([^"]+)".*'' (builtins.readFile ../build.zig.zon)
  );

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../build
      ../liborca
      ../apps
      ../LICENSE
      ../fixtures/eq/hd650.txt
    ];
  };

  deps = zig_0_17.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-PagG6fv96840UDWtKFWP6tnRGahU8hMZTLjJtyFu23U=";
  };

  nativeBuildInputs = [
    zig_0_17.hook
    pkg-config
    wrapGAppsHook4
  ];

  buildInputs = [
    sqlite
    flac
    libogg
    libopus
    opusfile
    libvorbis
    libsamplerate
    pipewire
    gtk4
    libadwaita
    libsecret
  ];

  postConfigure = ''
    ln -s ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  meta = {
    description = "Local-files-first music player and library-maintenance application";
    homepage = "https://github.com/evanriley/orca";
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "orca-gtk";
  };
})
