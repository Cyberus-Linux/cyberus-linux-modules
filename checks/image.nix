{
  pkgs,
  packages,
  lib,
  nixosModules,
}:

let
  mkImageTest' = pkgs.callPackage ./image-base.nix { inherit nixosModules; };

  mkImageTest =
    attrName:
    {
      additionalConfig ? { },
      name,
      ...
    }@args:
    [
      {
        name = "${attrName}Minimal";
        value = mkImageTest' (
          args
          // {
            name = "${name} (Minimal)";
            additionalConfig = {
              imports = [ additionalConfig ];
              config = {
              };
            };
          }
        );
      }
    ];
in
builtins.listToAttrs (
  builtins.concatLists [
    (mkImageTest "imageDefault" {
      name = "Image Test (defaults)";
      testScript = ''
        # Header plus one swap entry
        print(machine.execute('cat /proc/swaps'))
        machine.succeed('[ "$(wc -l < /proc/swaps)" -eq 2 ]')
      '';
    })

    (mkImageTest "imageWithoutSwap" {
      name = "Image Test (disabled swap)";
      additionalConfig = {
        cyberus-linux.image.swap.enable = false;
      };
      testScript = ''
        # Header without swap entries
        machine.succeed('[ "$(wc -l < /proc/swaps)" -eq 1 ]')
      '';
    })

    (mkImageTest "imageKnownBootDev" {
      name = "Image Test (rootdev known)";
      additionalConfig = {
        cyberus-linux.image.bootDevice = "/dev/vda";
      };
      testScript = ''
        # Header without swap entries
        machine.succeed('[ "$(wc -l < /proc/swaps)" -eq 2 ]')
      '';
    })

    (mkImageTest "imageUpdates" {
      name = "Image Test (updates)";

      additionalConfig =
        {
          pkgs,
          lib,
          config,
          extendModules,
          ...
        }:
        let
          # Create an update package in version `from` to version `to`.
          #
          # We need to do ugly overrides to get the right version into each version of the image. Better solutions
          # welcome!
          mkUpdate = override: to: {
            source =
              (extendModules {
                modules = [
                  {
                    cyberus-linux.image.version = lib.mkOverride override to;
                  }
                ];
              }).config.system.build.imageUpdateBundle;
          };
        in
        {
          cyberus-linux.image.version = lib.mkDefault "1.0.0";

          # FIXME: The shared directory is not mounted, so we cannot use copy_from_host.
          # We work around this by bundling the image in the generated image.
          environment.etc.updates =
            {
              "1.0.0" = mkUpdate 100 "1.0.1";
              "1.0.1" = mkUpdate 99 "2.0.0-rc3";
            }
            .${config.cyberus-linux.image.version} or {
              source = pkgs.emptyDirectory;
            };

        };

      testScript = ''

        def check_update(from_version, to_version):
            # Make the bundled image available.
            machine.succeed("rm -f /var/updates")
            machine.succeed("ln -sf /etc/updates /var/updates")

            current_version = machine.succeed("grep IMAGE_VERSION /etc/os-release")
            t.assertIn(from_version, current_version)

            updates = machine.succeed("updatectl check")
            t.assertIn(f"{from_version} → {to_version}", updates)

            # Ensure the update process has completed running.
            # NOTE: This command likely may not fail on update failures.
            machine.succeed("updatectl update")

            # For some failure modes, the `updatectl update` command will exit(0)
            # Additionally, it will print confusing output such as:
            #     host@1.0.1: ✗ No space left on device
            #     host@1.0.1: ✓ Already up-to-date
            # So we need to check the `check` subcommand instead.
            # This saves a needless reboot in case of failures.
            output = machine.succeed("updatectl check 2>&1")
            t.assertIn("No updates available.", output)

            machine.reboot()
            check_post_boot_sanity()

            current_version = machine.succeed("grep IMAGE_VERSION /etc/os-release")
            t.assertIn(to_version, current_version)


        check_update("1.0.0", "1.0.1")
        check_update("1.0.1", "2.0.0-rc3")
      '';
    })

    (
      let
        runCysb =
          name: script:
          pkgs.runCommand name {
            nativeBuildInputs = [ packages.cysb ];
          } script;

        secureBootKeys = runCysb "secure-boot-keys" ''
          cysb init-ca -o $out
        '';

        enrollmentPackage = runCysb "enrollment-package" ''
          K=${secureBootKeys}
          cysb create-enrollment \
            --owner-guid "$(cat $K/public/guid.txt)" \
            --pk-key $K/private/pk.key --pk-certificate $K/public/pk.crt \
            --kek-key $K/private/kek.key --kek-certificate $K/public/kek.crt \
            --signing-ca-certificate $K/public/signing-ca.crt \
            -o $out
        '';

        signingKey = runCysb "signing-key" ''
          cysb create-signing-key -o $out/
          cysb issue-signing-certificate \
            --signing-ca-key ${secureBootKeys}/private/signing-ca.key \
            --signing-ca-certificate ${secureBootKeys}/public/signing-ca.crt \
            --csr $out/signing.csr \
            -o $out/signing.crt

          rm $out/signing.csr
        '';

        blessImage = ''
          orig_raw_image = raw_image
          modified_raw_image = tempfile.NamedTemporaryFile()
          raw_image = modified_raw_image.name

          # Preserve sparseness of the raw image to save space.
          subprocess.run(["cp", "--sparse=always", orig_raw_image, raw_image], check=True)

          # cysb bless-image only understands raw images.
          subprocess.run([
            "${lib.getExe packages.cysb}",
            "bless-image",
            "--private-key",
            "${signingKey}/signing.key",
            "--certificate",
            "${signingKey}/signing.crt",
            raw_image,
          ], check=True)
        '';
      in
      mkImageTest "imageSecureBoot" {
        name = "Image Test (Secure Boot)";

        additionalImagePrep = blessImage;

        additionalConfig = {
          cyberus-linux.image = {
            loaderConf = ''
              secure-boot-enroll-timeout-sec 0
              secure-boot-enroll force
            '';
            secure-boot.enrollKeys.auto = enrollmentPackage;
          };
        };
        testScript = ''
          t.assertIn("Secure Boot: enabled (user)", machine.succeed('bootctl'))
        '';
      }
    )
  ]
)
