{
  lib,
  openssl,
  pkg-config,
  rustPlatform,
}:
let
  cargoToml = lib.importTOML ./src/Cargo.toml;
in
rustPlatform.buildRustPackage {
  pname = cargoToml.package.name;
  inherit (cargoToml.package) version;

  src = ./src;

  cargoLock.lockFile = ./src/Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = {
    description = "Manage the Secure Boot keys of Cyberus Linux";
    license = lib.licenses.asl20;
    mainProgram = "cysb";
    platforms = lib.platforms.linux;
  };
}
