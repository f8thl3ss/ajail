use std::env;
use std::fs;
use std::path::PathBuf;

use serde::Deserialize;

use crate::Cli;

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default)]
    pub allow_ssh_agent: bool,
    #[serde(default)]
    pub allow_gpg_agent: bool,
    #[serde(default)]
    pub allow_xdg_runtime: bool,
    #[serde(default)]
    pub allow_docker: bool,
    #[serde(default)]
    pub allow_dangerous_writes: bool,
    #[serde(default)]
    pub allow_unix_sockets: bool,
    #[serde(default)]
    pub worktree: bool,
    #[serde(default)]
    pub command: Option<String>,
}

fn config_path() -> PathBuf {
    let xdg_config = env::var("XDG_CONFIG_HOME")
        .unwrap_or_else(|_| format!("{}/.config", env::var("HOME").unwrap_or_default()));
    PathBuf::from(xdg_config).join("ajail").join("config.json")
}

pub fn load_config() -> Config {
    let path = config_path();
    let content = match fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Config::default(),
        Err(e) => {
            eprintln!(
                "Warning: Failed to load config from {}: {e}",
                path.display()
            );
            return Config::default();
        }
    };
    match serde_json::from_str(&content) {
        Ok(c) => c,
        Err(e) => {
            eprintln!(
                "Warning: Failed to parse config from {}: {e}",
                path.display()
            );
            Config::default()
        }
    }
}

/// Merged CLI flags (override) with config file (defaults).
pub struct Options {
    pub allow_ssh_agent: bool,
    pub allow_gpg_agent: bool,
    pub allow_xdg_runtime: bool,
    pub allow_docker: bool,
    pub allow_dangerous_writes: bool,
    pub allow_unix_sockets: bool,
    pub worktree: bool,
    pub command: String,
}

pub fn merge_options(cli: &Cli, config: &Config) -> Options {
    Options {
        allow_ssh_agent: cli.allow_ssh_agent || config.allow_ssh_agent,
        allow_gpg_agent: cli.allow_gpg_agent || config.allow_gpg_agent,
        allow_xdg_runtime: cli.allow_xdg_runtime || config.allow_xdg_runtime,
        allow_docker: cli.allow_docker || config.allow_docker,
        allow_dangerous_writes: cli.allow_dangerous_writes || config.allow_dangerous_writes,
        allow_unix_sockets: cli.allow_unix_sockets || config.allow_unix_sockets,
        worktree: cli.worktree || config.worktree,
        command: cli
            .command
            .clone()
            .or_else(|| config.command.clone())
            .unwrap_or_else(|| "claude".to_string()),
    }
}
