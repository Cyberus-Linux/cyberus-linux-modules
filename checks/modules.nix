{
  pkgs,
  nixosModules,
}:

let
  inherit (pkgs) lib;
  # `system.build.image` is unconditionally set in older releases.
  # See: https://github.com/NixOS/nixpkgs/pull/561557
  # Skip `system.build` only when the `enable` option is not found.
  skipBuildRepart =
    !(
      (pkgs.nixos (
        { modulesPath, ... }:
        {
          imports = [ "${modulesPath}/image/repart.nix" ];
        }
      )).options.image.repart or { } ? enable
    );
  check = import ../lib/check-modules-no-ops.nix {
    inherit pkgs;
    modules = nixosModules;
    ignoreChangesIn = {
      image = lib.optionals skipBuildRepart [
        [
          "system"
          "build"
        ]
      ];
    };
  };
in
builtins.seq check.result (
  (pkgs.writeText "modules-check" (builtins.toJSON check.result)) // { inherit check; }
)
