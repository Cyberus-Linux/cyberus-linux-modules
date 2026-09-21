# This is an opinionated module that configures image-based systems.
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

  # We need roughly 0.8% for the verity partition. We use 1% to avoid
  # any unfortunate rounding effects.
  storeVeritySizeMiB = (cfg.userData.maxSizeMiB + 99) / 100;
in
{
  imports = [
    "${modulesPath}/image/repart.nix"
  ];

  options.cyberus-linux.image = {
    enable = lib.mkEnableOption "image-based deployment";

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

    loaderConf = lib.mkOption {
      description = ''
        The systemd-boot loader.conf configuration file.

        See [the systemd-boot documentation](https://www.freedesktop.org/software/systemd/man/latest/loader.conf.html)
        for the available options.
      '';

      internal = true;
      type = lib.types.str;
      default = "";
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

    systemPartition = {
      sizeMiB = lib.mkOption {
        description = ''
          The size of the UEFI System Partition (ESP) in MiB.

          Compared to a standard NixOS system, we do not need a lot of space. The system
          partition needs to be large enough to hold the boot loader (< 1 MiB) and the
          kernel and initrds for each installed version.
        '';
        type = lib.types.int;
        default = 512;
      };
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
        type = lib.types.ints.unsigned;
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

    updates = {
      slots = lib.mkOption {
        description = ''
          The number of slots for updates.

          Setting this to 2 creates the classical A/B update system, but more
          slots are possible. Setting this to 1 disables updates.

          Each slot consumes `cyberus-linux.image.nixStore.maxSizeMiB` MiB of
          storage plus around 1% for integrity checking information.
        '';
        type = lib.types.ints.unsigned;
        default = 2;
      };

      updateDirectory = lib.mkOption {
        description = ''
          A local directory from which updates will be applied.

          These updates have to be in a format that systemd-update understands. For now this means
          for each new version it expects three files:

          - A UKI: `kernel_<version>.efi`.
          - A Nix store image: `store_data_<uuid>_<version>`
          - A dm-verity partition of the Nix store: `store_verity_<uuid>_<version>`
        '';

        type = lib.types.path;
        default = "/var/updates";
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
        assertions = [
          {
            assertion = cfg.updates.slots > 0;
            message = "The number of update slots cannot be zero. If you want to disable updates, set them to 1.";
          }
        ];

        system.image.version = cfg.version;

        # We replace the boot loader.
        boot.loader.grub.enable = false;
        boot.loader.systemd-boot.enable = false;

        image.repart = {
          name = "image";
          split = true;

          # We use dm-verity to permanently bind the /nix/store
          # partition to the kernel. The verity hash is included in
          # the Linux kernel command line. We can never use the wrong
          # /nix/store.
          #
          # With Secure Boot, this verity hash is signed and we thus
          # have a complete chain of trust from the firmware to the
          # /nix/store partition.
          verityStore = {
            enable = true;
            ukiPath = "/EFI/Linux/kernel_${config.system.image.version}.efi";

            partitionIds = {
              store-verity = "25-1-store-verity-update";
              store = "26-1-store-update";
            };
          };

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
                SizeMinBytes = "${toString cfg.systemPartition.sizeMiB}M";
                SizeMaxBytes = "${toString cfg.systemPartition.sizeMiB}M";
                SplitName = "-";
              };
            };

            "${config.image.repart.verityStore.partitionIds.store-verity}" = {
              # The verity partition is configured by the
              # repart-verity-store module.

              repartConfig = {
                Type = "usr-verity";
                Label = "store_verity_${config.system.image.version}";
                VerityMatchKey = "store_data_${config.system.image.version}";
                ReadOnly = "yes";
                SplitName = "store_verity_%U";
                Minimize = "best";

                # Shrinks the verity partition to ~0.8% of the data
                # instead of ~7% with a small cost in performance.
                VerityDataBlockSizeBytes = 4096;
                VerityHashBlockSizeBytes = 4096;

                SizeMinBytes = "${toString storeVeritySizeMiB}M";
                SizeMaxBytes = "${toString storeVeritySizeMiB}M";

                # Stay at minimum size in the image.
                Weight = 0;
              };
            };

            "${config.image.repart.verityStore.partitionIds.store}" = {
              # Most of the root partition is configured by the
              # repart-verity-store module.
              repartConfig = {
                Type = "usr";
                Label = "store_data_${config.system.image.version}";

                Format = "squashfs";
                Compression = "zstd";

                VerityMatchKey = "store_data_${config.system.image.version}";
                ReadOnly = "yes";
                SplitName = "store_data_%U";

                SizeMinBytes = "${toString cfg.nixStore.maxSizeMiB}M";
                SizeMaxBytes = "${toString cfg.nixStore.maxSizeMiB}M";

                # Stay at minimum size in the image.
                Weight = 0;
              };
            };

            # The physical partition for user data needs to exist for the
            # system to be bootable.
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
        }
        // builtins.listToAttrs (
          lib.concatMap (updateSlot: [
            (lib.nameValuePair "25-${toString updateSlot}-store-verity-update" {
              Type = "usr-verity";
              Format = "empty";
              SizeMinBytes = "${toString storeVeritySizeMiB}M";
              SizeMaxBytes = "${toString storeVeritySizeMiB}M";
              SplitName = "-";
            })
            (lib.nameValuePair "26-${toString updateSlot}-store-update" {
              Type = "usr";
              Format = "empty";
              SizeMinBytes = "${toString cfg.nixStore.maxSizeMiB}M";
              SizeMaxBytes = "${toString cfg.nixStore.maxSizeMiB}M";
              SplitName = "-";
            })
          ]) (lib.range 1 cfg.updates.slots)
        );

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
              # We should be able to mount the ESP without the label, but the
              # by-designator links are not created early enough and we fail in
              # the update test with: Timed out waiting for device
              # /dev/disk/by-designator/esp.
              #
              # What's strange is that this only happens after an update.
              #
              # device = "/dev/disk/by-designator/esp";
              device = "/dev/disk/by-label/ESP";
              fsType = partConf.Format;
            };

          # We don't need a /usr mountpoint. Linux finds it via the verity hash.
        };

        # Ensure other services that touch the disk don't interfer.
        boot.initrd.systemd.services."systemd-repart" = {
          after = [
            # We don't want to modify dirty filesystems.
            "systemd-fsck@.service"
            "systemd-fsck-root.service"
          ];

          before = [
            "systemd-veritysetup@usr.service"
            "systemd-growfs@.service"
            "systemd-growfs-root.service"
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
            SplitName = "-";
          };
        };
      })

      (lib.mkIf (cfg.updates.slots > 1) {

        system.build.imageUpdateBundle =
          pkgs.runCommand "update-bundle"
            {
              nativeBuildInputs = [ pkgs.zstd ];
            }
            ''
              IMAGES_DIR="${config.system.build.image}"
              VERSION="${config.image.repart.version}"
              IMAGE_PREFIX="${config.image.repart.name}_$VERSION"

              # Compress the store and verity image, because they contain zero padding.
              # We don't need a high compression level, because the populated part is
              # already compressed or incompressible.

              mkdir -p $out
              install -m444 ${config.system.build.uki}/${config.system.boot.loader.ukiFile} $out/kernel_$VERSION.efi

              STORE_IMG=$(ls "$IMAGES_DIR/$IMAGE_PREFIX".store_data_*.raw)
              STORE_VERITY_IMG=$(ls "$IMAGES_DIR/$IMAGE_PREFIX".store_verity_*.raw)

              # We need the partition UUIDs in the file names, so systemd-sysupdate can
              # correctly restore them. This is important to match store and verity partitions
              # automatically when mounting, as the partition UUIDs are linked to the usrhash=
              # kernel parameter.

              zstd -1 -v "$STORE_IMG" \
                -o $out/$(echo "$STORE_IMG" | sed -E "s/.*image_(.*)\\.store_data_([0-9a-f]+).raw/store_data_\2_\1/").zstd

              zstd -1 -v "$STORE_VERITY_IMG" \
                -o $out/$(echo "$STORE_VERITY_IMG" | sed -E "s/.*image_(.*)\\.store_verity_([0-9a-f]+).raw/store_verity_\2_\1/").zstd
            '';

        systemd.sysupdate = {
          enable = true;

          reboot.enable = lib.mkDefault true;

          transfers = {
            "10-uki" = {
              Source = {
                MatchPattern = [
                  "kernel_@v.efi.zstd"
                  "kernel_@v.efi.xz"
                  "kernel_@v.efi"
                ];

                Path = cfg.updates.updateDirectory;
                Type = "regular-file";
              };
              Target = {
                InstancesMax = cfg.updates.slots;
                MatchPattern = [
                  "kernel_@v.efi"
                ];

                Mode = "0444";
                Path = "/EFI/Linux";
                PathRelativeTo = "boot";

                Type = "regular-file";
              };
              Transfer = {
                # Don't overwrite the current version.
                ProtectVersion = "%A";
              };
            };

            "26-1-store-update" = {
              Source = {
                MatchPattern = [
                  "store_data_@u_@v.zstd"
                  "store_data_@u_@v.xz"
                  "store_data_@u_@v"
                ];
                Path = cfg.updates.updateDirectory;
                Type = "regular-file";
              };

              Target = {
                InstancesMax = cfg.updates.slots;

                Path = "auto";
                MatchPattern = "store_data_@v";
                MatchPartitionType = "usr";

                Type = "partition";
                ReadOnly = "yes";
              };

              Transfer = {
                # Don't overwrite the current version.
                ProtectVersion = "%A";
              };
            };

            "25-1-store-verity-update" = {
              Source = {
                MatchPattern = [
                  "store_verity_@u_@v.zstd"
                  "store_verity_@u_@v.xz"
                  "store_verity_@u_@v"
                ];
                Path = cfg.updates.updateDirectory;
                Type = "regular-file";
              };

              Target = {
                InstancesMax = cfg.updates.slots;

                Path = "auto";
                MatchPattern = "store_verity_@v";
                MatchPartitionType = "usr-verity";

                Type = "partition";
                ReadOnly = "yes";
              };

              Transfer = {
                # Don't overwrite the current version.
                ProtectVersion = "%A";
              };
            };
          };
        };
      })
    ]
  );
}
