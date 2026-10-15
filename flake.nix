{
  description = "Orca: a local-files-first music library and player built on liborca";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  nixConfig = {
    extra-substituters = [ "https://orca.cachix.org" ];
    extra-trusted-public-keys = [ "orca.cachix.org-1:Cn49KmT1A0Sg/RPfc6TnKmaQYirb2b58eZD6nUP/Nxg=" ];
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      forAllSystems = f: lib.genAttrs [ "x86_64-linux" ] (system: f nixpkgs.legacyPackages.${system});

      runtimeLibraries =
        pkgs: with pkgs; [
          sqlite
          flac
          libogg
          libopus
          opusfile
          libvorbis
          mpg123
          libsamplerate
          pipewire
          onnxruntime
          gtk4
          gtkmm4
          libadwaita
          libsecret
          curl
        ];

      buildTools =
        pkgs: with pkgs; [
          cmake
          ninja
          ccache
          pkg-config
          git
          python3
          sqlite-interactive.bin
          ffmpeg-headless
          wireplumber
        ];
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell.override { stdenv = pkgs.gcc15Stdenv; } {
          packages = [ pkgs.clang ] ++ buildTools pkgs;
          buildInputs = runtimeLibraries pkgs;
          shellHook = ''
            export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
