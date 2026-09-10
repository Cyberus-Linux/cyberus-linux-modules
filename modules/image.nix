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

  # Integer division rounding up.
  ceil = a: b: (a + b - 1) / b;

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

    espSizeMiB = lib.mkOption {
      description = "The size of the UEFI System Partition (ESP) in MiB";
      type = lib.types.int;
      default = 512;
    };

    maxStoreSizeMiB = lib.mkOption {
      description = ''
        The maximum size of the Nix store partition.

        This must be set manually, because it determines the size of future
        updates.
      '';

      type = lib.types.int;
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
      default = 0;
    };

    swap = {
      enable = lib.mkEnableOption "add an encrypted swap partition" // {
        default = true;
      };

      enableCompression = lib.mkEnableOption "enable compression by default" // {
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

          # Not useful yet, but it will be for update packages.
          # split = true;

          verityStore.enable = true;

          partitions = {
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

              repartConfig =
                let
                  # Repart should be smart enough to figure out the
                  # correct size by itself, but it doesn't work if we
                  # specify an image size and the verity partition ends
                  # up gigantic.
                  #
                  # So instead do a back-of-the-envelope calculation.
                  sizeMiB =
                    1 # percent
                    * (ceil cfg.maxStoreSizeMiB 100);
                in
                {
                  Label = "store_verity_${config.system.image.version}";
                  VerityMatchKey = "store_${config.system.image.version}";
                  SplitName = "verity";
                  Minimize = "off";

                  SizeMinBytes = "${toString sizeMiB}M";
                  SizeMaxBytes = "${toString sizeMiB}M";

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
                VerityMatchKey = "store_${config.system.image.version}";
                ReadOnly = "yes";
                SplitName = "store";
                Minimize = "off";

                # TODO The 26.05 kernel only enables zip compression
                # for erofs. But repart it needs the zip tool in PATH.
                # Compression = "zip";

                SizeMinBytes = "${toString cfg.maxStoreSizeMiB}M";
                SizeMaxBytes = "${toString cfg.maxStoreSizeMiB}M";

                # Stay at minimum size in the image.
                Weight = 0;
              };
            };

            # TODO Only add a root partition if we don't know the target device.
            # TODO Fix the repart module to support Format = "empty"
            "40-root".repartConfig = {
              Type = "root";
              Format = "ext4";

              # Creating a tiny ext4 and inflating it later creates
              # suboptimal filesystem structures. Go a bit larger to
              # avoid this.
              #
              # We could create a 64MB ext4 image here, but this will
              # create a small journal that is a potential performance
              # bottleneck. The journal size is also not adjusted when
              # the file system is grown, but needs to be manually
              # changed with tune2fs.
              SizeMinBytes = "1G";
              SizeMaxBytes = "1G";

              SplitName = "root";
              Label = "root";
            }
            // lib.optionalAttrs cfg.inplaceBootableImage {
              PaddingMinBytes =
                let
                  swapSizeMiB = if cfg.swap.enable then cfg.swap.sizeMiB else 0;
                  rootSizeMiB = 8192 - 1024;
                  slackMiB = 64;
                in
                "${toString (swapSizeMiB + rootSizeMiB + slackMiB)}M";
            };
          };
        };

        boot.initrd.systemd.repart = {
          enable = true;

          # The root partition only be dynamically created, because we
          # would need to know the device name.
          #device = "/dev/sda";
        };

        # Resize /root to a better size.
        systemd.repart.partitions = {
          "40-root" = {
            Type = "root";
            Format = "ext4";

            SizeMinBytes = "1G";
            SizeMaxBytes = "8G";

            SplitName = "root";
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
              partConf = config.systemd.repart.partitions."40-root";
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
        zramSwap = lib.mkIf cfg.swap.enableCompression {
          enable = lib.mkDefault true;
          algorithm = lib.mkIf (lib.versionOlder "5.7" config.boot.kernelPackages.kernel.version) (
            lib.mkDefault "zstd"
          );
        };

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
