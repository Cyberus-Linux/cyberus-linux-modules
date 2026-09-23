use anyhow::{Context, Result};
use clap::Parser;
use crossterm::event::{self, Event, KeyCode};
use ratatui::{
    DefaultTerminal, Frame,
    layout::{Alignment, Constraint, Layout},
    widgets::{Block, Borders, Gauge, Paragraph},
};
use std::{
    fs::File, io::{Read as _, Write as _}, os::unix::fs::OpenOptionsExt, path::{Path, PathBuf}, sync::{Arc, Mutex}, thread::sleep, time::Duration,
};

const WRITE_CHUNK_SIZE: usize = 16 << 20;

/// Write an image to a target device
#[derive(Parser, Debug)]
#[command(version, about)]
struct Args {
    /// Path to the image file to write
    image: PathBuf,

    /// Target device path to write the image to
    target: PathBuf,
}

#[derive(Debug, Clone)]
enum AppState {
    Wiping,
    Writing(u16),
    Failure(String),
    Done,
}

impl AppState {
    fn is_terminal(&self) -> bool {
        matches!(self, AppState::Done | AppState::Failure(_))
    }
}

#[derive(Debug, Clone)]
struct App {
    state: Arc<Mutex<AppState>>,
}

impl App {
    fn current_state(&self) -> AppState {
        let state = self.state.lock().unwrap();
        state.clone()
    }

    fn set_state(&self, state: AppState) {
        let mut lock = self.state.lock().unwrap();
        *lock = state;
    }
}

impl App {
    pub fn run(&self, terminal: &mut DefaultTerminal) -> Result<()> {
        loop {
            let state = self.current_state();

            terminal.draw(|frame| self.draw(frame, &state))?;

            if state.is_terminal()
                && let Event::Key(key) = event::read()?
                    && key.code == KeyCode::Enter {
                        break;
                    }

            sleep(Duration::from_millis(100));
        }

        Ok(())
    }

    fn draw(&self, frame: &mut Frame, state: &AppState) {
        let area = frame.area();

        let vertical_layout = Layout::vertical([
            Constraint::Percentage(40),
            Constraint::Length(6),
            Constraint::Percentage(40),
        ])
        .split(area);

        let center_area = Layout::horizontal([
            Constraint::Percentage(20),
            Constraint::Percentage(60),
            Constraint::Percentage(20),
        ])
        .split(vertical_layout[1])[1];

        let bottom_area =
            Layout::vertical([Constraint::Min(0), Constraint::Length(2)]).split(area)[1];

        match state {
            AppState::Wiping => {
                let widget = Paragraph::new("Wiping old partition tables from device...")
                    .alignment(Alignment::Center);
                frame.render_widget(widget, center_area);
            }
            AppState::Writing(progress) => {
                let widget = Gauge::default()
                    .block(
                        Block::default()
                            .title("Writing Image to Disk")
                            .borders(Borders::ALL),
                    )
                    .percent(*progress);

                frame.render_widget(widget, center_area);
            }
            AppState::Failure(reason) => {
                let widget = Paragraph::new(format!(
                    "Failed to write image. Press ENTER to power down.\n{reason}"
                ))
                .alignment(Alignment::Center);

                frame.render_widget(widget, center_area);
            }
            AppState::Done => {
                let widget = Paragraph::new(
                    "Everything done! Press ENTER to power down.\nThen remove the installation media and reboot.",
                )
                .alignment(Alignment::Center);

                frame.render_widget(widget, center_area);
            }
        };
        let text_block =
            Paragraph::new("Cyberus Linux Image Deployment").alignment(Alignment::Left);

        frame.render_widget(text_block, bottom_area);
    }
}

fn wipe_device(state: &App, device: &Path) -> Result<()> {
    state.set_state(AppState::Wiping);
    let cmd = std::process::Command::new("wipefs")
        .arg("-a").arg(device).output().context("Failed to execute wipefs")?;
    if !cmd.status.success() {
        let stdout = String::from_utf8_lossy(&cmd.stdout);
        let stderr = String::from_utf8_lossy(&cmd.stderr);
        return Err(anyhow::anyhow!("Failed to wipe device: {}\n{}", stdout, stderr));
    }

    // The wipe is pretty much instantaneous, so give the user time to see what happens.
    sleep(Duration::from_secs(3));

    Ok(())
}

fn write_data(state: &App, input: &mut File, output: &mut File) -> Result<()> {
    let mut buf = vec![0; WRITE_CHUNK_SIZE];

    let filesize: u64 = input
        .metadata()
        .context("Failed to get input file size")?
        .len();
    let mut bytes_read: u64 = 0;

    while bytes_read < filesize {
        let read = input
            .read(&mut buf)
            .context("Failed to read from input file")?;
        output
            .write_all(&buf[..read])
            .context("Failed to write to output file")?;

        bytes_read += read as u64;
        state.set_state(AppState::Writing((bytes_read * 100 / filesize) as u16));
    }

    Ok(())
}

fn write_image(state: &App, input_file: &Path, output_file: &Path) -> Result<()> {
    wipe_device(state, output_file)?;

    let mut input_file = std::fs::File::open(input_file).context("Failed to open input file")?;
    let mut output_file = std::fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .create(true)
        .custom_flags(libc::O_DSYNC) // Be sure we write synchronously.
        .open(output_file)
        .context("Failed to open output file")?;

    write_data(state, &mut input_file, &mut output_file)?;

    state.set_state(AppState::Done);

    Ok(())

}

fn main() -> Result<()> {
    let args = Args::parse();

    color_eyre::install().expect("Failed to initialize terminal color support");

    let app_state = Arc::new(Mutex::new(AppState::Wiping));
    let app = App {
        state: app_state.clone(),
    };

    let _join_handle = {
        let app = app.clone();
        let input_file = args.image.clone();
        let output_file = args.target.clone();

        std::thread::spawn(move || {
            if let Err(e) = write_image(&app, &input_file, &output_file) {
                app.set_state(AppState::Failure(e.to_string()));
            }
        })
    };

    ratatui::run(|terminal| app.run(terminal))?;

    Ok(())
}
