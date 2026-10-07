//! Create a new Secure Boot CA.
//!
//! # UEFI variables
//!
//! Secure Boot is configured by four UEFI variables:
//!
//! - `PK` (Platform Key) holds exactly one certificate. The holder of this key may update `PK` and `KEK`.
//! - `KEK` (Key Exchange Key) holds any number of certificates. The key of any of them may update `db` and `dbx`.
//! - `db` (signature database) holds certificates and hashes that allow UEFI binaries to run.
//! - `dbx` (forbidden signature database) holds certificates and hashes that forbid UEFI binaries from running. It
//!   takes precedence over `db`.
//!
//! Firmware only runs a UEFI binary if it is not forbidden by `dbx`, and either its hash is in `db` or it is signed by a
//! key whose certificate is in `db` or was issued by a certificate in `db`.
//!
//! # Owner GUID
//!
//! Each entry in the variables above records the GUID of its owner. This command creates a random GUID that identifies
//! our entries, e.g. to tell them apart from Microsoft's. It is written to `public/guid.txt`.
use std::{
    fs::{self, DirBuilder},
    os::unix::fs::DirBuilderExt,
    path::PathBuf,
};

use anyhow::{Context, Result};
use clap::Args;
use log::info;
use openssl::{
    pkey::{PKey, Private},
    x509::X509,
    x509::extension::{BasicConstraints, KeyUsage},
};

use uuid::Uuid;

use crate::util::cert::{self, Issuer};

/// Firmware does not check certificate expiry, because it has no trusted time source. The validity period only
/// matters to tools such as sbverify and must cover all certificates issued by the signing CA.
const VALIDITY_DAYS: u32 = 20 /* years */ * 365;

/// Create a new Secure Boot CA.
#[derive(Debug, Args)]
pub struct Opts {
    /// Directory to write the keys and certificates to.
    #[arg(short, long)]
    output_directory: PathBuf,
}

impl Opts {
    pub fn run(&self) -> Result<()> {
        let private_dir = self.output_directory.join("private");
        let public_dir = self.output_directory.join("public");

        fs::create_dir_all(&self.output_directory)
            .with_context(|| format!("Failed to create {}", self.output_directory.display()))?;

        // This fails if the directory already exists, so we never overwrite existing keys.
        DirBuilder::new()
            .mode(0o700)
            .create(&private_dir)
            .with_context(|| format!("Failed to create {}", private_dir.display()))?;

        fs::create_dir_all(&public_dir)
            .with_context(|| format!("Failed to create {}", public_dir.display()))?;

        // The boolean indicates whether the key issues certificates.
        let keys = [
            ("pk", "Secure Boot PK", false),
            ("kek", "Secure Boot KEK", false),
            ("signing-ca", "Secure Boot Signing CA", true),
        ];

        for (name, common_name, issues_certificates) in keys {
            let key_file = private_dir.join(format!("{name}.key"));
            let cert_file = public_dir.join(format!("{name}.crt"));

            info!(
                "Creating {common_name}: key={} cert={}",
                key_file.display(),
                cert_file.display()
            );

            let (key, cert) = create_self_signed(common_name, issues_certificates)
                .with_context(|| format!("Failed to create {common_name}"))?;

            fs::write(&key_file, key.private_key_to_pem_pkcs8()?)
                .with_context(|| format!("Failed to write {}", key_file.display()))?;
            fs::write(&cert_file, cert.to_pem()?)
                .with_context(|| format!("Failed to write {}", cert_file.display()))?;
        }

        let guid_file = public_dir.join("guid.txt");
        let guid = Uuid::new_v4();

        info!("Owner GUID: {guid}");

        fs::write(&guid_file, format!("{guid}\n"))
            .with_context(|| format!("Failed to write {}", guid_file.display()))?;

        Ok(())
    }
}

/// Create an RSA key and a self-signed CA certificate for it.
///
/// If `issues_certificates` is set, the key may only sign certificates and the certificates it issues cannot be CAs
/// themselves. Otherwise, the key is not restricted.
fn create_self_signed(
    common_name: &str,
    issues_certificates: bool,
) -> Result<(PKey<Private>, X509)> {
    let key = cert::generate_key()?;

    // Mark the certificate as a CA certificate.
    let mut basic_constraints = BasicConstraints::new();
    basic_constraints.critical().ca();
    if issues_certificates {
        // Tell verifiers that no CA may follow this certificate in a chain.
        basic_constraints.pathlen(0);
    }
    let mut extensions = vec![basic_constraints.build()?];

    if issues_certificates {
        extensions.push(
            KeyUsage::new()
                .critical()
                .key_cert_sign()
                .crl_sign()
                .build()?,
        );
    }

    let cert = cert::create_certificate(
        &key,
        common_name,
        VALIDITY_DAYS,
        Issuer::SelfSigned { key: key.clone() },
        extensions,
    )?;

    Ok((key, cert))
}
