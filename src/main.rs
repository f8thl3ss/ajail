mod config;
mod process;
mod sandbox;
mod util;
mod worktree;

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, ValueEnum};
use nix::unistd::{ForkResult, fork};

use config::{load_config, merge_options};
use process::{handle_worktree_cleanup, run_child, wait_for_child};
use sandbox::SandboxConfig;
use util::{random_hex, repo_root};
use worktree::create_worktree;

// =============================================================================
// CLI
// =============================================================================

#[derive(Clone, Debug, Default, ValueEnum)]
pub enum WorktreeAction {
    /// Merge worktree changes into the original branch
    Merge,
    /// Discard worktree changes
    Discard,
    /// Interactively prompt for merge or discard
    #[default]
    Prompt,
}

/// Run Claude Code in a Linux namespace sandbox
#[derive(Parser)]
#[command(name = "ajail", version, about)]
pub struct Cli {
    /// Allow access to SSH agent socket
    #[arg(long)]
    pub allow_ssh_agent: bool,

    /// Allow access to GPG agent socket
    #[arg(long)]
    pub allow_gpg_agent: bool,

    /// Allow full XDG runtime directory access
    #[arg(long)]
    pub allow_xdg_runtime: bool,

    /// Override Claude config directory (default: ~/.claude, env: CLAUDE_CONFIG_DIR)
    #[arg(long, env = "CLAUDE_CONFIG_DIR")]
    pub claude_config_dir: Option<PathBuf>,

    /// Run Claude in an isolated git worktree
    #[arg(long)]
    pub worktree: bool,

    /// Action after worktree session ends: merge, discard, or prompt (default: prompt)
    #[arg(long, default_value = "prompt")]
    pub worktree_action: WorktreeAction,

    /// Pass --dangerously-skip-permissions to Claude
    #[arg(long)]
    pub dangerously_skip_permissions: bool,
}

// =============================================================================
// Main
// =============================================================================

fn main() -> ExitCode {
    let cli = Cli::parse();
    let config = load_config();
    let options = merge_options(&cli, &config);

    let project_dir = env::current_dir().expect("Failed to get current directory");
    let repo_root = repo_root(&project_dir);
    let session_id = random_hex(8);

    let home = PathBuf::from(env::var("HOME").expect("HOME not set"));
    let claude_home = env::temp_dir().join(format!("ajail-{session_id}"));
    fs::create_dir_all(&claude_home).expect("Failed to create temp home");

    let claude_config = cli
        .claude_config_dir
        .clone()
        .unwrap_or_else(|| home.join(".claude"));
    fs::create_dir_all(&claude_config).ok();
    let claude_json = home.join(".claude.json");

    // Smart filesystem sharing: if repo is under $HOME, share the top-level subdir
    let real_repo_root = fs::canonicalize(&repo_root).unwrap_or_else(|_| repo_root.clone());
    let real_home = fs::canonicalize(&home).unwrap_or_else(|_| home.clone());

    let share_tree = if real_repo_root.starts_with(&real_home) {
        let rel = real_repo_root
            .strip_prefix(&real_home)
            .expect("repo is under home")
            .to_path_buf();
        let top_dir = rel
            .components()
            .next()
            .expect("repo has at least one component");
        real_home.join(top_dir)
    } else {
        real_repo_root.clone()
    };

    // If a custom config dir was specified, mount it at the same path inside the sandbox.
    // Otherwise, use the default ~/.claude location.
    let claude_config_dest = if cli.claude_config_dir.is_some() {
        claude_config.clone()
    } else {
        home.join(".claude")
    };

    // Worktree: create an isolated worktree for Claude to work in
    let worktree_info = if options.worktree {
        match create_worktree(&real_repo_root, &session_id) {
            Ok(info) => {
                eprintln!(
                    "Created worktree at {} (branch: {})",
                    info.worktree_path.display(),
                    info.branch_name
                );
                Some(info)
            }
            Err(e) => {
                eprintln!("Failed to create worktree: {e}");
                return ExitCode::FAILURE;
            }
        }
    } else {
        None
    };

    // If using a worktree, sandbox operates on the worktree path instead
    let (sandbox_repo_root, sandbox_project_dir, sandbox_share_tree) =
        if let Some(ref wt) = worktree_info {
            let wt_root =
                fs::canonicalize(&wt.worktree_path).unwrap_or_else(|_| wt.worktree_path.clone());
            let wt_share = wt_root.clone();
            (wt_root.clone(), wt_root, wt_share)
        } else {
            (real_repo_root.clone(), project_dir.clone(), share_tree)
        };

    // When using worktrees, the worktree's .git file references the original repo's
    // .git/worktrees/<name> dir, so we need to make the original .git accessible.
    let original_git_dir = worktree_info.as_ref().map(|_| real_repo_root.join(".git"));

    // Resolve claude path before fork — after namespace setup, $HOME is overlaid
    // with tmpfs and paths under it (like ~/.nix-profile/bin) become invisible.
    // Canonicalize to follow symlinks (e.g. nix profile symlinks to /nix/store).
    let claude_path = which::which("claude")
        .map(|p| fs::canonicalize(&p).unwrap_or(p))
        .unwrap_or_else(|_| {
            eprintln!("claude not found in PATH");
            std::process::exit(1);
        });

    let sandbox_config = SandboxConfig {
        home: home.clone(),
        claude_config,
        claude_config_dest: claude_config_dest.clone(),
        claude_json,
        share_tree: sandbox_share_tree,
        repo_root: sandbox_repo_root,
        project_dir: sandbox_project_dir,
        original_git_dir,
        claude_path: claude_path.clone(),
        options,
    };

    // Fork: child sets up namespace and execs claude, parent waits
    match unsafe { fork() } {
        Ok(ForkResult::Child) => {
            run_child(&sandbox_config, &cli, &claude_config_dest, &claude_path);
        }
        Ok(ForkResult::Parent { child }) => {
            let exit_code = wait_for_child(child);
            handle_worktree_cleanup(&worktree_info, &cli.worktree_action);
            let _ = fs::remove_dir_all(&claude_home);
            ExitCode::from(exit_code as u8)
        }
        Err(e) => {
            eprintln!("Fork failed: {e}");
            handle_worktree_cleanup(&worktree_info, &cli.worktree_action);
            let _ = fs::remove_dir_all(&claude_home);
            ExitCode::FAILURE
        }
    }
}
