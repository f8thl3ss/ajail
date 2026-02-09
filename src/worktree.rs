use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use git2::{BranchType, DiffStatsFormat, Oid, Repository};

use crate::WorktreeAction;
use std::env;

pub struct WorktreeInfo {
    pub worktree_path: PathBuf,
    pub branch_name: String,
    pub original_head: String,
    pub original_repo: PathBuf,
}

pub fn create_worktree(repo_root: &Path, session_id: &str) -> Result<WorktreeInfo, String> {
    let repo = Repository::open(repo_root).map_err(|e| format!("Failed to open repo: {e}"))?;

    let head = repo
        .head()
        .map_err(|_| "Failed to get HEAD. Is this a git repo with at least one commit?")?;
    let original_head = head
        .target()
        .ok_or("HEAD is not a direct reference")?
        .to_string();

    let branch_name = format!("ajail-{session_id}");
    let worktree_path = env::temp_dir().join(format!("ajail-worktree-{session_id}"));

    // git2-rs doesn't expose worktree_add, so shell out for this
    let output = Command::new("git")
        .args([
            "worktree",
            "add",
            "-b",
            &branch_name,
            worktree_path.to_str().unwrap(),
            &original_head,
        ])
        .current_dir(repo_root)
        .output()
        .map_err(|e| format!("Failed to create worktree: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "git worktree add failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(WorktreeInfo {
        worktree_path,
        branch_name,
        original_head,
        original_repo: repo_root.to_path_buf(),
    })
}

pub fn worktree_has_changes(info: &WorktreeInfo) -> bool {
    let repo = match Repository::open(&info.worktree_path) {
        Ok(r) => r,
        Err(_) => return false,
    };

    // Check if HEAD has moved beyond original
    let current_head = repo
        .head()
        .ok()
        .and_then(|h| h.target())
        .map(|oid| oid.to_string())
        .unwrap_or_default();

    if current_head != info.original_head {
        return true;
    }

    // Check for uncommitted changes
    repo.statuses(None).map(|s| !s.is_empty()).unwrap_or(false)
}

pub fn show_worktree_diff(info: &WorktreeInfo) {
    let repo = match Repository::open(&info.worktree_path) {
        Ok(r) => r,
        Err(_) => return,
    };

    let original_oid = match Oid::from_str(&info.original_head) {
        Ok(oid) => oid,
        Err(_) => return,
    };

    // Show commits: equivalent of `git log --oneline <original>..HEAD`
    if let Ok(mut revwalk) = repo.revwalk() {
        revwalk.set_sorting(git2::Sort::REVERSE).ok();
        if revwalk.push_range(&format!("{original_oid}..HEAD")).is_ok() {
            for oid in revwalk.flatten() {
                if let Ok(commit) = repo.find_commit(oid) {
                    let short = &commit.id().to_string()[..7];
                    let summary = commit.summary().unwrap_or("");
                    eprintln!("{short} {summary}");
                }
            }
        }
    }

    // Show diff stats: equivalent of `git diff --stat <original>`
    if let Ok(original_commit) = repo.find_commit(original_oid)
        && let Ok(original_tree) = original_commit.tree()
        && let Ok(diff) = repo.diff_tree_to_workdir_with_index(Some(&original_tree), None)
        && let Ok(stats) = diff.stats()
        && let Ok(buf) = stats.to_buf(DiffStatsFormat::FULL, 80)
    {
        eprint!("{}", buf.as_str().unwrap_or(""));
    }
}

pub fn prompt_worktree_action() -> WorktreeAction {
    use std::io::{BufRead, Write};

    // Read from /dev/tty for interactive input (terminal may have been used by claude)
    let tty = match fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
    {
        Ok(f) => f,
        Err(_) => {
            eprintln!("Cannot open /dev/tty for interactive prompt, discarding changes");
            return WorktreeAction::Discard;
        }
    };
    let mut tty_writer = std::io::BufWriter::new(tty.try_clone().unwrap());
    let mut tty_reader = std::io::BufReader::new(tty);

    loop {
        let _ = write!(tty_writer, "\n[m]erge or [d]iscard? ");
        let _ = tty_writer.flush();
        let mut input = String::new();
        if tty_reader.read_line(&mut input).is_err() {
            return WorktreeAction::Discard;
        }
        match input.trim().to_lowercase().as_str() {
            "m" | "merge" => return WorktreeAction::Merge,
            "d" | "discard" => return WorktreeAction::Discard,
            _ => {
                let _ = writeln!(tty_writer, "Please enter 'm' to merge or 'd' to discard.");
            }
        }
    }
}

pub fn merge_worktree(info: &WorktreeInfo) -> bool {
    let repo = match Repository::open(&info.original_repo) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("Failed to open repo: {e}");
            return false;
        }
    };

    let branch_ref = match repo.find_branch(&info.branch_name, BranchType::Local) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("Failed to find branch {}: {e}", info.branch_name);
            return false;
        }
    };

    let their_oid = match branch_ref.get().target() {
        Some(oid) => oid,
        None => {
            eprintln!("Branch has no target commit");
            return false;
        }
    };

    let their_commit = match repo.find_annotated_commit(their_oid) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Failed to find commit: {e}");
            return false;
        }
    };

    let analysis = match repo.merge_analysis(&[&their_commit]) {
        Ok((analysis, _)) => analysis,
        Err(e) => {
            eprintln!("Merge analysis failed: {e}");
            return false;
        }
    };

    if analysis.is_up_to_date() {
        eprintln!("Already up to date.");
        return true;
    }

    if analysis.is_fast_forward() {
        // Fast-forward: just move HEAD to the target commit
        let mut head_ref = match repo.head() {
            Ok(r) => r,
            Err(e) => {
                eprintln!("Failed to get HEAD: {e}");
                return false;
            }
        };
        if let Err(e) = head_ref.set_target(their_oid, "ajail: fast-forward merge") {
            eprintln!("Failed to fast-forward: {e}");
            return false;
        }
        if let Err(e) = repo.checkout_head(Some(git2::build::CheckoutBuilder::new().force())) {
            eprintln!("Failed to checkout after fast-forward: {e}");
            return false;
        }
        eprintln!("Merged worktree changes into original branch (fast-forward).");
        return true;
    }

    // Normal merge
    if let Err(e) = repo.merge(&[&their_commit], None, None) {
        eprintln!("Merge failed: {e}");
        return false;
    }

    // Check for conflicts
    if let Ok(index) = repo.index()
        && index.has_conflicts()
    {
        eprintln!(
            "Merge has conflicts. Worktree preserved at: {}",
            info.worktree_path.display()
        );
        return false;
    }

    // Create merge commit
    let result = (|| -> Result<(), git2::Error> {
        let mut index = repo.index()?;
        let tree_oid = index.write_tree()?;
        let tree = repo.find_tree(tree_oid)?;
        let head_commit = repo.head()?.peel_to_commit()?;
        let their_commit_obj = repo.find_commit(their_oid)?;
        let sig = repo.signature()?;
        let msg = format!("Merge branch '{}'", info.branch_name);
        repo.commit(
            Some("HEAD"),
            &sig,
            &sig,
            &msg,
            &tree,
            &[&head_commit, &their_commit_obj],
        )?;
        repo.cleanup_state()?;
        Ok(())
    })();

    match result {
        Ok(()) => {
            eprintln!("Merged worktree changes into original branch.");
            true
        }
        Err(e) => {
            eprintln!(
                "Merge commit failed: {e}. Worktree preserved at: {}",
                info.worktree_path.display()
            );
            false
        }
    }
}

pub fn cleanup_worktree(info: &WorktreeInfo) {
    // git2-rs doesn't expose worktree remove, so shell out
    let _ = Command::new("git")
        .args([
            "worktree",
            "remove",
            "--force",
            info.worktree_path.to_str().unwrap(),
        ])
        .current_dir(&info.original_repo)
        .output();

    // Delete the branch using git2
    if let Ok(repo) = Repository::open(&info.original_repo)
        && let Ok(mut branch) = repo.find_branch(&info.branch_name, BranchType::Local)
    {
        let _ = branch.delete();
    }
}
