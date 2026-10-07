//! Create an enrollment package for systemd-boot.
//!
//! The package contains:
//!
//! - `PK.auth`: the PK certificate, signed by the PK key.
//! - `KEK.auth`: the KEK certificate, signed by the PK key.
//! - `db.auth`: the signing CA certificate, signed by the KEK key.
//!
//! systemd-boot would also enroll a `dbx.auth`, but there is nothing to forbid yet. Whether systemd-boot enrolls the
//! package automatically is controlled by `secure-boot-enroll` in `loader.conf`.
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result, ensure};
use clap::Args;
use log::info;
use openssl::x509::X509Ref;
use tempfile::TempDir;
use uuid::Uuid;

use crate::util::{cert, external_commands};

/// Create an enrollment package for systemd-boot.
#[derive(Debug, Args)]
pub struct Opts {
    /// Owner GUID of our entries in the variables, as created by init-ca in public/guid.txt.
    #[arg(long)]
    owner_guid: Uuid,

    /// Private key of the PK, e.g. private/pk.key as created by init-ca. Signs the updates of PK and KEK.
    #[arg(long)]
    pk_key: PathBuf,

    /// Certificate of the PK, e.g. public/pk.crt as created by init-ca. Enrolled in PK.
    #[arg(long)]
    pk_certificate: PathBuf,

    /// Private key of the KEK, e.g. private/kek.key as created by init-ca. Signs the update of db.
    #[arg(long)]
    kek_key: PathBuf,

    /// Certificate of the KEK, e.g. public/kek.crt as created by init-ca. Enrolled in KEK.
    #[arg(long)]
    kek_certificate: PathBuf,

    /// Certificate of the signing CA, e.g. public/signing-ca.crt as created by init-ca. Enrolled in db.
    #[arg(long)]
    signing_ca_certificate: PathBuf,

    /// Directory to write PK.auth, KEK.auth and db.auth to. Copy them to loader/keys/<NAME>/ on the ESP for
    /// systemd-boot.
    #[arg(short, long)]
    output_directory: PathBuf,
}

impl Opts {
    pub fn run(&self) -> Result<()> {
        for command in ["cert-to-efi-sig-list", "sign-efi-sig-list"] {
            external_commands::check_command(
                Path::new(command),
                "Install efitools, e.g. via nix-shell -p efitools.",
            )?;
        }

        // Catch mixed up keys and certificates here. Otherwise, efitools would happily create updates that firmware
        // rejects.
        let (_, pk_cert) = cert::read_key_pair(&self.pk_key, &self.pk_certificate)?;
        let (_, kek_cert) = cert::read_key_pair(&self.kek_key, &self.kek_certificate)?;
        let signing_ca_cert = cert::read_certificate(&self.signing_ca_certificate)?;

        // efitools only reads certificates in PEM format, while ours may also be in DER format. The directory also
        // holds the intermediate signature lists and is removed when it goes out of scope.
        let work = TempDir::new().context("Failed to create temporary directory")?;
        let pk_pem = write_pem(&work, "pk.crt", &pk_cert)?;
        let kek_pem = write_pem(&work, "kek.crt", &kek_cert)?;
        let signing_ca_pem = write_pem(&work, "signing-ca.crt", &signing_ca_cert)?;

        fs::create_dir_all(&self.output_directory)
            .with_context(|| format!("Failed to create {}", self.output_directory.display()))?;

        // Variable, certificate to enroll, and the key and certificate that sign the update.
        let updates = [
            ("PK", &pk_pem, &self.pk_key, &pk_pem),
            ("KEK", &kek_pem, &self.pk_key, &pk_pem),
            ("db", &signing_ca_pem, &self.kek_key, &kek_pem),
        ];

        for (variable, enrolled_cert, signing_key, signing_cert) in updates {
            let signature_list = work.path().join(format!("{variable}.esl"));
            let update = self.output_directory.join(format!("{variable}.auth"));

            // sign-efi-sig-list silently overwrites its output.
            ensure!(!update.exists(), "{} already exists", update.display());

            external_commands::run(
                Command::new("cert-to-efi-sig-list")
                    .arg("-g")
                    .arg(self.owner_guid.to_string())
                    .arg(enrolled_cert)
                    .arg(&signature_list),
            )?;

            external_commands::run(
                Command::new("sign-efi-sig-list")
                    .arg("-k")
                    .arg(signing_key)
                    .arg("-c")
                    .arg(signing_cert)
                    .arg(variable)
                    .arg(&signature_list)
                    .arg(&update),
            )?;

            info!("Created {}", update.display());
        }

        Ok(())
    }
}

/// Write a certificate in PEM format to the given directory.
fn write_pem(dir: &TempDir, file_name: &str, cert: &X509Ref) -> Result<PathBuf> {
    let path = dir.path().join(file_name);
    fs::write(&path, cert.to_pem()?)
        .with_context(|| format!("Failed to write {}", path.display()))?;
    Ok(path)
}
