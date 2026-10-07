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
              cysb = config.packages.cysb;
            }
          );
      };

      perSystem =
        { pkgs, ... }:
        {
          packages = import ./default.nix { inherit pkgs; };
        };
    }
