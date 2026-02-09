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
    pub worktree: bool,
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
    pub worktree: bool,
}

pub fn merge_options(cli: &Cli, config: &Config) -> Options {
    Options {
        allow_ssh_agent: cli.allow_ssh_agent || config.allow_ssh_agent,
        allow_gpg_agent: cli.allow_gpg_agent || config.allow_gpg_agent,
        allow_xdg_runtime: cli.allow_xdg_runtime || config.allow_xdg_runtime,
        worktree: cli.worktree || config.worktree,
    }
}
