# Cyberus Linux Secure Boot Tooling

This Rust program (`cysb`) manages the keys and certificates for Secure Boot on Cyberus Linux. It also signs UEFI binaries. It is not meant as a general tool to cater to all Secure Boot setups. The intention is to provide a simple, opinionated tool for managing Secure Boot on Cyberus Linux.

This README gives a quick overview of `cysb`. For more details, see [the Cyberus Linux documentation](https://docs.cyberus-linux.com/). A general overview of UEFI and UEFI Secure Boot is out of scope for this README.

## Intended Use Case

Our intended use case is that most keys involved in our Secure Boot setup are offline and rarely used. Keys we need to use frequently can reside on HSMs or other secure elements.

We settled on the following key setup as the root of trust. These are the keys that are created by `cysb init-ca`.

- One **Platform Key (PK)**: This key will be enrolled in the PK variable. The PK signs updates of `PK` and `KEK`.
- One **Key Exchange Key (KEK)**: This key will be enrolled in the KEK variable. The KEK signs updates of `db` and `dbx`. While the `KEK` variable can hold multiple certificates, we only use one.
- One **Signing CA**: For signing UEFI binaries, we enroll this CA in the `db` variable. We don't use this CA directly to sign UEFI binaries. Instead, it issues certificates for other keys (e.g. keys created on HSMs) and we sign with them.

For signing UEFI binaries, additional signing keys can be created via `cysb create-signing-key` (or directly on an HSM) and then signed via `cysb issue-signing-certificate`. These keys can then be used in CI to sign production UEFI binaries.

## Requirements

`cysb` relies on external tools for certain tasks. Over time, these can move to Rust code:

- `cysb create-enrollment` needs `cert-to-efi-sig-list` and `sign-efi-sig-list` from `efitools`.
- `cysb sign-file` needs `systemd-sbsign` from `systemd`.
- `cysb verify` needs `sbverify` from `sbsigntools`.

To interact with HSMs, you will need additional setup according to the HSM documentation. We'll give some examples here for interacting with a [Nitrokey](https://www.nitrokey.com/).

## Walkthrough

This section provides a minimal walkthrough of the lifecycle of Secure Boot.

### Create the CA

On a secure machine, create the PK, KEK, and signing CA:

```sh
cysb init-ca -o ca
```

This creates the following files in the `ca` directory.

In the `private` subdirectory, you will find the private keys:

- `pk.key`
- `kek.key`
- `signing-ca.key`

In the `public` subdirectory, you will find the certificates and the owner GUID:

- `pk.crt`
- `kek.crt`
- `signing-ca.crt`
- `guid.txt`

Keep the private keys secure!

### Preparing the Target Machine

We assume that you have a target machine that boots with `systemd-boot`. One way to achieve this is to use the
`cyberus-linux.image` module from this repository.

Put the target machine in `Setup Mode` to enroll the keys. How this is achieved is out of scope for this guide.
You may find [the Lanzaboote
documentation](https://nix-community.github.io/lanzaboote/getting-started/enable-secure-boot.html#enter-secure-boot-setup-mode)
or the [Arch Linux
documentation](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#Putting_firmware_in_%22Setup_Mode%22)
helpful.

### **Important**: Checking for Boot Drivers

Before enabling Secure Boot, ensure that the target machine does not need any boot drivers. This is **crucial** to avoid
bricking the machine!

Install the `tpm2_eventlog` tool from `tpm2-tools`. Then check for `EV_EFI_BOOT_SERVICES_DRIVER` events in the log by
executing the following command on the target machine:

```console
$ sudo tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements | grep EV_EFI_BOOT_SERVICES_DRIVER
```

If you get any errors when executing the command or you see `EventType: EV_EFI_BOOT_SERVICES_DRIVER` in the output, **do
not enable Secure Boot** on this machine. This limitation will be lifted soon.

Even if you don't see `EV_EFI_BOOT_SERVICES_DRIVER` in the output, there is a small risk that the machine will not boot
after enabling Secure Boot. Do not attempt to enable Secure Boot on a system that carries important data. If you end up
bricking the machine, you may need to contact your hardware vendor for assistance in resetting the firmware
configuration.

Also refer to the [sbctl documentation](https://github.com/Foxboron/sbctl/wiki/FAQ#option-rom) on this topic.

### Create an Enrollment Package

To enroll a machine in the Secure Boot scheme with the above keys, create an enrollment package on your secure system:

```sh
cysb create-enrollment \
  --owner-guid "$(cat ca/public/guid.txt)" \
  --pk-key ca/private/pk.key --pk-certificate ca/public/pk.crt \
  --kek-key ca/private/kek.key --kek-certificate ca/public/kek.crt \
  --signing-ca-certificate ca/public/signing-ca.crt \
  -o enroll
```

In the `enroll` directory, you will find the enrollment package:

- `PK.auth`
- `KEK.auth`
- `db.auth`

Copy these files to `loader/keys/<name>/` on the ESP of the target machine. `<name>` can be chosen freely, e.g.
"acme-corp-keys". On the next boot in `Setup Mode`, `systemd-boot` offers to enroll the keys via a menu item with the
given name.

Once `systemd-boot` has enrolled the keys, the target machine will **only** boot correctly signed binaries!

### Create a Signing Key

A signing key can be a file or live on a Nitrokey. First, we create the key and then issue a certificate for it. We show
two options: first, a signing key in software; then, a key on a Nitrokey as an example of a secure element.

#### Option 1: As a File

```sh
cysb create-signing-key -o signing-file
```

This writes the private key `signing-file/signing.key` and the CSR `signing-file/signing.csr`.

To issue the certificate, run:

```console
$ cysb -v issue-signing-certificate \
  --signing-ca-key ca/private/signing-ca.key --signing-ca-certificate ca/public/signing-ca.crt \
  --csr signing-file/signing.csr -o signing-file/signing.crt
INFO Issued certificate with serial number 61DE6E8DAF7710AB91D5336452E1C558: signing-file/signing.crt
```

Note the logged serial number, as it identifies the certificate if it ever needs to be revoked.

#### Option 2: On a Nitrokey 3

We'll walk through a short example of generating a key on a Nitrokey 3. The advantage of using a Nitrokey or a similar
secure element is that the key never leaves the device. A complete guide on how to use a Nitrokey is out of scope for
this document. Please refer to the [Nitrokey documentation](https://docs.nitrokey.com/nitrokeys/) for more information.

Install the `nitropy` CLI tool, e.g. via the `pynitrokey` attribute in Nixpkgs. Then generate a key on the Nitrokey in PIV slot 9c (Digital Signature):

```console
$ mkdir -p signing-nitro
$ nitropy nk3 piv --experimental generate-key --key 9c --algo rsa2048 --subject-name "CN=Signing Key" \
  --path signing-nitro/signing.csr
```

If you are asked for a PIN and haven't changed it from the default, enter `123456`.
`nitropy` writes the PIN in plaintext to its logs in `/tmp/nitropy-*.log`. Delete them afterwards.

Issue the certificate as before:

```console
$ cysb -v issue-signing-certificate \
  --signing-ca-key ca/private/signing-ca.key --signing-ca-certificate ca/public/signing-ca.crt \
  --csr signing-nitro/signing.csr -o signing-nitro/signing.crt
INFO Issued certificate with serial number 2A685A37A89B7D83B39379B1D259634B: signing-nitro/signing.crt
```

As an optional step, store the certificate on the Nitrokey for easy retrieval:

```console
$ nitropy nk3 piv --experimental write-certificate --key 9c --path signing-nitro/signing.crt
```

## Sign a UEFI binary

_Finally_, we are ready to sign a UEFI binary. Let's go!

### Option 1: Via a Signing Key as a File

This is the simplest option. Just provide the paths to the signing key and certificate. Then use `cysb sign-file` to sign the binary:

```console
$ cysb sign-file --private-key signing-file/signing.key --certificate signing-file/signing.crt \
  -o signed.efi unsigned.efi
```

### Option 2: Via a Signing Key on a Nitrokey

Signing using a key on a Nitrokey requires more preparation due to the underlying smartcard APIs (PKCS#11). We first need to set environment variables to point to the PKCS#11 provider and OpenSC library:

```console
# For development you can also do this via `nix develop .#cysb-pkcs11`
$ export OPENSSL_MODULES=<pkcs11-provider>/lib/ossl-modules
$ export PKCS11_PROVIDER_MODULE=<opensc>/lib/opensc-pkcs11.so
```

Now we need to find the ID of the key and certificate on the Nitrokey. We only need to do this once. We list the available keys and certificates on the Nitrokey and note the ID of the one we want to use:

```console
$ pkcs11-tool --module $PKCS11_PROVIDER_MODULE --list-objects --login
Using slot 0 with a present token (0x0)
Logging in to "Secure Boot Signing Key".
Please enter User PIN:
```

Use the PIN from before. Then find the following entries and note down their IDs:

```console
Private Key Object; RSA  2048 bits
...
  label:      SIGN key
  ID:         2 (0x02)
...
Certificate Object; type = X.509 cert
  label:      Certificate for Digital Signature
  subject:    DN: CN=Secure Boot Signing Key
  serial:     2A685A37A89B7D83B39379B1D259634B
  ID:         2 (0x02)
...
```

In our case, the IDs are `02` for the private key and `02` for the certificate. These need to be specified as `%02` in the `cysb sign-file` command:

```console
$ cysb sign-file \
  --private-key-source provider:pkcs11 \
  --private-key 'pkcs11:id=%02;type=private' \
  --certificate-source provider:pkcs11 \
  --certificate 'pkcs11:id=%02;type=cert' \
  -o signed.efi unsigned.efi
🔐 Enter pass phrase for PKCS#11 Token (Slot 0 - Nitrokey Nitrokey 3 [CCID/ICCD Interface] 00 00): ••••••
Wrote signed PE binary to /home/julian/Source/cyberus-linux/modules/signed.efi
```

To avoid entering the PIN every time, let the kernel cache the PIN for you:

```console
# TODO This is needlessly complicated. The path is only valid on NixOS
$ /run/current-system/sw/lib/systemd/systemd-keyutil validate --private-key-source provider:pkcs11 --private-key "pkcs11:id=%02;type=private" --certificate-source provider:pkcs11 --certificate 'pkcs11:id=%02;type=cert'
🔐 Enter pass phrase for PKCS#11 Token (Slot 0 - Nitrokey Nitrokey 3 [CCID/ICCD Interface] 00 00): ••••••
```

After this, `cysb sign-file` will not ask for a PIN again.

## Verify a UEFI binary

To double-check that a UEFI binary is signed by the signing CA, use `cysb verify`:

```console
$ cysb verify --signing-ca-certificate ca/public/signing-ca.crt signed.efi
Verifying signed.efi: OK
```
