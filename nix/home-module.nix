self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.orca;
in
{
  options.programs.orca = {
    enable = lib.mkEnableOption "Orca, a local-files-first music player";

    package = lib.mkOption {
      type = lib.types.package;
      default =
        if pkgs ? zig_0_17 then
          pkgs.callPackage ./package.nix { }
        else
          self.packages.${pkgs.stdenv.hostPlatform.system}.orca;
      defaultText = lib.literalExpression ''
        if pkgs ? zig_0_17 then
          pkgs.callPackage ./package.nix { }
        else
          orca.packages.''${pkgs.stdenv.hostPlatform.system}.orca
      '';
      description = ''
        The Orca package to install. The default is built against the
        system's nixpkgs when it provides `zig_0_17`, so the package uses the
        glibc that the GPU drivers expect, and against Orca's pinned nixpkgs
        otherwise.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
  };
}
