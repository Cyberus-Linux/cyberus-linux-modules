{
  description = "A collection of curated modules that work great with CTRL-OS (and NixOS)";

  # The inputs are only used for checks. We test this flake with
  # different Nixpkgs versions and with CTRL-OS in the CI.
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
          (inputs.nixpkgs.lib.versionAtLeast inputs.nixpkgs.lib.version
            (import ./lib { lib = { }; }).lockedNixpkgsVersion
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

          # CTRL-OS 24.05 doesn't have this package.
          formatter = pkgs.nixfmt-tree or null;
        };
    };
}
