{ nixosModules, testers }:
testers.nixosTest {
  name = "profiles.developer";

  nodes.machine = {
    imports = [ nixosModules.profiles ];

    cyberus-linux.profiles.developer.enable = true;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
  '';
}
