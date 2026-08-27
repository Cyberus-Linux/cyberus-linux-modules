{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let

  vmNetworkOptions =
    { ... }:
    {
      options = {
        externalIP = mkOption {
          description = ''
            The external IPv4 address from which the virtual machine network is accessible on the host.
          '';
          default = "192.168.10.2";
          type = types.nonEmptyStr;
        };

        gatewayIP = mkOption {
          description = ''
            The Gateway IPv4 address, from which the virtual machines are able to connect to the internet
          '';
          type = types.nonEmptyStr;
          default = "192.168.20.1";
        };

        internalNetmask = mkOption {
          description = ''
            The IPv4 Subnet mask of the network inside the network namespace.
            e.G
            255.255.255.0 for /24 networks
            255.255.255.255 for /32
            255.255.0.0 for /16
            255.0.0.0 for /8
          '';
          default = "255.255.255.0";
          type = types.nonEmptyStr;
        };

        allowedTCPPorts = mkOption {
          description = ''
            List of TCP ports that should be forwarded from the vms internal ip address to the external ip address.

            Valid format:
            <externalPort>:<vmIp>:<vmPort>

            Note, that the VM ip must be different from the gateway IP address to avoid IP address clashes inside the network namespace.
            The external facing port is directly assigned to the external IP and vm hostname, thus port re using on the host is possible.
          '';
          example = [ "2222:192.168.20.2:22" ];
          default = [ ];
          type = with types; listOf str;
        };

        allowedUDPPorts = mkOption {
          description = ''
            List of UDP ports that should be forwarded from the vms internal ip address to the external ip address.

            Valid format:
            <externalPort>:<vmIp>:<vmPort>

            Note, that the VM ip must be different from the gateway IP address to avoid IP address clashes inside the network namespace.
            The external facing port is directly assigned to the external IP and vm hostname, thus port re using on the host is possible.
          '';
          example = [ "5353:192.168.20.2:53" ];
          default = [ ];
          type = with types; listOf str;
        };
      };
    };

  vmOptions =
    { ... }:
    {
      options = {
        image = mkOption {
          type = types.path;
          description = ''
            The virtual machine image to run.
            At the moment, only a raw image format is supported.

            The image could be converted via
            qemu-img convert -f <source-image-format> -O raw <image> <image-converted-to-raw>
          '';
        };

        imageSize = mkOption {
          type = types.ints.positive;
          description = ''
            The size of the virtual machine image at runtime in MiB.
            The virtual machine control plane prepares statically sized images.
            Thus a static image size must be specified before the first run.
            A change of the VM image size at a later point results in a complete clean image afterwards.
            The older images are not deleted at a change.
            To show the virtual machine images run
            sclctl volume list
          '';
        };

        cores = mkOption {
          default = config.virtualisation.cores;
          defaultText = "config.virtualisation.cores";
          type = types.ints.positive;
          description = ''
            Specify the number of cores the virtual machine is permitted to use.
            The number cannot be higher than `cyberus-linux.vms.maxCores`
          '';
        };

        memorySize = mkOption {
          default = config.virtualisation.memorySize;
          defaultText = "config.virtualisation.memorySize";
          type = types.ints.positive;
          description = ''
            The memory size in megabytes the vm is permitted to use.
            The number must not be higher than `cyberus-linux.vms.maxMemory
          '';
        };

        network = mkOption {
          default = "default";
          type = with types; str;
          description = ''
            The virtual machine network, the virtual machine is attached to.
            The virtual machine network must be defined beforehand, or the default network must be used.
          '';
        };

        cloudInitUserConfigFile = mkOption {
          default = null;
          type = with types; nullOr path;
          description = ''
            Path to a cloud configuration YAML file.
            Specifying cloud configuration is optional and only supported for
            cloud ready operating system images.
            For a detailed list of configuration options refer to
            https://cloudinit.readthedocs.io/en/latest/reference/modules.html
          '';

          example = ''
            pkgs.writeScript "cloud-config.yaml" "
                        # cloud-config
                        system_info:
                          default_user:
                            name: nixos
                        password: nixos
                        chpasswd:
                          expire: false # not recommended for production use
                        ssh_pwauth: false # not recommended for production use
                      "
          '';
        };

        cloudInitNetworkConfigFile = mkOption {
          default = null;
          type = with types; nullOr path;
          description = ''
            Path to a network cloud configuration YAML file.
            Specifying cloud configuration is optional and only supported for
            cloud ready operating system images.
            For a detailed list of configuration options, refer to
            https://cloudinit.readthedocs.io/en/latest/reference/network-config.html
          '';
          example = ''
            pkgs.writeScript "cloud-network-config.yaml" "
                        # cloud-config
                        version: 2
                        ethernets:
                          id0:
                            match:
                              name: "enp*"
                            addresses:
                              - 192.168.20.2/24
                            gateway4: 192.168.20.1
                            nameservers:
                              addresses: [ 1.1.1.1 8.8.8.8 ]
                        "
          '';
        };

        autoStart = mkOption {
          type = types.bool;
          default = true;
          description = ''
            When enable, the virtual machine is automatically started on boot.
            If this option is set to false, the virtual machine has to be started on-demand via its service.
          '';
        };
      };
    };

  cfg = config.cyberus-linux.vms;

  mkVMService =
    name: options:
    let
      serviceName = "scl-${lib.toLower options.network}";
      vmName = lib.toLower name;
    in
    {
      name = "vm-${vmName}";
      value = {
        enable = true;
        wantedBy = lib.optional (options.autoStart) "scl.target";
        requires = [
          "scl.target"
          "vm-network-${lib.toLower options.network}.service"
        ];
        after = [
          "scl.target"
          "vm-network-${lib.toLower options.network}.service"
        ];
        path = with pkgs; [
          config.programs.sclctl.package
          jq
        ];
        preStart = ''
          while ! sclctl sc show ${serviceName}; do
            echo "waiting for sc"
            sleep 1
          done
        '';
        script = ''
          IMAGE_NAME="${vmName}-$(sha1sum ${options.image} | cut -d ' ' -f1)"
          if ! sclctl volume show ${serviceName} $IMAGE_NAME; then
            cp ${options.image} ${config.services.scl-singlenode.imageRegistry.dataDir}/$IMAGE_NAME.img
            sclctl volume create --size ${toString options.imageSize} --url http://localhost:${toString config.services.scl-singlenode.imageRegistry.listenPort}/$IMAGE_NAME.img ${serviceName} $IMAGE_NAME
            while [ "$(sclctl volume show ${serviceName} $IMAGE_NAME | jq -r ".status")" != "active" ]; do sleep 1; done
            rm ${config.services.scl-singlenode.imageRegistry.dataDir}/$IMAGE_NAME.img
          fi
          while sclctl vm show ${serviceName} ${vmName}; do
            sclctl vm update ${serviceName} ${vmName} stopped  || true
            sclctl vm delete ${serviceName} ${vmName} || true
            sleep 1
          done

          sclctl vm create ${serviceName} ${vmName} \
            --vcpu ${toString (options.cores)} \
            --ram ${toString (options.memorySize)} \
            --boot-volume name=$IMAGE_NAME  \
            --network-device-name tap${vmName} \
            ${lib.optionalString (
              options.cloudInitUserConfigFile != null
            ) "--cloud-init-user-data ${options.cloudInitUserConfigFile} \\"}
            ${lib.optionalString (
              options.cloudInitNetworkConfigFile != null
            ) "--cloud-init-network-config ${options.cloudInitNetworkConfigFile}"}

          # since we are not able to obtain the logs in an easy way, we check whether the vm is running and has no error
          echo "preparing VM to start"
          vmInfo=$(sclctl vm show ${serviceName} ${vmName})
          while [ "$( echo $vmInfo | jq -r ".status.running")" == "null" ]
          do
            sleep 1
            if [ "$(echo $vmInfo | jq -r ".status.prepared.transitionInfo.errorDescription")" != "null" ]
            then
              echo $vmInfo | jq -r ".status.prepared.transitionInfo.errorDescription"
              false
            fi
            vmInfo=$(sclctl vm show ${serviceName} ${vmName})
          done
          echo "VM Started"
          while [ "$( echo $vmInfo | jq -r ".status.running")" != "null" ]
          do
            sleep 1
            vmInfo=$(sclctl vm show ${serviceName} ${vmName})
          done
        '';
        serviceConfig.ExecStop = pkgs.writeShellScript "vm-${vmName}-stop" ''
          sclctl vm update ${serviceName} ${vmName} stopped
          sclctl vm delete ${serviceName} ${vmName}
        '';
        serviceConfig.Restart = "always";
      };
    };

  mkNetworkService =
    name: networkOptions:
    let
      serviceName = "scl-${lib.toLower name}";
    in
    {
      name = "vm-network-${lib.toLower name}";
      value = {
        enable = true;
        wantedBy = [ "scl.target" ];
        requires = [ "scl.target" ];
        after = [ "scl.target" ];
        path = with pkgs; [
          config.programs.sclctl.package
          jq
        ];
        preStart = ''
          while ! sclctl sc list; do
            echo "waiting for scl"
            sleep 1
          done
        '';
        script = ''
          if ! sclctl sc show ${serviceName}
          then
            sclctl sc create ${serviceName}
          fi

          while sclctl router delete ${serviceName} router
          do
            echo "Deleting existing router instance"
            sleep 1
          done

          sclctl router create ${serviceName} router \
            --external-ip ${networkOptions.externalIP} \
            --internal-ip ${networkOptions.gatewayIP} \
            --internal-ip-netmask ${networkOptions.internalNetmask} \
            ${lib.concatStringsSep "\n" (
              map (rule: "--forward-tcp ${rule} \\") networkOptions.allowedTCPPorts
            )}
            ${lib.concatStringsSep "\n" (
              map (rule: "--forward-udp ${rule} \\") networkOptions.allowedUDPPorts
            )}

          echo "activating router"
          while [ "$(sclctl router show ${serviceName} router | jq -r ".status")" == "pending" ]
          do
            sleep 1
          done
          echo "router activated"
          while [ "$(sclctl router show ${serviceName} router | jq -r ".status.assigned")" != "null" ]
          do
            sleep 1
          done
        '';
        serviceConfig = {
          restart = "always";
          ExecStop = pkgs.writeShellScript "${serviceName}-stop" ''
            while sclctl router delete ${serviceName} router
            do
              echo "Deleting existing router instance"
              sleep 1
            done
          '';
        };
      };
    };

  defaultNetwork = {
    externalIP = "192.168.10.1";
    gatewayIP = "192.168.20.1";
    internalNetmask = "255.255.255.0";
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];
  };

  networks =
    if (cfg.networks.default or { }) == null then
      builtins.removeAttrs cfg.networks [ "default" ]
    else
      lib.recursiveUpdate {
        default = defaultNetwork;
      } cfg.networks;
in
{
  imports = [
    ./internal/sclctl.nix
    ./internal/scl-singlenode.nix
    (lib.mkRenamedOptionModule [ "ctrl-os" "vms" ] [ "cyberus-linux" "vms" ])
  ];

  options.cyberus-linux.vms = {
    gatewayInterface = mkOption {
      description = ''
        The network interface that should be used to allow internet access for virtual machines
      '';
      type = with types; nullOr nonEmptyStr;
      default = null;
      example = "eno1";
    };

    networks = mkOption {
      type = with types; attrsOf (nullOr (submodule vmNetworkOptions));
      default = { };
      description = ''
        The virtual machine network is separated from the host network using
        network namespaces.
        To access the virtual machines network from the host, a router
        component ensures forwarding of desired ports to the guest network
        via a dedicated ip address assignment on the host network.

        Internally, virtual machines are available at a desired IP address.
        At the moment there is no DHCP server feature, thus a static IP
        assignment is necessary beforehand.

        There is a default network configuration, with the following options specified:
        - externalIP: 192.168.10.1
        - internalIP: 192.168.20.1
        - internalNetmask: 255.255.255.0
        - allowedTCPPorts: [ ]
        - allowedUDPPorts: [ ]

        If the default network is specified, changes are merged into the existing default network
        If default = null; is specified, the default network will be deleted.
      '';
    };

    virtualMachines = mkOption {
      default = { };
      type = with types; attrsOf (submodule vmOptions);
      description = "Virtual Machines to run as systemd services in cloud hypervisor.";
    };
  };

  config = mkIf (cfg.virtualMachines != { }) {

    assertions = [
      {
        assertion = cfg.gatewayInterface != null;
        message = ''
          Please specify the gatewayInterface, to allow an internet connection for your VMs.
        '';
      }
    ];

    systemd.services =
      (lib.mapAttrs' mkNetworkService networks) // (lib.mapAttrs' mkVMService cfg.virtualMachines);

    services.scl-singlenode = {
      enable = true;
      l3NetController.gateway = cfg.gatewayInterface;
    };

    programs.sclctl.enable = true;
  };
}
