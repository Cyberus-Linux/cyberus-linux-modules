use anyhow::{Context, Result};
use clap::Parser;
use crossterm::event::{self, Event, KeyCode};
use ratatui::{
    DefaultTerminal, Frame, layout::{Alignment, Constraint, Direction, HorizontalAlignment::Center, Layout, Rect}, style::{Color, Modifier, Style, Stylize as _}, widgets::{Block, Borders, Clear, Gauge, Paragraph},
};
use std::{
    fs::File,
    io::{Read as _, Write as _},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread::sleep,
    time::Duration,
};

const WRITE_CHUNK_SIZE: usize = 16 << 20;

const THEME_COLOR_FG: Color = Color::Magenta;
const THEME_COLOR_BG: Color = Color::Gray;
const THEME_COLOR_FAILED: Color = Color::Red;

/// Write an image to a target device
#[derive(Parser, Debug)]
#[command(version, about)]
struct Args {
    /// Path to the image file to write
    image: PathBuf,

    /// Target device path to write the image to
    target: PathBuf,
}

#[derive(Debug, Clone, Copy, Default)]
enum TaskStatus {
    #[default]
    NotStarted,
    InProgress(u16),
    Failed,
    Success,
}

impl TaskStatus {
    fn is_terminal(&self) -> bool {
        matches!(self, TaskStatus::Failed | TaskStatus::Success)
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct UiState {
    wiping: TaskStatus,
    writing: TaskStatus,
}

#[derive(Debug, Clone, Default)]
struct AppState {
    ui: UiState,

    error: Option<String>,
}

impl AppState {
    fn is_terminal(&self) -> bool {
        self.error.is_some() || (self.ui.wiping.is_terminal() && self.ui.writing.is_terminal())
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

    fn update_state<F>(&self, f: F)
    where
        F: FnOnce(&mut AppState),
    {
        let mut lock = self.state.lock().unwrap();
        f(&mut lock);
    }
}

impl App {
    pub fn run(&self, terminal: &mut DefaultTerminal) -> Result<()> {
        loop {
            let state = self.current_state();

            terminal.draw(|frame| self.draw(frame, &state))?;

            if state.is_terminal()
                && let Event::Key(key) = event::read()?
                && key.code == KeyCode::Enter
            {
                break;
            }

            sleep(Duration::from_millis(100));
        }

        Ok(())
    }

    fn draw(&self, frame: &mut Frame, state: &AppState) {
        let area = frame.area();
        let main_block = Block::default()
            .title(" Cyberus Linux Deployment ")
            .title_alignment(Center)
            .title_style(Style::default().fg(THEME_COLOR_FG))
            .borders(Borders::ALL)
            .border_style(Style::default().fg(THEME_COLOR_FG));
        let inner_area = main_block.inner(area);

        frame.render_widget(main_block, area);

        let vertical_center = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(0),
                Constraint::Length(6),
                Constraint::Min(0),
            ])
            .split(inner_area)[1];

        let horizontal_center = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Min(0),
                Constraint::Length(80),
                Constraint::Min(0),
            ])
            .split(vertical_center)[1];

