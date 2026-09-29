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
          pkgs.libsamplerate
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.pipewire
          pkgs.gtk4
          pkgs.libadwaita
          pkgs.libsecret
        ];
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "orca";
          version = builtins.head (
            builtins.match ''.*\.version = "([^"]+)".*'' (builtins.readFile ./build.zig.zon)
          );
          src = self;

          deps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-PagG6fv96840UDWtKFWP6tnRGahU8hMZTLjJtyFu23U=";
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

          meta.license = pkgs.lib.licenses.mpl20;
        });
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.zls
            pkgs.pkg-config
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.wireplumber ];
          buildInputs = libraries pkgs;
          shellHook = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
