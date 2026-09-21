{ self, inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        developer = pkgs.callPackage ./developer.nix { inherit (self) nixosModules; };
      }
      // inputs.nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux) (
        {
          modules = pkgs.callPackage ./modules.nix { inherit (self) nixosModules; };
        }
        // (import ./image.nix {
          inherit pkgs;
          inherit (self) nixosModules;
        })
      );
    };
}
