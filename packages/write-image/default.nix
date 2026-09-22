{
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "cyberus-linux-write-image";
  version = "0.1.0";

  src = ./src;

  cargoHash = "sha256-005nkIXhWVMF2z07Gg4xqttucW2Hryo/PVrOzZ3bcR4=";
}
