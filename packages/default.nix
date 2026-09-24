{ pkgs }:
{
  scl = pkgs.callPackage ./scl.nix { };
  OVMF-cloud-hypervisor = pkgs.callPackage ./OVMF-cloud-hypervisor.nix { };
  cyberus-linux-write-image = pkgs.callPackage ./write-image { };
}
