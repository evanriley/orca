{
  description = "Orca: a local-files-first music library and player built on liborca";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      forAllSystems = f: lib.genAttrs [ "x86_64-linux" ] (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          orca = pkgs.callPackage ./nix/package.nix { };
        in
        {
          inherit orca;
          default = orca;
        }
      );

      apps = forAllSystems (pkgs: {
        orca-cli = {
          type = "app";
          program = lib.getExe' self.packages.${pkgs.stdenv.hostPlatform.system}.orca "orca-cli";
          meta.description = "Orca's command-line interface";
        };
      });

      overlays.default = final: prev: {
        orca = final.callPackage ./nix/package.nix { };
      };

      nixosModules = {
        default = self.nixosModules.orca;
        orca = import ./nix/nixos-module.nix self;
      };

      homeModules = {
        default = self.homeModules.orca;
        orca = import ./nix/home-module.nix self;
      };

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          orca = self.packages.${system}.orca;

          nixos = lib.nixosSystem {
            modules = [
              self.nixosModules.default
              {
                nixpkgs.hostPlatform = system;
                programs.orca.enable = true;
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                system.stateVersion = "25.11";
              }
            ];
          };
        in
        {
          inherit orca;

          zig-fmt = pkgs.runCommand "orca-zig-fmt" { nativeBuildInputs = [ pkgs.zig_0_17 ]; } ''
            export HOME="$TMPDIR"
            cd ${self}
            zig fmt --check liborca apps benchmarks tests build build.zig
            touch "$out"
          '';

          nixos-module =
            assert builtins.elem orca nixos.config.environment.systemPackages;
            pkgs.runCommand "orca-nixos-module" { } ''touch "$out"'';

          installed =
            pkgs.runCommand "orca-installed"
              {
                nativeBuildInputs = [
                  pkgs.pkg-config
                  pkgs.binutils
                ];
                buildInputs = orca.buildInputs;
              }
              ''
                set -euo pipefail
                export HOME="$TMPDIR"
                fail() {
                  echo "installed: $*" >&2
                  exit 1
                }

                reported=$(${orca}/bin/orca-cli --version)
                [ "$reported" = "orca-cli ${orca.version}" ] ||
                  fail "orca-cli --version printed '$reported'; expected 'orca-cli ${orca.version}' from build.zig.zon"

                [ -x ${orca}/bin/orca-gtk ] || fail "bin/orca-gtk is missing"
                [ -f ${orca}/include/orca/orca.h ] || fail "include/orca/orca.h is missing"
                [ -f ${orca}/lib/liborca.so.0 ] || fail "lib/liborca.so.0 is missing"
                soname=$(readelf -d ${orca}/lib/liborca.so.0 | sed -n 's/.*Library soname: \[\(.*\)\]/\1/p')
                [ "$soname" = liborca.so.0 ] || fail "lib/liborca.so.0 has SONAME '$soname'; expected liborca.so.0"

                export PKG_CONFIG_PATH="${orca}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
                pkg_version=$(pkg-config --modversion orca)
                [ "$pkg_version" = ${orca.version} ] || fail "orca.pc has version '$pkg_version'; expected ${orca.version}"
                pkg-config --cflags --libs --static orca >/dev/null || fail "orca.pc does not resolve"

                licenses=${orca}/share/doc/orca/licenses
                expected="alac/LICENSE chromaprint/LICENSE.md kissfft/BSD-3-Clause libxaac/LICENSE libxaac/NOTICE minimp3/LICENSE orca/LICENSE qoa/LICENSE"
                for file in $expected; do
                  [ -s "$licenses/$file" ] || fail "share/doc/orca/licenses/$file is missing or empty"
                done
                installed=$(cd "$licenses" && find . -type f | sed 's,^\./,,' | sort | tr '\n' ' ')
                [ "$installed" = "$expected " ] ||
                  fail "share/doc/orca/licenses holds '$installed'; expected '$expected'"

                touch "$out"
              '';
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_17
            pkgs.pkg-config
            pkgs.python3
            pkgs.ffmpeg-headless
            pkgs.sqlite-interactive.bin
            pkgs.wireplumber
          ];
          buildInputs = self.packages.${pkgs.stdenv.hostPlatform.system}.orca.buildInputs;
          shellHook = ''
            export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
