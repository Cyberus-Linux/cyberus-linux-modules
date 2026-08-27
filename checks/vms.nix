{
  fetchurl,
  formats,
  lib,
  nixosModules,
  openssh,
  qemu-utils,
  runCommand,
  sshpass,
  testers,
}:
let
  # The image must be a raw image.
  image = fetchurl {
    # Cloud images, while they get removed from the `/$release/$date/` directory on `cloud-image`,
    # are available under `/releases/$release/release-$date/` on `cloud-images-archive`.
    url = "http://cloud-images-archive.ubuntu.com/releases/noble/release-20260225/ubuntu-24.04-server-cloudimg-amd64.img";
    sha256 = "sha256-eqbZ9eijpVx0RbE40xpz0Rh4cSEbK32p2i4abL8WmyE=";
  };
  imageRaw = runCommand "convert-RAW" { } ''
    ${lib.getExe' qemu-utils "qemu-img"} convert -O raw ${image} $out
  '';
  # The IP to access the virtual machine from the host
  externalIP = "192.168.10.2";
  # The IP of the virtual machine in the internal network
  vmIP = "192.168.91.3";
  # The IP of the gateway in the VM network, allowing outside world access
  gatewayIP = "192.168.91.1";
in
testers.nixosTest {
  name = "vms";
  meta.platforms = [
    "x86_64-linux"
  ];
  nodes.default = {
    environment.systemPackages = [
      sshpass
      openssh
    ];
    imports = [
      nixosModules.vms
    ];
    virtualisation.cores = 4;
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 16384;
    networking.hostId = "cafecafe";
    cyberus-linux.vms = {
      gatewayInterface = "eth0";
      networks = {
        test = {
          # The IP to access the virtual machine from the host
          inherit externalIP;
          # The IP of the gateway in the VM network, allowing outside world access
          inherit gatewayIP;
          # The netmask of the internal network
          internalNetmask = "255.255.255.0";
          # Port forwarding from host network to internal network host ip
          allowedTCPPorts = [ "2222:${vmIP}:22" ];
        };
        default = null;
      };
      virtualMachines = {
        testmachine = {
          image = imageRaw;
          imageSize = 4096;
          cores = 1;
          memorySize = 2048;
          autoStart = true;
          network = "test";
          # The cloud init user configuration file to attach to the Virtual Machine
          cloudInitUserConfigFile = (formats.yaml { }).generate "cloud-init-user-config.yaml" {
            system_info.default_user.name = "nixos";
            password = "nixos";
            chpasswd.expire = false;
            ssh_pwauth = true;
          };
          # The cloud init network configuration to attach to the Virtual Machine
          cloudInitNetworkConfigFile = (formats.yaml { }).generate "cloud-init-network-config.yaml" {
            version = 2;
            ethernets.id0 = {
              match = {
                name = "enp*";
              };
              addresses = [
                "${vmIP}/24"
              ];
              gateway4 = "${gatewayIP}";
            };
          };
        };
      };
    };
  };

  testScript = ''
    start_all()
    default.wait_for_unit("scl.target")
    with subtest("scl is accessible"):
      default.succeed("sclctl sc list")
    with subtest("vm is started"):
     default.wait_for_unit("vm-testmachine.service")
    with subtest("vm is accessible"):
      default.wait_until_succeeds("${sshpass}/bin/sshpass -p 'nixos' ssh -o StrictHostKeyChecking=no  -p 2222 nixos@${externalIP} whoami")
  '';
}
