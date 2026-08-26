{ config, lib, ... }:

let
  cfg = config.ctrl-os.profiles.ctrl-os-system;

  # Makes an "enable" option that defaults to the `ctrl-os-system.enable` state.
  mkDefaultEnable =
    description:
    (lib.mkEnableOption description)
    // {
      default = cfg.enable;
      defaultText = "config.ctrl-os.profiles.ctrl-os-system.enable";
    };
in
{
  options = {
    ctrl-os.profiles.ctrl-os-system = {
      enable = lib.mkEnableOption "the opinionated settings for an installed CTRL-OS system";
      # NOTE: The following module logical settings are re-used in other modules.
      useFlakes = mkDefaultEnable "system-wide usage of Flakes";
      useCache = mkDefaultEnable "system-wide usage of the CTRL-OS binary cache";
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
