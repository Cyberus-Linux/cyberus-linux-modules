{ config, lib, ... }:

let
  cfg = config.cyberus-linux.profiles.developer;

  # Makes an "enable" option that defaults to the `developer.enable` state.
  mkDefaultEnable =
    description:
    (lib.mkEnableOption description)
    // {
      default = cfg.enable;
      defaultText = "config.cyberus-linux.profiles.developer.enable";
    };
in
{
  options = {
    cyberus-linux.profiles.developer = {
      enable = lib.mkEnableOption "the opinionated Cyberus Linux developer settings";
      useFlakes = mkDefaultEnable "system-wide usage of Flakes";
      useCache = mkDefaultEnable "system-wide usage of the Cyberus Linux binary cache";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.useCache {
      cyberus-linux.profiles.cyberus-linux-system.useCache = true;
    })
    (lib.mkIf cfg.useFlakes {
      cyberus-linux.profiles.cyberus-linux-system.useFlakes = true;
    })
  ];
}
