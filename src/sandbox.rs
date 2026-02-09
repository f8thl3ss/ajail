use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use nix::mount::{MsFlags, mount};
use nix::sched::{CloneFlags, unshare};
use nix::unistd::{getgid, getuid};

use crate::config::Options;

pub struct SandboxConfig {
    pub home: PathBuf,
    pub claude_config: PathBuf,
    /// Where claude_config should appear inside the sandbox
    pub claude_config_dest: PathBuf,
    pub claude_json: PathBuf,
    pub share_tree: PathBuf,
    pub repo_root: PathBuf,
    pub project_dir: PathBuf,
    /// When using worktrees, the original repo's .git dir must be accessible
    /// so the worktree's .git file can reference it.
    pub original_git_dir: Option<PathBuf>,
    pub options: Options,
}

/// Bind-mount `src` onto `dst`. Creates `dst` if needed.
/// If `readonly` is true, remounts read-only afterward.
fn bind_mount(src: &Path, dst: &Path, readonly: bool) -> nix::Result<()> {
    if !dst.exists() {
        if src.is_dir() {
            fs::create_dir_all(dst).ok();
        } else {
            if let Some(parent) = dst.parent() {
                fs::create_dir_all(parent).ok();
            }
            fs::write(dst, b"").ok();
        }
    }

    mount(
        Some(src),
        dst,
        None::<&str>,
        MsFlags::MS_BIND | MsFlags::MS_REC,
        None::<&str>,
    )?;

    if readonly {
        mount(
            None::<&str>,
            dst,
            None::<&str>,
            MsFlags::MS_BIND | MsFlags::MS_REC | MsFlags::MS_REMOUNT | MsFlags::MS_RDONLY,
            None::<&str>,
        )?;
    }

    Ok(())
}

/// Mount a tmpfs at `dst`.
fn mount_tmpfs(dst: &Path) -> nix::Result<()> {
    fs::create_dir_all(dst).ok();
    mount(
        Some("tmpfs"),
        dst,
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        None::<&str>,
    )
}

/// Create new user and mount namespaces, write UID/GID mappings,
/// and make all mounts private.
fn init_namespaces() -> nix::Result<()> {
    let uid = getuid();
    let gid = getgid();

    unshare(CloneFlags::CLONE_NEWUSER | CloneFlags::CLONE_NEWNS)?;

    fs::write("/proc/self/setgroups", "deny").ok();
    fs::write("/proc/self/uid_map", format!("{uid} {uid} 1\n"))
        .map_err(|e| nix::errno::Errno::from_raw(e.raw_os_error().unwrap_or(1)))?;
    fs::write("/proc/self/gid_map", format!("{gid} {gid} 1\n"))
        .map_err(|e| nix::errno::Errno::from_raw(e.raw_os_error().unwrap_or(1)))?;

    mount(
        None::<&str>,
        "/",
        None::<&str>,
        MsFlags::MS_SLAVE | MsFlags::MS_REC,
        None::<&str>,
    )
}

/// Collect $PATH directories under $HOME that need preserving.
///
/// Returns two lists:
/// - `outside`: (original_path, real_path) for symlinks under $HOME that resolve outside it
///   (e.g. nix profile -> /nix/store). These can be bind-mounted directly after the overlay.
/// - `under_home`: original paths for real directories under $HOME that need staging.
fn collect_home_path_dirs(home: &Path) -> (Vec<(PathBuf, PathBuf)>, Vec<PathBuf>) {
    let mut outside: Vec<(PathBuf, PathBuf)> = Vec::new();
    let mut under_home: Vec<PathBuf> = Vec::new();
    let path_var = env::var_os("PATH").unwrap_or_default();

    for p in env::split_paths(&path_var) {
        if !p.starts_with(home) || !p.exists() {
            continue;
        }
        let real = match fs::canonicalize(&p) {
            Ok(r) => r,
            Err(_) => continue,
        };
        if real.starts_with(home) {
            under_home.push(p);
        } else {
            outside.push((p, real));
        }
    }

    (outside, under_home)
}

