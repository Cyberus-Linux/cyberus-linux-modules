//! Issue a certificate for a key that signs UEFI binaries.
//!
//! Only the public key of the certificate signing request (CSR) is used. The name, validity and extensions of the
//! certificate are decided here.
//!
//! The certificate does not need to be enrolled in `db`, because it is embedded in every signed binary and firmware
//! checks that it was issued by the signing CA certificate in `db`.
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::PathBuf,
};

use anyhow::{Context, Result, ensure};
use clap::Args;
use log::{info, warn};
use openssl::{
    pkey::{Id, PKey},
    x509::extension::{BasicConstraints, ExtendedKeyUsage, KeyUsage},
};

use crate::util::cert::{self, Issuer, read_csr};

/// Firmware does not check certificate expiry. Tools such as sbverify do, so this must not exceed the validity of the
/// signing CA certificate.
const VALIDITY_DAYS: u32 = 5 /* years */ * 365;

/// The key size that all firmware supports.
const COMPATIBLE_RSA_KEY_BITS: u32 = 2048;

/// Issue a certificate for a key that signs UEFI binaries.
#[derive(Debug, Args)]
pub struct Opts {
    /// Private key of the signing CA. This is the private/signing-ca.key as created by init-ca.
    #[arg(long)]
    signing_ca_key: PathBuf,

    /// Certificate of the signing CA. This is the public/signing-ca.crt as created by init-ca.
    #[arg(long)]
    signing_ca_certificate: PathBuf,

    /// Certificate signing request of the signing key in PEM or DER format, e.g. signing.csr as created by
    /// create-signing-key.
    #[arg(long)]
    csr: PathBuf,

    /// File to write the certificate to. Must not exist yet.
    #[arg(short, long)]
    output: PathBuf,

    /// Common name of the certificate.
    #[arg(long, default_value = "Secure Boot Signing Key")]
    common_name: String,
}

impl Opts {
    pub fn run(&self) -> Result<()> {
        let ca_key = PKey::private_key_from_pem(
            &fs::read(&self.signing_ca_key)
                .with_context(|| format!("Failed to read {}", self.signing_ca_key.display()))?,
        )?;
        let ca_cert = cert::read_certificate(&self.signing_ca_certificate)?;

        // Sanity check whether the given key and certificate match.
        ensure!(
            ca_cert.public_key()?.public_eq(&ca_key),
            "{} does not belong to {}",
            self.signing_ca_key.display(),
            self.signing_ca_certificate.display()
        );

        let csr = read_csr(&self.csr)?;
        let key = csr.public_key()?;

        // The CSR is signed by the key it contains. This proves that whoever created the CSR holds the private key.
        ensure!(
            csr.verify(&key)?,
            "The signature of {} is invalid",
            self.csr.display()
        );

        ensure!(
            key.id() == Id::RSA,
            "The key in {} is not an RSA key",
            self.csr.display()
        );
        if key.bits() != COMPATIBLE_RSA_KEY_BITS {
            warn!(
                "The key in {} has {} bits. Not all firmware supports keys other than RSA-{COMPATIBLE_RSA_KEY_BITS}.",
                self.csr.display(),
                key.bits()
            );
        }

        let extensions = vec![
            // Mark the certificate as not being a CA certificate.
            BasicConstraints::new().critical().build()?,
            // The key may only sign code.
            KeyUsage::new().critical().digital_signature().build()?,
            ExtendedKeyUsage::new().code_signing().build()?,
        ];

        let issuer = Issuer::Ca {
            key: ca_key,
            cert: ca_cert,
        };

        let cert =
            cert::create_certificate(&key, &self.common_name, VALIDITY_DAYS, issuer, extensions)?;

        // The serial number identifies the certificate, e.g. when it needs to be revoked via dbx.
        info!(
            "Issued certificate with serial number {}: {}",
            cert.serial_number().to_bn()?.to_hex_str()?,
            self.output.display()
        );

        let pem = cert.to_pem()?;
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&self.output)
            .and_then(|mut file| file.write_all(&pem))
            .with_context(|| format!("Failed to write {}", self.output.display()))?;

        Ok(())
    }
}
