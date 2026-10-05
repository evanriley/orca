{
  lib,
  stdenv,
  zig,
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
    fileset = lib.fileset.difference ../. (
      lib.fileset.unions (
        map lib.fileset.maybeMissing [
          ../.zig-cache
          ../zig-out
          ../zig-pkg
          ../.direnv
          ../result
        ]
      )
    );
  };

  deps = zig.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-PagG6fv96840UDWtKFWP6tnRGahU8hMZTLjJtyFu23U=";
  };

  nativeBuildInputs = [
    zig.hook
    pkg-config
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ wrapGAppsHook4 ];

  buildInputs = [
    sqlite
    flac
    libogg
    libopus
    opusfile
    libvorbis
    libsamplerate
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
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
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
    mainProgram = if stdenv.hostPlatform.isLinux then "orca-gtk" else "orca-cli";
  };
})
