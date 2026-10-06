//! Sign a UEFI binary.
use std::{
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result, ensure};
use clap::Args;
use log::info;

use crate::util::external_commands;

/// Common arguments for signing operations.
#[derive(Clone, Debug, Args)]
pub struct SignOpts {
    /// Path to systemd-sbsign.
    ///
    /// It is usually not in PATH, but in systemd's library directory, e.g. /usr/lib/systemd/systemd-sbsign on most
    /// distributions. The default is the location on NixOS.
    #[arg(
        long,
        env = "SYSTEMD_SBSIGN_PATH",
        default_value = "/run/current-system/sw/lib/systemd/systemd-sbsign"
    )]
    pub systemd_sbsign_path: PathBuf,

    /// Certificate of the signing key, as issued by `cysb issue-signing-certificate`.
    ///
    /// A path to a PEM file, unless --certificate-source says otherwise. This is usually a file, even if the private key
    /// is on a token.
    #[arg(long)]
    pub certificate: String,

    /// How to interpret --certificate: file or provider:PROVIDER, e.g. provider:pkcs11.
    #[arg(long, default_value = "file")]
    pub certificate_source: String,

    /// Private key to sign with.
    ///
    /// A path to a PEM file as created by `cysb create-signing-key`, unless --private-key-source says otherwise. For a key
    /// on a token, use a pkcs11: URI, e.g. 'pkcs11:object=SIGN%20key;type=private'. `pkcs11-tool -O` shows the label.
    #[arg(long)]
    pub private_key: String,

    /// How to interpret --private-key: file, provider:PROVIDER or engine:ENGINE.
    ///
    /// For keys on a token, use provider:pkcs11. This requires the OpenSSL pkcs11-provider to be installed and
    /// configured, e.g. via OPENSSL_MODULES and PKCS11_PROVIDER_MODULE.
    #[arg(long, default_value = "file")]
    pub private_key_source: String,
}

impl SignOpts {
    pub fn check_tools(&self) -> Result<()> {
        external_commands::check_command(
            &self.systemd_sbsign_path,
            "Set --systemd-sbsign-path or SYSTEMD_SBSIGN_PATH to the location of systemd-sbsign, \
             e.g. /usr/lib/systemd/systemd-sbsign.",
        )
    }

    /// Sign a single binary with systemd-sbsign.
    pub fn sign_file(&self, input: &Path, output: &Path) -> Result<()> {
        // systemd-sbsign inherits stdin, stdout and stderr, because it may need to ask for a PIN, e.g. for keys on a
        // Nitrokey. Its error messages go directly to the user.
        let status = Command::new(&self.systemd_sbsign_path)
            .arg("sign")
            .arg("--certificate")
            .arg(&self.certificate)
            .arg("--certificate-source")
            .arg(&self.certificate_source)
            .arg("--private-key")
            .arg(&self.private_key)
            .arg("--private-key-source")
            .arg(&self.private_key_source)
            .arg("--output")
            .arg(output)
            .arg(input)
            .status()
            .with_context(|| format!("Failed to execute {}", self.systemd_sbsign_path.display()))?;

        ensure!(
            status.success(),
            "{} failed ({status})",
            self.systemd_sbsign_path.display()
        );

        Ok(())
    }
}

/// Sign a UEFI binary.
#[derive(Debug, Args)]
pub struct Opts {
    /// Where to write the signed binary. Overwritten if it already exists.
    #[arg(long, short = 'o')]
    output: PathBuf,

    /// Path to the UEFI binary to sign.
    file: PathBuf,

    #[command(flatten)]
    sign_opts: SignOpts,
}

impl Opts {
    pub fn run(&self) -> Result<()> {
        self.sign_opts.check_tools()?;
        self.sign_opts.sign_file(&self.file, &self.output)?;

        info!("Signed {}: {}", self.file.display(), self.output.display());

        Ok(())
    }
}
