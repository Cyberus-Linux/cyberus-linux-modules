{
  description = "A collection of curated modules that work great with Cyberus Linux (and NixOS)";

  # The inputs are only used for checks. We test this flake with
  # different Nixpkgs versions and with Cyberus Linux in the CI.
  inputs = {
    nixpkgs.url = "https://channels.cyberus-linux.com/channel/cyberus-linux-26.05.tar.xz";
    preCommitHooksNix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-linux"
        "x86_64-linux"
        "aarch64-darwin"
      ];
      imports = [
        ./checks
        ./packages/flakeModule.nix
      ]
      ++
        # Only run the `pre-commit` checks when ran using the locked Nixpkgs.
        # This ensures our CI isn't running those checks when we override the Nixpkgs input.
        inputs.nixpkgs.lib.optionals
          (
            let
              inherit (import ./lib { inherit (inputs.nixpkgs) lib; })
                getFlakeInput
                ;
            in
            (getFlakeInput "nixpkgs").locked.narHash == inputs.nixpkgs.sourceInfo.narHash
          )
          [
            inputs.preCommitHooksNix.flakeModule
            ./checks/pre-commit.nix
          ];

      flake.nixosModules = import ./modules;

      perSystem =
        {
          pkgs,
          self',
          system,
          ...
        }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays =
              [ ]
              ++
                inputs.nixpkgs.lib.optionals (inputs.nixpkgs.lib.versionAtLeast inputs.nixpkgs.lib.version "25.11")
                  [
                    (_: _: {
                      scl = self'.packages.scl;
                      OVMF-cloud-hypervisor = self'.packages.OVMF-cloud-hypervisor;
                    })
                  ];
          };

          formatter = pkgs.nixfmt-tree;
        };
    };
}
