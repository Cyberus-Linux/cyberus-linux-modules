{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  cfg = config.cyberus-linux.hardware.devices.nvidia-jetson-orin-nano-super;
in
{
  options = {
    cyberus-linux.hardware.devices.nvidia-jetson-orin-nano-super = {
      enableOotModules = lib.mkEnableOption "the NVIDIA Out-Of-Tree kernel modules" // {
        default = true;
      };
      enableStage1KernelModules =
        lib.mkEnableOption "use of storage and necessary kernel modules in stage-1"
        // {
          default = true;
        };
      # Reminder device enablement modules should not set the unfree software option.
      # The module *must* fail with the unfree software error.
      # The user must make the informed decision about enabling unfree software.
      enableHardwareAcceleration = lib.mkEnableOption "the NVIDIA proprietary graphical and ML drivers";
      quirks = {
        # Enabled by default since it's cheap.
        addDebugUserGroup =
          lib.mkEnableOption "adding the `debug` user group, which is used in vendor udev configuration"
          // {
            default = true;
          };
        debugModuleLoading =
          lib.mkEnableOption "send debug information to the kernel log when loading the kernel module."
          // {
            internal = true;
          };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = pkgs.linuxKernel.override.__functionArgs ? kernelPackagesExtensions;
            message = "The `kernelPackagesExtensions` feature was not detected on the `linuxKernel` attribute. Your Nixpkgs version may be too old.";
          }
        ];
      }
      {
        nixpkgs.hostPlatform = "aarch64-linux";

        # We can add the proprietary packages to the overlay even without enabling the
        # *configuration* for proprietary packages. This leaves it up to the end-user
        # to use those proprietary packages.
        nixpkgs.overlays = [
          (final: super: {
            kernelPackagesExtensions = (super.kernelPackagesExtensions or [ ]) ++ [
              (kFinal: _kSuper: {
                nvidia-oot = kFinal.callPackage ./nvidia-oot { };
              })
            ];
            nvidia-jetson-orin-nano-super = {
              nvidia-l4t = final.callPackage ./nvidia-l4t { };
              nvidia-l4t-firmware = final.callPackage ./nvidia-l4t-firmware {
                inherit (final.nvidia-jetson-orin-nano-super)
                  nvidia-l4t
                  ;
              };
              nvidia-l4t-kernelPackages = final.linuxPackagesFor final.nvidia-jetson-orin-nano-super.nvidia-l4t-kernel;
              nvidia-l4t-kernel = final.callPackage ./nvidia-l4t-kernel {
                kernelPatches = [
                  final.linuxKernel.kernelPatches.bridge_stp_helper
                  final.linuxKernel.kernelPatches.request_key_helper
                ];
              };
            };
          })
        ];
      }

      (lib.mkIf cfg.enableStage1KernelModules {
        boot.initrd.availableKernelModules = [
          # Enable PCIe support at boot time
          "phy_tegra194_p2u"
          "pcie_tegra194"
          # Enable USB support for USB Boot
          "xhci-tegra"
          "phy-tegra-xusb"
        ];
      })

      {
        boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_6_12;
      }

      (lib.mkIf cfg.enableOotModules {
        boot.extraModulePackages = [
          config.boot.kernelPackages.nvidia-oot
        ];
      })

      (lib.mkIf cfg.quirks.addDebugUserGroup {
        users.groups = {
          # Works around these warnings in system logs:
          #     /etc/udev/rules.d/99-tegra-devices.rules:00 Unknown group 'debug', ignoring.
          debug = { };
        };
      })

      (lib.mkIf (cfg.enableHardwareAcceleration) {
        # This service handles the weakly defined dependencies for the NVIDIA
        # driver stack.
        #  - simpledrm must not hold the device
        #  - tegra-drm must be loaded before nvidia-drm
        #  - nvidia-drm is loaded last
        # For better support of wayland compositors, this uses a trick to
        # force the nvidia-drm driver to pick the `card0` name (from the
        # assigned minor device number).
        # This workaround will not work when “SOC Display Hand-Off” is
        # disabled, or if running on a kernel with simpledrm disabled.
        systemd.services.nvidia-load-modules = {
          wantedBy = [ "graphical.target" ];
          before = [
            "graphical.target"
            "display-manager.service"
          ];
          after = [
            "multi-user.target"
            "systemd-modules-load.service"
          ];
          path = with pkgs; [
            kmod
            coreutils
          ];
          script = ''
            (
            set -eu -o pipefail
            printf 'Loading nvidia-drm kernel module...\n\n'
            (
            # This path allows manually unbinding the simpledrm driver from the framebuffer.
            # The vendor driver does not know how to do that.
            unbind_path='/sys/bus/platform/devices/chosen:framebuffer/driver/unbind'

            simpledrm_card="/dev/dri/by-path/platform-chosen:framebuffer-card"
            tegra_card="dev/dri/by-path/platform-13e00000.host1x-card"
            nvidia_card="dev/dri/by-path/platform-13800000.display-card"

            printf "Checking nvidia-drm can take card0...\n"
            if ! test -e "$unbind_path"; then
              printf "WARNING: The nvidia-drm driver will be on '/dev/dri/card1'.\n"
              printf "This may break some wayland compositors or other DRM software.\n"
            fi

            printf "Checking if the module can be loaded...\n"
            if ! modprobe --first-time --dry-run nvidia-drm; then
              printf "Skipping loading nvidia-drm kernel module.\n" >&2
              # This is not a failure for this unit.
              # The module might be loaded.
              exit 0
            fi

            ${lib.optionalString cfg.quirks.debugModuleLoading "set -x"}

            # Load the tegra-drm driver.
            # If simpledrm is loaded, this will effectively use /dev/dri/card1.
            modprobe tegra-drm

            i=30
            # Wait a bit until the card shows up.
            until test -e "$tegra_card"; do
              sleep 0.1
              ((i--)) || break
            done

            # The vendor driver stack is fussy, wait a bit more.
            sleep 1

            # Make the simpledrm driver drop the card0 identifier, if relevant.
            if test -e "$unbind_path"; then
              printf 'chosen:framebuffer' > "$unbind_path"
              i=30
              # Wait until (effectively) card0 is free.
              while test -e ; do
                sleep 0.1
                ((i--)) || break
              done
            fi

            # The vendor driver stack is fussy, wait just a bit more again.
            sleep 1

            # Then load the driver actual driver.
            modprobe nvidia-drm
            )

            printf '... done loading nvidia-drm kernel module.\n'
            ) ${lib.optionalString cfg.quirks.debugModuleLoading ">/dev/kmsg 2>&1"}
          '';
          serviceConfig = {
            # > systemd will consider [oneshot units] to be in the state "starting"
            # > until the program has terminated, so ordered dependencies will
            # > wait for the program to finish before starting themselves
            Type = "oneshot";
            # Never restart this unit.
            Restart = "no";
          };
        };

        services.udev.packages = [
          pkgs.nvidia-jetson-orin-nano-super.nvidia-l4t
        ];
        hardware = {
          firmware = lib.mkAfter [
            pkgs.nvidia-jetson-orin-nano-super.nvidia-l4t-firmware
          ];
          # Backward compatibility to evaluate against 24.05
          "${if options.hardware ? graphics then "graphics" else "opengl"}" = {
            enable = true;
            extraPackages = [
              pkgs.nvidia-jetson-orin-nano-super.nvidia-l4t
            ];
          };
        };
        environment.etc = {
          "egl/egl_external_platform.d".source = "/run/opengl-driver/share/egl/egl_external_platform.d/";
          "glvnd/egl_vendor.d".source = "/run/opengl-driver/share/glvnd/egl_vendor.d";
        };
        boot.blacklistedKernelModules = [
          # The tegra_drm and nvidia_drm modules need to be loaded in order.
          # Prevent the usual modules loading mechanisms from trying and failing.
          # See 70-nvidia-unbind-simpledrm.rules for how this gets loaded.
          "tegra_drm"
          "nvidia_drm"
          # Vendor prevents this module from being loaded by default.
          # The reason why is not explained.
          "snd_soc_tegra_audio_graph_card"
        ];
        boot.extraModprobeConfig = lib.mkMerge [
          # Without `modeset`, the X11 driver will fail to work.
          # This is the vendor-suggested configuration.
          "options nvidia_drm modeset=1 fbdev=1"
        ];
        services.xserver = {
          # Use the `nvidia` driver for `tegra` kernel driver matches.
          config = ''
            Section "OutputClass"
              Identifier "nvidia"
              MatchDriver "tegra"
              Driver "nvidia"
            EndSection
          '';
          # NOTE: videoDrivers cannot be used.
          # Enabling `"nvidia"` within it uses the non-l4t NVIDIA driver.
          # Instead we force the driver list to ensure only this one is used.
          drivers = lib.mkForce (
            lib.singleton {
              name = "nvidia";
              modules = [ pkgs.nvidia-jetson-orin-nano-super.nvidia-l4t ];
              display = true;
              deviceSection = ''
                Option "AllowEmptyInitialConfiguration" "true"
              '';
            }
          );
        };
      })
    ]
  );
}
