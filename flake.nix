{
  description = "Orca: a local-files-first music library and player built on liborca";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      forAllSystems =
        f: lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (system: f nixpkgs.legacyPackages.${system});
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

          zig-fmt = pkgs.runCommand "orca-zig-fmt" { nativeBuildInputs = [ pkgs.zig ]; } ''
            export HOME="$TMPDIR"
            cd ${self}
            zig fmt --check liborca apps benchmarks tests build.zig
            touch "$out"
          '';
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          nixos-module =
            assert builtins.elem orca nixos.config.environment.systemPackages;
            pkgs.runCommand "orca-nixos-module" { } ''touch "$out"'';
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.zls
            pkgs.pkg-config
            pkgs.python3
            pkgs.ffmpeg-headless
            pkgs.sqlite-interactive.bin
          ]
          ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.wireplumber ];
          buildInputs = self.packages.${pkgs.stdenv.hostPlatform.system}.orca.buildInputs;
          shellHook = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
