mod cli;
mod util;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

use cli::{
    bless_image, create_enrollment, create_signing_key, init_ca, issue_signing_certificate,
    sign_file, verify,
};

use crate::cli::bless_update;

/// Manage the Secure Boot keys of Cyberus Linux.
#[derive(Debug, Parser)]
#[command(version, about)]
struct Cli {
    /// Increase the log verbosity. Can be given multiple times.
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    verbose: u8,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Create a new Secure Boot CA: PK, KEK and signing CA.
    InitCA(init_ca::Opts),

    /// Bless a disk image by signing the boot loader and any UKI.
    BlessImage(bless_image::Opts),

    /// Bless an update bundle by signing the kernel it contains.
    BlessUpdate(bless_update::Opts),

    /// Create a new key for signing UEFI binaries.
    ///
    /// This creates the key and a certificate signing request (CSR). Use issue-signing-certificate to turn the CSR
    /// into a certificate.
    CreateSigningKey(create_signing_key::Opts),

    /// Issue a certificate for a key that signs UEFI binaries.
    ///
    /// The certificate is issued by the signing CA. Firmware boots binaries signed with the key, because the signing CA
    /// certificate is enrolled in db.
    IssueSigningCertificate(issue_signing_certificate::Opts),

    /// Create an enrollment package for systemd-boot.
    ///
    /// The package contains the signed updates of PK, KEK and db. systemd-boot enrolls them from
    /// loader/keys/<NAME>/ on the ESP while the firmware is in setup mode.
    CreateEnrollment(create_enrollment::Opts),

    /// Sign a UEFI binary.
    ///
    /// Firmware boots the signed binary if the certificate of the signing key was issued by the signing CA. The
    /// signing is done by systemd-sbsign. For more information, see the systemd-sbsign man page.
    SignFile(sign_file::Opts),

    /// Verify the signatures of UEFI binaries.
    ///
    /// A binary passes if it is signed by a key which is trusted by the given certificate.
    Verify(verify::Opts),
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    // Warnings and errors are always shown. Each -v adds info, debug and
    // trace messages.
    stderrlog::new()
        .module(module_path!())
        .verbosity(usize::from(cli.verbose) + 1)
        .init()
        .context("Failed to initialize logging")?;

    match cli.command {
        Command::InitCA(opts) => opts.run().context("Failed to initialize CA"),
        Command::BlessImage(opts) => opts.run().context("Failed to bless image"),
        Command::BlessUpdate(opts) => opts.run().context("Failed to bless update bundle"),
        Command::CreateEnrollment(opts) => {
            opts.run().context("Failed to create enrollment package")
        }
        Command::CreateSigningKey(opts) => opts.run().context("Failed to create signing key"),
        Command::IssueSigningCertificate(opts) => {
            opts.run().context("Failed to issue signing certificate")
        }
        Command::SignFile(opts) => opts.run().context("Failed to sign file"),
        Command::Verify(opts) => opts.run().context("Failed to verify signatures"),
    }
}
