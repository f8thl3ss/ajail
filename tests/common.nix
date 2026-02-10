{ pkgs, ajail }:

{
  machineConfig =
    { ... }:
    {
      boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;
      environment.systemPackages = [
        ajail
        pkgs.git
      ];
      users.users.testuser = {
        isNormalUser = true;
        home = "/home/testuser";
      };
    };

  # Helper: wrap a test script into a named mock binary
  mkMockCommand =
    name: script:
    pkgs.writeShellScriptBin name ''
      FAIL=0

      assert_denied() {
        local desc="$1"; shift
        if "$@" 2>/dev/null; then
          echo "FAIL: $desc"
          FAIL=1
        else
          echo "OK: $desc"
        fi
      }

      assert_ok() {
        local desc="$1"; shift
        if "$@" 2>/dev/null; then
          echo "OK: $desc"
        else
          echo "FAIL: $desc"
          FAIL=1
        fi
      }

      assert_exists() {
        local desc="$1" path="$2"
        if [ -e "$path" ]; then
          echo "OK: $desc"
        else
          echo "FAIL: $desc"
          FAIL=1
        fi
      }

      assert_not_exists() {
        local desc="$1" path="$2"
        if [ -e "$path" ]; then
          echo "FAIL: $desc"
          FAIL=1
        else
          echo "OK: $desc"
        fi
      }

      ${script}

      exit $FAIL
    '';

  # Helper: wrap a test script into a mock claude binary
  mkMockClaude =
    script:
    pkgs.writeShellScriptBin "claude" ''
      FAIL=0

      assert_denied() {
        local desc="$1"; shift
        if "$@" 2>/dev/null; then
          echo "FAIL: $desc"
          FAIL=1
        else
          echo "OK: $desc"
        fi
      }

      assert_ok() {
        local desc="$1"; shift
        if "$@" 2>/dev/null; then
          echo "OK: $desc"
        else
          echo "FAIL: $desc"
          FAIL=1
        fi
      }

      assert_exists() {
        local desc="$1" path="$2"
        if [ -e "$path" ]; then
          echo "OK: $desc"
        else
          echo "FAIL: $desc"
          FAIL=1
        fi
      }

      assert_not_exists() {
        local desc="$1" path="$2"
        if [ -e "$path" ]; then
          echo "FAIL: $desc"
          FAIL=1
        else
          echo "OK: $desc"
        fi
      }

      ${script}

      exit $FAIL
    '';

  # Common setup for testScript: create user dirs, git repo, claude config
  setup = ''
    machine.wait_for_unit("multi-user.target")

    # Sensitive directories that should be hidden
    machine.succeed("su - testuser -c 'mkdir -p ~/.local ~/.secrets ~/.ssh'")
    machine.succeed("su - testuser -c 'echo secret-key > ~/.secrets/key'")
    machine.succeed("su - testuser -c 'echo local-data > ~/.local/data'")
    machine.succeed("su - testuser -c 'echo ssh-key > ~/.ssh/id_rsa'")

    # Claude config
    machine.succeed("su - testuser -c 'mkdir -p ~/.claude'")
    machine.succeed("su - testuser -c 'echo test-config > ~/.claude/config'")
    machine.succeed("su - testuser -c 'echo {} > ~/.claude.json'")

    # Git repo
    machine.succeed("su - testuser -c 'mkdir -p ~/projects/myrepo'")
    machine.succeed("su - testuser -c 'cd ~/projects/myrepo && git init'")
    machine.succeed("su - testuser -c 'echo existing > ~/projects/myrepo/existing-file'")

    # File in host /tmp that should NOT be visible inside sandbox
    machine.succeed("su - testuser -c 'echo host-tmp > /tmp/host-marker'")
  '';
}