        let task_chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(3), Constraint::Length(3)])
            .split(horizontal_center);

        let render_task =
            |frame: &mut Frame, target_area: Rect, label: &str, status: &TaskStatus| {
                let chunks = Layout::default()
                    .direction(Direction::Horizontal)
                    .constraints([Constraint::Length(20), Constraint::Min(0)])
                    .split(target_area);

                let vertical_label = Layout::default()
                    .direction(Direction::Vertical)
                    .constraints([
                        Constraint::Length(1),
                        Constraint::Length(1),
                        Constraint::Length(1),
                    ])
                    .split(chunks[0]);

                frame.render_widget(Paragraph::new(label).style(Style::default().fg(THEME_COLOR_FG)), vertical_label[1]);

                match status {
                    TaskStatus::NotStarted | TaskStatus::Failed | TaskStatus::Success => {
                        let vertical_text = Layout::default()
                            .direction(Direction::Vertical)
                            .constraints([
                                Constraint::Length(1),
                                Constraint::Length(1),
                                Constraint::Length(1),
                            ])
                            .split(chunks[1]);

                        let (text, color) = match status {
                            TaskStatus::NotStarted => ("PENDING", THEME_COLOR_FG),
                            TaskStatus::Failed => ("FAILED", THEME_COLOR_FAILED),
                            TaskStatus::Success => ("OK", THEME_COLOR_FG),
                            _ => unreachable!(),
                        };

                        frame.render_widget(
                            Paragraph::new(text)
                                .style(Style::default().fg(color))
                                .alignment(Alignment::Center),
                            vertical_text[1],
                        );
                    }
                    TaskStatus::InProgress(pct) => {
                        let gauge = Gauge::default()
                            .gauge_style(Style::default().fg(THEME_COLOR_FG).bg(THEME_COLOR_BG))
                            .percent(*pct);
                        frame.render_widget(gauge, chunks[1]);
                    }
                }
            };

        render_task(frame, task_chunks[0], "Wiping partitions", &state.ui.wiping);
        render_task(frame, task_chunks[1], "Writing data", &state.ui.writing);

        fn render_popup(frame: &mut Frame, area: Rect, message: String, color: Color) {
            let vertical_chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Percentage(40),
                    Constraint::Length(10),
                    Constraint::Percentage(40),
                ])
                .split(area);

            let horizontal_chunks = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(25),
                    Constraint::Percentage(50),
                    Constraint::Percentage(25),
                ])
                .split(vertical_chunks[1]);

            let popup_area = horizontal_chunks[1];

            let popup_block = Block::default()
                .borders(Borders::ALL)
                .fg(color)
                .bg(THEME_COLOR_BG);

            let inner_popup_area = popup_block.inner(popup_area);
            let popup_text_vertical_center = Layout::default()
                      .direction(Direction::Vertical)
                      .constraints([
                          Constraint::Min(0),
                          Constraint::Length(5),
                          Constraint::Min(0),
                      ])
                      .split(inner_popup_area)[1];

            let popup_text = Paragraph::new(message)
                .style(Style::default().add_modifier(Modifier::BOLD))
                .alignment(Alignment::Center);

            frame.render_widget(Clear, popup_area);
            frame.render_widget(popup_block, popup_area);
            frame.render_widget(popup_text, popup_text_vertical_center);
        }

        if state.is_terminal() {
            if let Some(error_msg) = &state.error {
                let message = format!("An error occurred. Press ENTER to power down.\n\n{error_msg}");
                render_popup(frame, inner_area, message, THEME_COLOR_FAILED);
            } else {
                let message = String::from("Deployment complete.\n\nPress ENTER to power down.");
                render_popup(frame, inner_area, message, THEME_COLOR_FG);
            }
        }
    }
}

fn wipe_device_bare(device: &Path) -> Result<()> {
    let cmd = std::process::Command::new("wipefs")
        .arg("-a")
        .arg(device)
        .output()
        .context("Failed to execute wipefs")?;
    if !cmd.status.success() {
        let stdout = String::from_utf8_lossy(&cmd.stdout);
        let stderr = String::from_utf8_lossy(&cmd.stderr);
        return Err(anyhow::anyhow!(
            "Failed to wipe device: {}\n{}",
            stdout,
            stderr
        ));
    }

    Ok(())
}

fn wipe_device(state: &App, device: &Path) -> Result<()> {
    state.update_state(|s| s.ui.wiping = TaskStatus::InProgress(0));

    match wipe_device_bare(device) {
        Ok(_) => {
            state.update_state(|s| s.ui.wiping = TaskStatus::Success);
            Ok(())
        }
        Err(e) => {
            state.update_state(|s| s.ui.wiping = TaskStatus::Failed);
            Err(e)
        }
    }
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

        state.update_state(|s| {
            s.ui.writing = TaskStatus::InProgress((bytes_read * 100 / filesize) as u16)
        });
    }

    state.update_state(|s| s.ui.writing = TaskStatus::Success);

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

    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();

    color_eyre::install().expect("Failed to initialize terminal color support");

    let app_state = Arc::new(Mutex::new(AppState::default()));
    let app = App {
        state: app_state.clone(),
    };

    let _join_handle = {
        let app = app.clone();
        let input_file = args.image.clone();
        let output_file = args.target.clone();

        std::thread::spawn(move || {
            if let Err(e) = write_image(&app, &input_file, &output_file) {
                app.update_state(|s| s.error = Some(e.to_string()));
            }
        })
    };

    ratatui::run(|terminal| app.run(terminal))?;

    Ok(())
}
