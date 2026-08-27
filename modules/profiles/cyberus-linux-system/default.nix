{ config, lib, ... }:

let
  cfg = config.cyberus-linux.profiles.cyberus-linux-system;

  # Makes an "enable" option that defaults to the `cyberus-linux-system.enable` state.
  mkDefaultEnable =
    description:
    (lib.mkEnableOption description)
    // {
      default = cfg.enable;
      defaultText = "config.cyberus-linux.profiles.cyberus-linux-system.enable";
    };
in
{
  options = {
    cyberus-linux.profiles.cyberus-linux-system = {
      enable = lib.mkEnableOption "the opinionated settings for an installed Cyberus Linux system";
      # NOTE: The following module logical settings are re-used in other modules.
      useFlakes = mkDefaultEnable "system-wide usage of Flakes";
      useCache = mkDefaultEnable "system-wide usage of the Cyberus Linux binary cache";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.useCache {
      nix = {
        settings = {
          extra-trusted-public-keys = [
            "ctrl-os:baPzGxj33zp/P+GAIJXsr8ss9Law+qEEFViX1+flbv8="
          ];

          extra-substituters = [
            "https://cache.cyberus-linux.com/"
          ];
        };
      };
    })
    (lib.mkIf cfg.useFlakes {
      nix = {
        settings = {
          # While some developers prefer not to use flakes for their
          # projects, it is convenient to have them enabled to
          # copy'n'paste documentation snippets.
          experimental-features = [
            "nix-command"
            "flakes"
          ];
        };
      };
    })
  ];
}
