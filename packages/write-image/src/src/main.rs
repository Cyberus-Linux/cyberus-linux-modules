use anyhow::{Context, Result};
use clap::Parser;
use crossterm::event::{self, Event, KeyCode};
use ratatui::{
    DefaultTerminal, Frame,
    layout::{Alignment, Constraint, Layout},
    widgets::{Block, Borders, Gauge, Paragraph},
};
use std::{
    fs::File,
    io::{Read as _, Write as _},
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    sync::{Arc, Mutex},
    thread::sleep,
    time::Duration,
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
    Writing(u16),
    Failure(String),
    Done,
}

impl AppState {
    fn is_terminal(&self) -> bool {
        matches!(self, AppState::Done | AppState::Failure(_))
    }
}

#[derive(Debug)]
struct App {
    state: Arc<Mutex<AppState>>,
}

impl App {
    fn current_state(&self) -> AppState {
        let state = self.state.lock().unwrap();
        state.clone()
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
            Constraint::Length(3),
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

fn write_data(state: Arc<Mutex<AppState>>, input: &mut File, output: &mut File) -> Result<()> {
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
        {
            let mut lock = state.lock().unwrap();
            *lock = AppState::Writing((bytes_read * 100 / filesize) as u16);
        }
    }

    {
        let mut lock = state.lock().unwrap();
        *lock = AppState::Done;
    }

    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();

    color_eyre::install().expect("Failed to initialize terminal color support");

    let app_state = Arc::new(Mutex::new(AppState::Writing(0)));
    let app = App {
        state: app_state.clone(),
    };

    let input_file = std::fs::File::open(&args.image).context("Failed to open input file")?;
    let output_file = std::fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .create(true)
        .custom_flags(libc::O_DSYNC) // Be sure we write synchronously.
        .open(&args.target)
        .context("Failed to open output file")?;

    let _join_handle = {
        let state = app_state.clone();
        let mut input_file = input_file;
        let mut output_file = output_file;

        std::thread::spawn(move || {
            if let Err(e) = write_data(state.clone(), &mut input_file, &mut output_file) {
                let mut lock = state.lock().unwrap();
                *lock = AppState::Failure(e.to_string());
            }
        })
    };

    ratatui::run(|terminal| app.run(terminal))?;

    Ok(())
}
