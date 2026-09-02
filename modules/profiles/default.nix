{ lib, ... }:
{
  imports = [
    ./developer
    ./cyberus-linux-system

    (lib.mkRenamedOptionModule [ "ctrl-os" "profiles" ] [ "cyberus-linux" "profiles" ])
  ];
}
