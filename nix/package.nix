{
  lib,
  stdenv,
  zig_0_17,
  fetchurl,
  pkg-config,
  wrapGAppsHook4,
  sqlite,
  flac,
  libogg,
  libopus,
  opusfile,
  libvorbis,
  libsamplerate,
  onnxruntime,
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
      (lib.fileset.fileFilter (file: !file.hasExt "md") ../liborca)
      (lib.fileset.fileFilter (file: !file.hasExt "md") ../apps)
      ../LICENSE
      ../fixtures/eq/hd650.txt
    ];
  };

  deps = zig_0_17.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-zpLyab1/EdS5XvJ3utKYkfRhMv4IJJgZ3atwqbYEp7w=";
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
    onnxruntime
    pipewire
    gtk4
    libadwaita
    libsecret
  ];

  embeddingModel = fetchurl {
    url = "https://github.com/evanriley/orca/releases/download/model-clap-int8-1/clap_audio_int8.onnx";
    hash = "sha256-EtPiwVk7oRHfYQP+rC885PToXl78KtknrBaoQC57PDY=";
  };

  postConfigure = ''
    ln -s ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  postInstall = ''
    mkdir -p "$out/share/orca/models"
    ln -s ${finalAttrs.embeddingModel} "$out/share/orca/models/clap_audio_int8.onnx"
  '';

  meta = {
    description = "Local-files-first music player and library-maintenance application";
    homepage = "https://github.com/evanriley/orca";
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "orca-gtk";
  };
})
