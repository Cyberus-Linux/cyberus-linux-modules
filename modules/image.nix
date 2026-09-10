# This is an opinionated module that configures image-based systems.
#
# TODO The impurity checks in checks/modules.nix are currently disabled for this
# module for 26.05. 26.11 fixes the impurity of including the image/repart module.
{
  config,
  options,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.cyberus-linux.image;

  inherit (pkgs.stdenv.hostPlatform) efiArch;
in
{
  imports = [
    "${modulesPath}/image/repart.nix"
  ];

  options.cyberus-linux.image = {
    enable = lib.mkEnableOption "image-based deployment";

    inplaceBootableImage = lib.mkOption {
      description = ''
        Size the image to fit partitions that are created on first boot.

        This is useful to create a image that can boot as-is in a VM. Images
        that are intended to be written to a disk image or USB thumb drive do
        not need this option to be enabled.

        Disabling this option creates a smaller image.
      '';
      type = lib.types.bool;
      default = true;
    };

    bootDevice = lib.mkOption {
      description = ''
        The boot device name (if known).

        Setting a boot device creates smaller disk images.

        When the boot device is known, the initial disk image doesn't
        need to include the user data partition. It is instead created
        on first boot. This is a result of a technical limitation in
        `systemd-repart` and might be resolved eventually.
      '';

      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    espSizeMiB = lib.mkOption {
      description = "The size of the UEFI System Partition (ESP) in MiB";
      type = lib.types.int;
      default = 512;
    };

    # TODO The config is "<key> <value>" and we could make it harder
    # to mess this up by accepting an attrset.
    loaderConf = lib.mkOption {
      description = "The systemd-boot loader.conf configuration file";
      type = lib.types.str;
      default = ''
        timeout 5
      '';
    };

    version = lib.mkOption {
      description = ''
        Version of the image.

        Use a value according to the
        [UAPI Version Format Specification](https://uapi-group.org/specifications/specs/version_format_specification).
      '';
      type = lib.types.str;
      default = "0.0.0";
    };

    nixStore = {
      maxSizeMiB = lib.mkOption {
        description = ''
          The maximum size of the Nix store partition.

          This must be set manually, because it determines the size of future
          updates.
        '';

        type = lib.types.int;
      };
    };

    userData = {
      minSizeMiB = lib.mkOption {
        description = ''
          The minimum size of the user data (root) partition.

          Creating a tiny filesystem and inflating it later creates
          suboptimal filesystem structures. Use at least 1 GiB.
        '';
        type = lib.types.int;
        default = 1024;
      };

      maxSizeMiB = lib.mkOption {
        description = "The maximum size of the user data (root) partition";
        type = lib.types.int;
        default = 32 * 1024;
      };
    };

    swap = {
      enable = lib.mkEnableOption "add an encrypted swap partition" // {
        default = true;
      };

      sizeMiB = lib.mkOption {
        description = "The size of the swap partition";
        type = lib.types.int;
        default = 1024;
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # mkIf cannot be used to hide options that do not exist.
      (lib.optionalAttrs (options.image.repart ? enable) {
        image.repart.enable = true;
      })

      {
        system.image.version = cfg.version;

        # We replace the boot loader.
        boot.loader.grub.enable = false;
        boot.loader.systemd-boot.enable = false;

        image.repart = {
          name = config.boot.uki.name;

          # We use dm-verity to permanently bind the /nix/store
          # partition to the kernel. The verity hash is included in
          # the Linux kernel command line. We can never use the wrong
          # /nix/store.
          #
          # With Secure Boot, this verity hash is signed and we thus
          # have a complete chain of trust from the firmware to the
          # /nix/store partition.
          verityStore.enable = true;

          partitions =
            let
              includeUserData = cfg.bootDevice == null || cfg.inplaceBootableImage;
              includeSwap = cfg.swap.enable && cfg.inplaceBootableImage;
            in
            {
              "00-esp" = {
                contents = {
                  "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
                    "${config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

                  # The UKI is added by the repart-verity-store module.

                  # systemd-boot configuration
                  "/loader/loader.conf".source = pkgs.writeText "$out" cfg.loaderConf;
                };
                repartConfig = {
                  Type = "esp";
                  Format = "vfat";
                  SizeMinBytes = "${toString cfg.espSizeMiB}M";
                  SizeMaxBytes = "${toString cfg.espSizeMiB}M";
                  SplitName = "-";
                };
              };

              "10-store-verity" = {
                # The verity partition is configured by the
                # repart-verity-store module.

                repartConfig = {
                  Label = "store_verity_${config.system.image.version}";
                  VerityMatchKey = "store_${config.system.image.version}";
                  ReadOnly = "yes";
                  SplitName = "verity";
                  Minimize = "best";

                  # Shrinks the verity partition to ~0.8% of the data
                  # instead of ~7% with a small cost in performance.
                  VerityDataBlockSizeBytes = 4096;
                  VerityHashBlockSizeBytes = 4096;

                  # Stay at minimum size in the image.
                  Weight = 0;
                };
              };

              "20-store" = {
                # Most of the root partition is configured by the
                # repart-verity-store module.
                repartConfig = {
                  Label = "store_${config.system.image.version}";

                  Format = "squashfs";
                  Compression = "zstd";

                  VerityMatchKey = "store_${config.system.image.version}";
                  ReadOnly = "yes";
                  SplitName = "store";
                  Minimize = "best";

                  SizeMaxBytes = "${toString cfg.nixStore.maxSizeMiB}M";

                  # Stay at minimum size in the image.
                  Weight = 0;
                };
              };
            }
            // lib.optionalAttrs includeSwap {
              "30-swap".repartConfig = config.systemd.repart.partitions."30-swap";
            }
            // lib.optionalAttrs includeUserData {
              "40-user-data".repartConfig = config.systemd.repart.partitions."40-user-data" // {
                SplitName = "-";
                Weight = 0;
              };
            };
        };

        boot.initrd.systemd.repart = {
          enable = true;
          device = cfg.bootDevice;
        };

        # Resize /root to a better size.
        systemd.repart.partitions = {
          "40-user-data" = {
            Type = "root";
            Format = "ext4";

            SizeMinBytes = "${toString cfg.userData.minSizeMiB}M";
            SizeMaxBytes = "${toString cfg.userData.maxSizeMiB}M";

            Label = "root";
          };
        };

        boot.initrd.systemd.services.systemd-repart = {
          path = [
            # For mkswap.
            #
            # systemd-repart needs this to format the swap partition on
            # first boot.
            pkgs.util-linux

            # For creating the ext4 root partition.
            pkgs.e2fsprogs
          ];
        };

        fileSystems = {
          "/" =
            let
              partConf = config.systemd.repart.partitions."40-user-data";
            in
            {
              device = "/dev/disk/by-label/${partConf.Label}";
              fsType = partConf.Format;
            };

          "/boot" =
            let
              partConf = config.image.repart.partitions."00-esp".repartConfig;
            in
            {
              device = "/dev/disk/by-designator/esp";
              fsType = partConf.Format;
            };

          # We don't need a /usr mountpoint. Linux finds it via the verity
          # hash.
        };

        # Ensure other services that touch the disk don't interfer.
        boot.initrd.systemd.services."systemd-repart" = {
          after = [
            # We don't want to modify dirty filesystems.
            "systemd-fsck@.service"
          ];

          before = [
            "systemd-veritysetup@usr.service"
          ];
        };
      }

      (lib.mkIf cfg.swap.enable {
        swapDevices = [
          {
            device = "/dev/disk/by-designator/swap";
            randomEncryption.enable = true;
          }
        ];

        systemd.repart.partitions = {
          "30-swap" = {
            Type = "swap";
            SizeMinBytes = "${toString cfg.swap.sizeMiB}M";
            SizeMaxBytes = "${toString cfg.swap.sizeMiB}M";
          };
        };
      })
    ]
  );
}
