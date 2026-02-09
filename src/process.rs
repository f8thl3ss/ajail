use std::env;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use nix::sys::wait::{WaitStatus, waitpid};
use nix::unistd::{Pid, chdir, execve};

use crate::sandbox::{self, SandboxConfig};
use crate::worktree::{
    WorktreeInfo, cleanup_worktree, merge_worktree, prompt_worktree_action, show_worktree_diff,
    worktree_has_changes,
};
use crate::{Cli, WorktreeAction};

/// Set up the sandbox namespace and exec claude. Never returns on success.
pub fn run_child(
    sandbox_config: &SandboxConfig,
    cli: &Cli,
    claude_config_dest: &Path,
    claude_path: &Path,
) -> ! {
    if let Err(e) = sandbox::setup_namespace(sandbox_config) {
        eprintln!("Failed to set up sandbox: {e}");
        std::process::exit(1);
    }

    if let Err(e) = chdir(&sandbox_config.project_dir) {
        eprintln!("Failed to chdir to project: {e}");
        std::process::exit(1);
    }

    // Build environment for the child, injecting CLAUDE_CONFIG_DIR if needed.
    // Safety: we're in a forked child process, single-threaded.
    if cli.claude_config_dir.is_some() {
        unsafe { env::set_var("CLAUDE_CONFIG_DIR", claude_config_dest) };
    } else {
        unsafe { env::remove_var("CLAUDE_CONFIG_DIR") };
    }
    let env_vars: Vec<CString> = env::vars_os()
        .map(|(k, v)| {
            let mut pair = k.as_encoded_bytes().to_vec();
            pair.push(b'=');
            pair.extend_from_slice(v.as_encoded_bytes());
            CString::new(pair).expect("environment variable contains NUL byte")
        })
        .collect();

    let cmd =
        CString::new(claude_path.as_os_str().as_bytes()).expect("claude path contains NUL byte");
    let mut args = vec![CString::new("claude").expect("static string")];
    if cli.dangerously_skip_permissions {
        args.push(CString::new("--dangerously-skip-permissions").expect("static string"));
    }
    let Err(e) = execve(&cmd, &args, &env_vars);
    eprintln!("Failed to exec claude: {e}");
    std::process::exit(1);
}

/// Wait for the child process to exit and return its exit code.
pub fn wait_for_child(child: Pid) -> i32 {
    loop {
        match waitpid(child, None) {
            Ok(WaitStatus::Exited(_, code)) => break code,
            Ok(WaitStatus::Signaled(_, sig, _)) => break 128 + sig as i32,
            Ok(_) => continue,
            Err(nix::errno::Errno::EINTR) => continue,
            Err(e) => {
                eprintln!("waitpid error: {e}");
                break 1;
            }
        }
    }
}

/// Handle post-session worktree cleanup (merge, discard, or prompt).
pub fn handle_worktree_cleanup(
    worktree_info: &Option<WorktreeInfo>,
    worktree_action: &WorktreeAction,
) {
    let Some(info) = worktree_info else {
        return;
    };

    if !worktree_has_changes(info) {
        eprintln!("No changes made in worktree.");
        cleanup_worktree(info);
        return;
    }

    eprintln!("\n--- Worktree changes ---");
    show_worktree_diff(info);

    let action = match worktree_action {
        WorktreeAction::Prompt => prompt_worktree_action(),
        a => a.clone(),
    };

    match action {
        WorktreeAction::Merge => {
            if merge_worktree(info) {
                cleanup_worktree(info);
            }
            // If merge failed, don't clean up — user can resolve
        }
        WorktreeAction::Discard | WorktreeAction::Prompt => {
            eprintln!("Discarding worktree changes.");
            cleanup_worktree(info);
        }
    }
}
