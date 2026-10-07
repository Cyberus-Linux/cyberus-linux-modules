//! Helpers for external commands.
use std::{io::ErrorKind, path::Path, process::Command};

use anyhow::{Context, Result, bail};

/// Check whether a command can be executed by running it with --version.
///
/// The command may be a path or a bare program name, which is then looked up in PATH. If the command cannot be found,
/// `not_found_hint` is added to the error message to tell the user how to fix it.
pub fn check_command(command: &Path, not_found_hint: &str) -> Result<()> {
    match Command::new(command).arg("--version").output() {
        Ok(output) if output.status.success() => Ok(()),
        Ok(output) => bail!(
            "{} --version failed ({}): {}",
            command.display(),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ),
        Err(err) if err.kind() == ErrorKind::NotFound => {
            bail!("{} was not found. {not_found_hint}", command.display())
        }
        Err(err) => Err(err).with_context(|| format!("Failed to execute {}", command.display())),
    }
}

/// Run a command and fail with its output if it does not succeed.
pub fn run(command: &mut Command) -> Result<()> {
    let program = command.get_program().to_string_lossy().into_owned();
    let output = command
        .output()
        .with_context(|| format!("Failed to execute {program}"))?;

    if !output.status.success() {
        // Tools print their reasons to stdout or stderr, so we include both.
        let message = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        bail!(
            "{program} failed ({}): {}",
            output.status,
            message.trim_end()
        );
    }

    Ok(())
}
