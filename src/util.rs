use std::path::{Path, PathBuf};

pub fn random_hex(len: usize) -> String {
    let mut buf = vec![0u8; len.div_ceil(2)];
    getrandom::fill(&mut buf).expect("Failed to get random bytes");
    hex::encode(&buf)[..len].to_string()
}

pub fn repo_root(project_dir: &Path) -> PathBuf {
    git2::Repository::discover(project_dir)
        .ok()
        .and_then(|repo| repo.workdir().map(|p| p.to_path_buf()))
        .unwrap_or_else(|| project_dir.to_path_buf())
}
