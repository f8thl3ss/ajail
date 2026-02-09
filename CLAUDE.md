# ajail

Rust rewrite of [numtide/claudebox](https://github.com/numtide/claudebox) (originally JavaScript). Runs Claude Code inside a Linux namespace sandbox using `unshare(CLONE_NEWUSER | CLONE_NEWNS)` to create unprivileged user and mount namespaces, giving Claude full autonomy within the project directory while isolating it from the rest of the system. Unlike the original, ajail uses direct Linux namespace syscalls instead of Bubblewrap, requiring no external sandboxing tools.

## Build & Run

```bash
nix develop          # enter dev shell
cargo build          # build
cargo run -- --help  # show usage
```

Or via Nix:

```bash
nix build            # produces result/bin/ajail
nix run . -- --help
```

## Linting

```bash
cargo clippy -- -D warnings
```

## Testing

NixOS VM tests verify sandbox isolation. Run with:

```bash
nix flake check
```

Two test suites in `tests/sandbox.nix`:

- **sandbox**: verifies `~/.local`, `~/.secrets` are inaccessible, parent dir can't be deleted, repo is writable, `/tmp` is isolated
- **config-dir**: verifies `--claude-config-dir` makes `CLAUDE_CONFIG_DIR` available, readable, and writable inside the sandbox while home remains isolated

Each test uses a mock `claude` script that performs assertions and exits non-zero on failure.

After any code change, run `cargo clippy -- -D warnings` and `nix flake check` to ensure linting passes and all NixOS VM tests still work. New test files must be `git add`ed before `nix flake check` can see them.

## Architecture

Single file: `src/main.rs`. No module splitting needed at current size (~330 lines).

### Sandbox strategy

Paths under `$HOME` become inaccessible after the tmpfs overlay. To preserve them:

1. Bind-mount needed paths to a staging tmpfs at `/tmp/.ajail-staging`
2. Overlay `$HOME` with tmpfs (hides everything)
3. Bind-mount from staging to final destinations inside the new home
4. Bind-mount repo/share_tree from staging (if under home) before overlaying `/tmp`
5. Overlay `/tmp` with tmpfs (cleans up staging)

### Mount order matters

The staging approach exists because after mounting tmpfs over `$HOME`, original paths underneath are gone. The `/tmp` overlay must happen **after** repo bind-mounts since staging lives under `/tmp`.

### Config

Persistent settings in `$XDG_CONFIG_HOME/ajail/config.json` (default `~/.config/ajail/config.json`). Uses `camelCase` keys to match the original JS version:

```json
{
  "allowSshAgent": false,
  "allowGpgAgent": false,
  "allowXdgRuntime": false
}
```

CLI flags override config file values.

## Dependencies

- `nix` - Linux syscall wrappers (unshare, mount, fork, exec, waitpid)
- `clap` - CLI argument parsing with derive and env support
- `serde` + `serde_json` - config file parsing
