{
  lib,
  openssl,
  pkg-config,
  rustPlatform,
  makeWrapper,
  efitools,
  systemd,
}:
let
  cargoToml = lib.importTOML ./src/Cargo.toml;
in
rustPlatform.buildRustPackage {
  pname = cargoToml.package.name;
  inherit (cargoToml.package) version;

  src = ./src;

  cargoLock.lockFile = ./src/Cargo.lock;

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];

  buildInputs = [ openssl ];

  postFixup = ''
    wrapProgram $out/bin/cysb \
      --set SYSTEMD_SBSIGN_PATH "${systemd}/lib/systemd/systemd-sbsign" \
      --prefix PATH : ${
        lib.makeBinPath [
          efitools
        ]
      }
  '';

  meta = {
    description = "Manage the Secure Boot keys of Cyberus Linux";
    license = lib.licenses.asl20;
    mainProgram = "cysb";
    platforms = lib.platforms.linux;
  };
}