/// Stage paths under $HOME to a tmpfs, overlay $HOME with tmpfs,
/// then restore the staged paths into the new home.
///
/// - `path_dirs_outside`: symlinks under $HOME resolving outside (original, real).
/// - `path_dirs_under_home`: real directories under $HOME that need staging.
fn isolate_home(
    config: &SandboxConfig,
    path_dirs_outside: &[(PathBuf, PathBuf)],
    path_dirs_under_home: &[PathBuf],
) -> nix::Result<()> {
    let staging = Path::new("/tmp/.ajail-staging");
    fs::create_dir_all(staging).ok();
    mount_tmpfs(staging)?;

    let stage_claude_config = staging.join("claude-config");
    let stage_claude_json = staging.join("claude-json");
    let stage_repo = staging.join("repo");
    let stage_share_tree = staging.join("share-tree");
    let stage_git_dir = staging.join("git-dir");

    let tmp_path = Path::new("/tmp");

    // Classify path locations once
    let config_under_home = config.claude_config.starts_with(&config.home);
    let repo_under_home = config.repo_root.starts_with(&config.home);
    let repo_under_tmp = !repo_under_home && config.repo_root.starts_with(tmp_path);
    let need_share_tree = config.share_tree != config.repo_root;
    let share_tree_under_home = need_share_tree && config.share_tree.starts_with(&config.home);
    let share_tree_under_tmp =
        need_share_tree && !share_tree_under_home && config.share_tree.starts_with(tmp_path);
    let git_dir_under_home = config
        .original_git_dir
        .as_ref()
        .is_some_and(|d| d.starts_with(&config.home));

    // Stage paths that live under $HOME (they'll disappear after the tmpfs overlay)
    let staged_config = config_under_home && config.claude_config.exists();
    if staged_config {
        bind_mount(&config.claude_config, &stage_claude_config, false)?;
    }

    let staged_json = config.claude_json.exists();
    if staged_json {
        bind_mount(&config.claude_json, &stage_claude_json, false)?;
    }

    if repo_under_home {
        bind_mount(&config.repo_root, &stage_repo, false)?;
    }

    let staged_git_dir = if let Some(ref git_dir) = config.original_git_dir {
        git_dir_under_home && git_dir.exists()
    } else {
        false
    };
    if staged_git_dir {
        bind_mount(
            config.original_git_dir.as_ref().expect("checked above"),
            &stage_git_dir,
            false,
        )?;
    }

    if share_tree_under_home {
        bind_mount(&config.share_tree, &stage_share_tree, true)?;
    }

    // Build staging paths for PATH dirs under $HOME
    let path_dirs_staged: Vec<(&PathBuf, PathBuf)> = path_dirs_under_home
        .iter()
        .enumerate()
        .map(|(i, p)| (p, staging.join(format!("path-{i}"))))
        .collect();

    for (original, stage) in &path_dirs_staged {
        bind_mount(original, stage, true)?;
    }

    // Mount tmpfs over $HOME to hide real home
    mount_tmpfs(&config.home)?;

    // Restore staged paths into the new home
    if staged_config {
        bind_mount(&stage_claude_config, &config.claude_config_dest, false)?;
    } else if !config_under_home && config.claude_config.exists() {
        bind_mount(&config.claude_config, &config.claude_config_dest, false)?;
    }

    if staged_json {
        bind_mount(&stage_claude_json, &config.home.join(".claude.json"), false)?;
    }

    // Restore $PATH directories under $HOME.
    // Use read-write mounts: sources may already be on a read-only filesystem
    // (e.g. /nix/store), and remounting read-only in a user namespace can EPERM.
    for (original, real) in path_dirs_outside {
        bind_mount(real, original, false)?;
    }
    for (original, stage) in &path_dirs_staged {
        bind_mount(stage, original, false)?;
    }

    if need_share_tree && share_tree_under_home {
        bind_mount(&stage_share_tree, &config.share_tree, true)?;
    } else if need_share_tree && !share_tree_under_tmp {
        bind_mount(&config.share_tree, &config.share_tree, true)?;
    }

    if repo_under_home {
        bind_mount(&stage_repo, &config.repo_root, false)?;
    } else if !repo_under_tmp {
        bind_mount(&config.repo_root, &config.repo_root, false)?;
    }

    if let Some(ref git_dir) = config.original_git_dir {
        if staged_git_dir {
            bind_mount(&stage_git_dir, git_dir, false)?;
        } else if !git_dir_under_home && git_dir.exists() {
            bind_mount(git_dir, git_dir, false)?;
        }
    }

    Ok(())
}

