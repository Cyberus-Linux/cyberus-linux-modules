{ self, inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        developer = pkgs.callPackage ./developer.nix { inherit (self) nixosModules; };
      }
      // inputs.nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux) {
        modules = pkgs.callPackage ./modules.nix { inherit (self) nixosModules; };
        image = pkgs.callPackage ./image.nix { inherit (self) nixosModules; };
      };
    };
}
