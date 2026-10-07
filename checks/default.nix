{ self, inputs, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    {
      checks = {
        developer = pkgs.callPackage ./developer.nix { inherit (self) nixosModules; };
      }
      // inputs.nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux) (
        {
          modules = pkgs.callPackage ./modules.nix { inherit (self) nixosModules; };
        }
        // (import ./image.nix {
          inherit pkgs lib;
          inherit (self) nixosModules;
          inherit (self') packages;
        })
      );
    };
}
