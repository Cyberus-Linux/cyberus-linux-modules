{ pkgs, nixosModules }:

let
  mkImageTest =
    args:
    pkgs.callPackage ./image-base.nix (
      {
        inherit nixosModules;
      }
      // args
    );

  # Simulate dd'ing the image to a larger block device.
  growImage = ''
    subprocess.run([
      qemu_img_bin,
      "resize",
      "-f",
      "qcow2",
      tmp_disk_image.name,
      "+32G"
    ])
  '';
in
rec {
  imageDefault = mkImageTest {
    name = "Image Test (defaults)";

    testScript = ''
      # Header plus one swap entry
      print(machine.execute('cat /proc/swaps'))
      machine.succeed('[ "$(wc -l < /proc/swaps)" -eq 2 ]')
    '';
  };

  imageWithoutSwap = mkImageTest {
    name = "Image Test (disabled swap)";

    additionalConfig = {
      cyberus-linux.image.swap.enable = false;
    };
    testScript = ''
      # Header without swap entries
      machine.succeed('[ "$(wc -l < /proc/swaps)" -eq 1 ]')
    '';
  };

  imageMinimal = mkImageTest {
    name = "Image Test (minimized)";

    additionalConfig = {
      cyberus-linux.image.inplaceBootable = false;
    };

    additionalImagePrep = growImage;

    testScript = ''
      # We manage to create a swap partition.
      machine.succeed('[ "$(wc -l < /proc/swaps)" -eq 2 ]')
    '';
  };

  imageMinimalBootDev = mkImageTest {
    name = "Image Test (minimized, rootdev known)";

    additionalConfig = {
      cyberus-linux.image.inplaceBootable = false;
      cyberus-linux.image.bootDevice = "/dev/vda";
    };

    additionalImagePrep = growImage;

    testScript = ''
      # We manage to create a swap partition.
      machine.succeed('[ "$(wc -l < /proc/swaps)" -eq 2 ]')
    '';
  };

  imageUpdates =
    let
      # Generate an update bundle. It would be nice to use extendModules
      # somehow...
      updateBundle =
        (mkImageTest {
          name = "New Version";

          additionalConfig = {
            cyberus-linux.image.version = "1.0.1";
          };
        }).nodes.machine.system.build.imageUpdateBundle;
    in
    mkImageTest {
      name = "Image Update Test";

      # See the TODO below.
      additionalConfig = {
        environment.etc.updates = {
          source = updateBundle;
        };
      };

      testScript = ''
        machine.succeed("mkdir -p /var/updates")

        # TODO The shared directory is not mounted, so we cannot use copy_from_host.
        machine.succeed("cp -v /etc/updates/* /var/updates/")

        current_version = machine.succeed("grep IMAGE_VERSION /etc/os-release")
        t.assertIn("1.0.0", current_version)

        updates = machine.succeed("updatectl check")
        assert "1.0.0 → 1.0.1" in updates

        machine.succeed("updatectl update")
        machine.reboot()

        current_version = machine.succeed("grep IMAGE_VERSION /etc/os-release")
        t.assertIn("1.0.1", current_version)
      '';
    };
}
