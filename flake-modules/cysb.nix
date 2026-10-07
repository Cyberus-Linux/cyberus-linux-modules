{ ... }: {
  perSystem = { self', pkgs, ... }: {

    # Development shell for cysb.
    devShells.cysb = pkgs.mkShell {
      inputsFrom = [
        self'.packages.cysb
      ];

      packages = with pkgs; [
        rust-analyzer
        rustPackages.clippy
      ];
    };

    # Shell to try out signing things (with smart cards).
    devShells.cysb-pkcs11 = pkgs.mkShell {
      packages = with pkgs; [
        pynitrokey

        sbsigntool
        efitools

        self'.packages.cysb
      ];

      env = {
        OPENSSL_MODULES = "${pkgs.pkcs11-provider}/lib/ossl-modules";
        PKCS11_PROVIDER_MODULE = "${pkgs.opensc}/lib/opensc-pkcs11.so";
      };
    };
  };
}
