{ lib, ... }:
{
  imports = [
    ./devices

    (lib.mkRenamedOptionModule [ "ctrl-os" "hardware" ] [ "cyberus-linux" "hardware" ])
  ];
}
