{ testers, nixosModules }:

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
  name = "Image module test";

  nodes.machine =
    {
      ...
    }:
    {
      imports = [
        testCompatibility
        nixosModules.image
      ];

      cyberus-linux.image = {
        enable = true;
        version = systemVersion;

        # Make this a bit larger so we don't make this test flaky.
        maxStoreSizeMiB = 4096;
      };
    };

  testScript =
    { nodes, ... }:
    ''
      import os
      import subprocess
      import tempfile

      tmp_disk_image = tempfile.NamedTemporaryFile()

      subprocess.run([
        "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img",
        "create",
        "-f",
        "qcow2",
        "-b",
        "${nodes.machine.system.build.image}/${nodes.machine.image.filePath}",
        "-F",
        "raw",
        tmp_disk_image.name,
      ])

      os.environ['NIX_DISK_IMAGE'] = tmp_disk_image.name

      with subtest("/etc/os-release contains the right version"):
        os_release = machine.succeed("cat /etc/os-release")
        t.assertIn('IMAGE_VERSION="${systemVersion}"', os_release)
    '';
}
