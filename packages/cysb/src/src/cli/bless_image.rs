use std::{
    io::{Seek, SeekFrom},
    path::PathBuf,
};

use anyhow::{Context, Result};
use clap::Args;
use fatfs::{FileSystem, FsOptions, ReadWriteSeek};
use fscommon::StreamSlice;
use log::{debug, info};
use uuid::Uuid;

use super::sign_file::SignOpts;

/// Sign UEFI binaries on a disk partition.
#[derive(Debug, Args)]
pub struct Opts {
    /// A disk image to bless.
    ///
    /// This must be a GPT-partitioned disk image with a ESP. This command will modify it in-place. systemd-boot and any
    /// UKI will be signed.
    #[arg(required = true)]
    disk_image: PathBuf,

    #[command(flatten)]
    sign_opts: SignOpts,
}

fn is_esp(uuid: &Uuid) -> bool {
    // Well known type for the EFI System Partition. See:
    // https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
    //
    // FIXME It's needlessly inefficient to construct this value on every call, but then performance doesn't matter
    // here.
    uuid == &Uuid::parse_str("c12a7328-f81f-11d2-ba4b-00a0c93ec93b").unwrap()
}

impl Opts {
    // Sign the file on the ESP and write it back.
    fn sign_file_on_esp<T>(&self, root: &fatfs::Dir<T>, file_path: &str) -> Result<()>
    where
        T: ReadWriteSeek,
    {
        let mut file_on_esp = root
            .open_file(file_path)
            .context("Failed to open {file_path} on ESP")?;

        let mut temp_file_in = tempfile::NamedTempFile::new()?;
        let temp_file_out = tempfile::NamedTempFile::new()?;

        std::io::copy(&mut file_on_esp, &mut temp_file_in)
            .context("Failed to copy file to temporary file")?;

        let in_path = temp_file_in.into_temp_path();
        let out_path = temp_file_out.into_temp_path();

        self.sign_opts.sign_file(&in_path, &out_path)?;

        file_on_esp
            .seek(SeekFrom::Start(0))
            .context("Failed to rewind to start of file")?;
        file_on_esp.truncate().context("Failed to truncate file")?;

        debug!("Truncated file on FAT.");

        let mut out_file =
            std::fs::File::open(&out_path).context("Failed to open signed binary")?;

        std::io::copy(&mut out_file, &mut file_on_esp)
            .context("Failed to copy signed binary to ESP")?;

        info!("Written signed version back to ESP.");

        Ok(())
    }

    pub fn run(&self) -> Result<()> {
        self.sign_opts.check_tools()?;

        let disk = gpt::GptConfig::new()
            .writable(true)
            .open(&self.disk_image)
            .context("Failed to open disk image")?;

        let esp = disk
            .partitions()
            .values()
            .find(|p| is_esp(&p.part_type_guid.guid))
            .context("Failed to find ESP")?;

        let byte_start = esp.bytes_start(*disk.logical_block_size())?;
        let byte_len = esp.bytes_len(*disk.logical_block_size())?;

        info!(
            "Found {} MiB ESP starting at {} MiB with name: {}",
            byte_len >> 20,
            byte_start,
            esp.name
        );

        let disk_file = disk.take_device();
        let partition = StreamSlice::new(disk_file, byte_start, byte_len)?;

        let fs = FileSystem::new(partition, FsOptions::new())
            .context("Failed to open ESP filesystem")?;
        debug!("Opened ESP file system.");

        let root = fs.root_dir();

        self.sign_file_on_esp(&root, "EFI/BOOT/BOOTX64.EFI")
            .context("Failed to sign boot loader")?;

        let uki_dir = root
            .open_dir("/EFI/Linux")
            .context("Failed to open /EFI/Linux on ESP")?;
        let ukis = uki_dir
            .iter()
            .filter_map(|entry| -> Option<String> {
                let entry = entry.expect("valid DirEntry");
                if !entry.is_file() {
                    return None;
                }

                Some(entry.file_name())
            })
            .collect::<Vec<String>>();

        debug!("Found UKIs: {ukis:?}");

        for uki in ukis {
            info!("Signing {uki}...");

            self.sign_file_on_esp(&uki_dir, uki.as_ref())
                .context("Failed to sign UKI")?;
        }

        Ok(())
    }
}
