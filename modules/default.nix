{
  hardware = import ./hardware;
  profiles = import ./profiles;
  vms = import ./vms.nix;
  image = import ./image.nix;
}