/// Overlay /tmp with tmpfs. If the repo or share_tree live under /tmp,
/// stage them to $HOME first, overlay, then restore.
fn isolate_tmp(config: &SandboxConfig) -> nix::Result<()> {
    let tmp_path = Path::new("/tmp");
    let repo_under_home = config.repo_root.starts_with(&config.home);
    let repo_under_tmp = !repo_under_home && config.repo_root.starts_with(tmp_path);
    let need_share_tree = config.share_tree != config.repo_root;
    let share_tree_under_home = need_share_tree && config.share_tree.starts_with(&config.home);
    let share_tree_under_tmp =
        need_share_tree && !share_tree_under_home && config.share_tree.starts_with(tmp_path);

    if repo_under_tmp || share_tree_under_tmp {
        let staging2 = config.home.join(".ajail-staging");
        fs::create_dir_all(&staging2).ok();
        let stage2_repo = staging2.join("repo");
        let stage2_share_tree = staging2.join("share-tree");

        if repo_under_tmp {
            bind_mount(&config.repo_root, &stage2_repo, false)?;
        }
        if share_tree_under_tmp {
            bind_mount(&config.share_tree, &stage2_share_tree, true)?;
        }

        mount_tmpfs(tmp_path)?;

        if share_tree_under_tmp {
            bind_mount(&stage2_share_tree, &config.share_tree, true)?;
        }
        if repo_under_tmp {
            bind_mount(&stage2_repo, &config.repo_root, false)?;
        }

        // Clean up staging
        if repo_under_tmp {
            nix::mount::umount(&stage2_repo).ok();
        }
        if share_tree_under_tmp {
            nix::mount::umount(&stage2_share_tree).ok();
        }
        fs::remove_dir_all(&staging2).ok();
    } else {
        mount_tmpfs(tmp_path)?;
    }

    Ok(())
}

/// Bind-mount agent sockets (SSH, GPG) or the full XDG runtime directory.
fn mount_agent_sockets(options: &Options) -> nix::Result<()> {
    let uid = getuid();
    let xdg_runtime_dir = env::var("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(format!("/run/user/{uid}")));

    if options.allow_xdg_runtime {
        if xdg_runtime_dir.is_dir() {
            bind_mount(&xdg_runtime_dir, &xdg_runtime_dir, true)?;
        }
    } else {
        if options.allow_ssh_agent
            && let Ok(sock) = env::var("SSH_AUTH_SOCK")
        {
            let sock = PathBuf::from(sock);
            if sock.exists() {
                bind_mount(&sock, &sock, false)?;
            }
        }

        if options.allow_gpg_agent {
            let gpg_dir = xdg_runtime_dir.join("gnupg");
            if gpg_dir.is_dir() {
                bind_mount(&gpg_dir, &gpg_dir, false)?;
            }
        }
    }

    Ok(())
}

pub fn setup_namespace(config: &SandboxConfig) -> nix::Result<()> {
    init_namespaces()?;

    let (path_dirs_outside, path_dirs_under_home) = collect_home_path_dirs(&config.home);

    isolate_home(config, &path_dirs_outside, &path_dirs_under_home)?;
    isolate_tmp(config)?;
    mount_agent_sockets(&config.options)?;

    Ok(())
}
