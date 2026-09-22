# This module writes an image to a disk after boot.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cyberus-linux.deploy-image;
in
{
  options.cyberus-linux.deploy-image = {
    enable = lib.mkEnableOption ''
      automatically deploying an image-based system.

      When enabled, after boot-up the image specified in `cyberus-linux.deploy-image.sourceImage` will be written to
      `cyberus-linux.deploy-image.targetDevice`.
    '';

    quiet = lib.mkEnableOption "booting without visual clutter" // {
      default = true;
    };

    sourceImage = lib.mkOption {
      description = ''
        The raw disk image file to deploy.

        This must be an uncompressed raw disk image. The ideal disk image is generated via `cyberus-linux.image.*`.
      '';
      type = lib.types.path;
    };

    targetDevice = lib.mkOption {
      description = ''
        The block device to deploy the image to.

        The must be a device node covering a whole block device, not a single partition. Typically,
        this can be /dev/nvme0n1 (for the first NVMe disk) or /dev/sda for the first SATA disk.

        **DATA ON THIS DEVICE WILL BE IRRETRIEVABLY DELETED ON BOOT.**
      '';
      type = lib.types.path;
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        systemd.services.write-image = {
          description = "Write image to disk";
          wantedBy = [ "multi-user.target" ];
          conflicts = [ "autovt@tty1.service" ];

          serviceConfig = {
            ExecStart = "${pkgs.cyberus-linux-write-image}/bin/write-image ${cfg.sourceImage} ${cfg.targetDevice}";
            StandardInput = "tty";
            StandardOutput = "tty";
            TTYPath = "/dev/tty1";
            TTYReset = true;
            TTYVHangup = true;
            TTYVTDisallocate = true;
            Type = "simple";
            Restart = "no";

            # The write-image tool will just exit and assume that triggers a poweroff event.
            SuccessAction = "poweroff-force";
          };
        };
      }

      (lib.mkIf cfg.quiet {
        boot.consoleLogLevel = lib.mkDefault 3;
        boot.initrd.verbose = lib.mkDefault false;

        boot.kernelParams = [
          "quiet"
          "systemd.show_status=auto"
        ];
      })
    ]
  );
}
