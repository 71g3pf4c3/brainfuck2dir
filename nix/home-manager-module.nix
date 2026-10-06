{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.b2d;
in
{
  options.programs.b2d = {
    enable = lib.mkEnableOption "b2d, the brainfuck-to-directory-tree materializer";

    package = lib.mkPackageOption pkgs "brainfuck2dir" { };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
  };
}
