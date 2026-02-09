# ajail

Rust rewrite of [numtide/claudebox](https://github.com/numtide/claudebox) (originally JavaScript). Runs Claude Code in `--dangerously-skip-permissions` mode inside a Linux namespace sandbox, so Claude gets full autonomy within your project while being isolated from the rest of your system.

Unlike the original which uses [Bubblewrap](https://github.com/containers/bubblewrap) as an external dependency, ajail uses direct Linux namespace syscalls (`unshare`, `mount`) via the [nix](https://crates.io/crates/nix) crate. No external sandboxing tools required. This is still experimental and has not been audited for security, _use it at your own risk_.

## What the sandbox does

**Namespace isolation:**

- User namespace -- unprivileged, zero capabilities
- Mount namespace -- independent mount tree, no propagation to host
- PID namespace -- sandboxed process runs as PID 1, cannot see host processes

**Writable inside the sandbox:**

- Your git repo / project directory
- Claude config (`~/.claude`, `~/.claude.json`)
- An isolated `/tmp`

**Hidden / inaccessible:**

- The rest of your home directory (`~/.ssh`, `~/.local`, `~/.secrets`, etc.)
- XDG runtime directory (`/run/user/$UID`)
- Host processes (`/proc` is remounted for the new PID namespace)

**Read-only:**

- System directories (`/usr`, `/bin`, `/lib`, `/etc`, `/nix`)
- Parent directory tree above the repo (if repo is under `$HOME`)
- Dangerous files in the repo: shell configs (`.bashrc`, `.zshrc`, `.profile`, etc.), git config/hooks (`.gitconfig`, `.gitmodules`, `.git/config`, `.git/hooks`), IDE settings (`.vscode`, `.idea`, `.zed`), and MCP/agent configs (`.mcp.json`, `.claude/commands`, `.claude/agents`)

**Opt-in access:**

- `--allow-ssh-agent` -- expose `$SSH_AUTH_SOCK` for git over SSH
- `--allow-gpg-agent` -- expose GPG socket for signed commits
- `--allow-docker` -- expose Docker daemon socket (`/var/run/docker.sock`)
- `--allow-xdg-runtime` -- expose full XDG runtime directory
- `--allow-dangerous-writes` -- allow writing to dangerous files (shell configs, git hooks, IDE settings, etc.)
- `--claude-config-dir <PATH>` -- use a custom Claude config directory (also reads `CLAUDE_CONFIG_DIR` env var)
- `--worktree` -- run Claude in an isolated git worktree
- `--worktree-action <merge|discard|prompt>` -- action after worktree session ends (default: prompt)
- `--dangerously-skip-permissions` -- pass `--dangerously-skip-permissions` to Claude

## Usage

```bash
# Run in current git repo
ajail

# Allow SSH agent for git push/pull
ajail --allow-ssh-agent

# Use a custom Claude config directory
ajail --claude-config-dir /path/to/config
```

## Install

### From source

```bash
cargo build --release
cp target/release/ajail ~/.local/bin/
```

## Configuration

Persistent settings in `$XDG_CONFIG_HOME/ajail/config.json` (default `~/.config/ajail/config.json`):

```json
{
  "allowSshAgent": false,
  "allowGpgAgent": false,
  "allowDocker": false,
  "allowDangerousWrites": false,
  "allowXdgRuntime": false,
  "worktree": false
}
```

CLI flags override config file values.

## Requirements

- Linux with user namespace support (kernel 3.8+, most distros since ~2020)
- `claude` CLI on your `$PATH`

## Credits

Inspired by and based on [numtide/claudebox](https://github.com/numtide/claudebox) by [numtide](https://github.com/numtide).

## License

[MIT](LICENSE)
