# `callPackage`-compatible signature.
# Dependency injection from Nixpkgs
{
  testers,
  nixosModules,
}:

# Arguments for mkImageTest.
{
  name,
  additionalConfig ? { },
  additionalImagePrep ? "",
  testScript ? "",
}:

let
  systemVersion = "1.0.0";

  # Disable the VM boot shortcuts, because they interfere with booting the image.
  testCompatibility = { lib, ... }: {
    virtualisation.directBoot.enable = false;
    virtualisation.mountHostNixStore = false;
    virtualisation.useEFIBoot = true;
    virtualisation.fileSystems = lib.mkForce { };
  };
in
testers.nixosTest {
  inherit name;

  nodes.machine =
    {
      lib,
      modulesPath,
      ...
    }:
    {
      imports = [
        testCompatibility
        nixosModules.image

        "${modulesPath}/profiles/image-based-appliance.nix"
        additionalConfig

      ];

      cyberus-linux.image = {
        enable = true;
        version = lib.mkDefault systemVersion;

        # Make this a bit larger so we don't make this test flaky.
        nixStore.maxSizeMiB = 4096;
      };
    };

  testScript =
    { nodes, ... }:
    ''
      import os
      import subprocess
      import tempfile

      qemu_img_bin = "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img"
      tmp_disk_image = tempfile.NamedTemporaryFile()

      subprocess.run([
        qemu_img_bin,
        "create",
        "-f",
        "qcow2",
        "-b",
        "${nodes.machine.system.build.image}/${nodes.machine.image.filePath}",
        "-F",
        "raw",
        tmp_disk_image.name,
      ])

      ${additionalImagePrep}

      os.environ['NIX_DISK_IMAGE'] = tmp_disk_image.name

      machine.start(allow_reboot=True)
      machine.wait_for_unit("multi-user.target")

      ${testScript}
    '';
}
