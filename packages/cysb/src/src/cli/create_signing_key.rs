//! Create a key for signing UEFI binaries.
use std::{fs, os::unix::fs::DirBuilderExt, path::PathBuf};

use anyhow::{Context, Result};
use clap::Args;
use log::info;
use openssl::{
    hash::MessageDigest,
    pkey::{PKeyRef, Private},
    x509::{X509Req, X509ReqBuilder},
};

use crate::util::cert;

/// Create a new key for signing UEFI binaries.
#[derive(Debug, Args)]
pub struct Opts {
    /// Directory to write the key and certificate signing request to. Must not exist yet.
    #[arg(short, long)]
    output_directory: PathBuf,
}

impl Opts {
    pub fn run(&self) -> Result<()> {
        // The directory contains the private key. This fails if the directory already exists, so we never overwrite
        // existing keys.
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&self.output_directory)
            .with_context(|| format!("Failed to create {}", self.output_directory.display()))?;

        let key_file = self.output_directory.join("signing.key");
        let csr_file = self.output_directory.join("signing.csr");

        info!(
            "Creating signing key: key={} csr={}",
            key_file.display(),
            csr_file.display()
        );

        let key = cert::generate_key()?;
        let csr = create_csr(&key)?;

        fs::write(&key_file, key.private_key_to_pem_pkcs8()?)
            .with_context(|| format!("Failed to write {}", key_file.display()))?;
        fs::write(&csr_file, csr.to_pem()?)
            .with_context(|| format!("Failed to write {}", csr_file.display()))?;

        Ok(())
    }
}

/// Create a certificate signing request for the given key.
///
/// The CSR only serves to transport the public key to the signing CA and to prove that the requester holds the private
/// key. It has no subject or extensions, because the signing CA decides on those when it issues the certificate.
fn create_csr(key: &PKeyRef<Private>) -> Result<X509Req> {
    let mut builder = X509ReqBuilder::new()?;

    // PKCS#10 only knows version 1, which is encoded as 0.
    builder.set_version(0)?;

    builder.set_pubkey(key)?;
    builder.sign(key, MessageDigest::sha256())?;

    Ok(builder.build())
}
