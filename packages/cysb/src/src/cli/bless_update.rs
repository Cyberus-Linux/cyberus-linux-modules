use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, ensure};
use clap::Args;
use log::info;
use tempfile::NamedTempFile;

use super::sign_file::SignOpts;

/// Sign UEFI binaries in an update bundle.
#[derive(Debug, Args)]
pub struct Opts {
    /// A directory containing an update bundle to bless.
    ///
    /// The command will modify the update bundle in-place.
    #[arg(required = true)]
    update_directory: PathBuf,

    #[command(flatten)]
    sign_opts: SignOpts,
}

impl Opts {
    /// Find the UKIs in the update bundle, i.e. all .efi files.
    fn find_ukis(&self) -> Result<Vec<PathBuf>> {
        fs::read_dir(&self.update_directory)
            .with_context(|| format!("Failed to read {}", self.update_directory.display()))?
            .map(|entry| Ok(entry?.path()))
            .filter(|path| {
                path.as_ref().map_or(true, |path: &PathBuf| {
                    path.is_file() && path.extension().is_some_and(|extension| extension == "efi")
                })
            })
            .collect()
    }

    /// Sign a UKI in-place.
    fn sign_uki(&self, uki: &Path) -> Result<()> {
        info!("Signing {}...", uki.display());

        // Sign into a temporary file next to the UKI and then atomically replace the UKI with it when signing
        // succeeded.
        let signed = NamedTempFile::new_in(&self.update_directory)
            .with_context(|| {
                format!(
                    "Failed to create temporary file in {}",
                    self.update_directory.display()
                )
            })?
            .into_temp_path();

        self.sign_opts.sign_file(uki, &signed)?;

        signed
            .persist(uki)
            .with_context(|| format!("Failed to replace {} with signed UKI", uki.display()))?;

        info!("Signed {}.", uki.display());

        Ok(())
    }

    pub fn run(&self) -> Result<()> {
        self.sign_opts.check_tools()?;

        let ukis = self.find_ukis()?;
        ensure!(
            !ukis.is_empty(),
            "No .efi file found in {}",
            self.update_directory.display()
        );

        ukis.iter().try_for_each(|uki| self.sign_uki(uki))
    }
}
