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
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.orca;
      defaultText = lib.literalExpression "orca.packages.\${pkgs.stdenv.hostPlatform.system}.orca";
      description = "The Orca package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
