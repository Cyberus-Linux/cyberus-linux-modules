{ pkgs }:
{
  cysb = pkgs.callPackage ./cysb { };
  scl = pkgs.callPackage ./scl.nix { };
  OVMF-cloud-hypervisor = pkgs.callPackage ./OVMF-cloud-hypervisor.nix { };
}
