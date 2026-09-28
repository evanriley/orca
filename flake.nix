{
  description = "Orca: a local-files-first music library and player built on liborca";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
          system: f nixpkgs.legacyPackages.${system}
        );

      libraries =
        pkgs:
        [
          pkgs.sqlite
          pkgs.flac
          pkgs.libogg
          pkgs.libopus
          pkgs.opusfile
          pkgs.libvorbis
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.pipewire
          pkgs.gtk4
        ];
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "orca";
          version = "0.2.0-alpha";
          src = self;

          deps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-GcUoKYhdhEWBlKPBiSJNa//HZLIb8QyuoxRumHYXmKw=";
          };

          nativeBuildInputs = [
            pkgs.zig.hook
            pkgs.pkg-config
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.wrapGAppsHook4 ];
          buildInputs = libraries pkgs;

          postConfigure = ''
            ln -s ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';
        });
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.zls
            pkgs.pkg-config
          ];
          buildInputs = libraries pkgs;
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
