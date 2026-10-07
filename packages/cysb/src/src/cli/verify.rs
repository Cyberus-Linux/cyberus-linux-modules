//! Verify the signatures of UEFI binaries.
use std::{
    io::Write,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result};
use clap::Args;
use tempfile::NamedTempFile;

use crate::util::{cert, external_commands};

/// Verify the signatures of UEFI binaries.
#[derive(Debug, Args)]
pub struct Opts {
    /// Certificate of the signing CA in PEM or DER format, e.g. public/signing-ca.crt as created by init-ca.
    #[arg(short = 'c', long)]
    signing_ca_certificate: PathBuf,

    /// UEFI binary to verify.
    #[arg(required = true)]
    file: PathBuf,
}

impl Opts {
    pub fn run(&self) -> Result<()> {
        external_commands::check_command(
            Path::new("sbverify"),
            "Install sbsigntools, e.g. via nix-shell -p sbsigntool.",
        )?;

        // sbverify only reads certificates in PEM format, so we hand it a PEM copy of the certificate.
        let certificate = cert::read_certificate(&self.signing_ca_certificate)?;
        let mut pem_file =
            NamedTempFile::new().context("Failed to create temporary certificate file")?;
        pem_file
            .write_all(&certificate.to_pem()?)
            .context("Failed to write temporary certificate file")?;

        print!("Verifying {}: ", self.file.display());
        verify_file(pem_file.path(), &self.file).inspect_err(|e| println!(" FAILED: {}", e))?;
        println!("OK");
        Ok(())
    }
}

/// Verify the signature of a single binary with sbverify.
fn verify_file(certificate: &Path, file: &Path) -> Result<()> {
    external_commands::run(
        Command::new("sbverify")
            .arg("--cert")
            .arg(certificate)
            .arg(file),
    )
}
