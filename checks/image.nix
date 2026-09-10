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
{
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
      cyberus-linux.image.inplaceBootableImage = false;
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
      cyberus-linux.image.inplaceBootableImage = false;
      cyberus-linux.image.bootDevice = "/dev/vda";
    };

    additionalImagePrep = growImage;

    testScript = ''
      # We manage to create a swap partition.
      machine.succeed('[ "$(wc -l < /proc/swaps)" -eq 2 ]')
    '';
  };
}
