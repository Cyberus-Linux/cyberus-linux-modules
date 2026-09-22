{ withSystem, inputs, ... }:
{ }
//
  inputs.nixpkgs.lib.optionalAttrs
    (inputs.nixpkgs.lib.versionAtLeast inputs.nixpkgs.lib.version "25.11")
    {
      flake.overlays = rec {
        default = vms;
        vms =
          _: prev:
          withSystem prev.stdenv.hostPlatform.system (
            { config, ... }:
            {
              scl = config.packages.scl;
              OVMF-cloud-hypervisor = config.packages.OVMF-cloud-hypervisor;
              cyberus-linux-write-image = config.packages.cyberus-linux-write-image;
            }
          );
      };

      perSystem =
        { pkgs, ... }:
        {
          packages = import ./default.nix { inherit pkgs; };
        };
    }
