{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-sandbox";

  nodes.machine =
    { ... }:
    {
      imports = [ common.machineConfig ];
      environment.systemPackages = [
        (common.mkMockClaude ''
          # --- Home isolation ---
          assert_not_exists "~/.local hidden"       "$HOME/.local"
          assert_not_exists "~/.secrets hidden"      "$HOME/.secrets"
          assert_not_exists "~/.ssh hidden"          "$HOME/.ssh"

          # --- Claude config accessible ---
          assert_exists     "~/.claude exists"       "$HOME/.claude"
          assert_exists     "~/.claude/config exists" "$HOME/.claude/config"
          assert_ok         "~/.claude/config readable" cat "$HOME/.claude/config"
          assert_exists     "~/.claude.json exists"  "$HOME/.claude.json"
          assert_ok         "~/.claude.json readable" cat "$HOME/.claude.json"

          # --- Repo writable ---
          assert_exists     "existing repo file"     "./existing-file"
          assert_ok         "can write to repo"      touch ./write-test
          rm -f ./write-test
          assert_ok         "can create dir in repo" mkdir ./subdir
          rmdir ./subdir

          # --- /tmp isolated ---
          assert_not_exists "host /tmp hidden"       "/tmp/host-marker"
          assert_ok         "can write to /tmp"      touch /tmp/sandbox-test
          rm -f /tmp/sandbox-test

          # --- Staging area not leaked ---
          assert_not_exists "staging area cleaned"   "/tmp/.ajail-staging"
          assert_not_exists "home staging cleaned"   "$HOME/.ajail-staging"

          # --- System dirs readable ---
          assert_ok         "/etc readable"          ls /etc
          assert_ok         "/nix readable"          ls /nix
          assert_exists     "/etc/passwd exists"     "/etc/passwd"

          # --- Parent directory not writable ---
          PARENT="$(dirname "$(pwd)")"
          assert_denied     "cannot write to parent" touch "$PARENT/write-test"
          assert_denied     "cannot delete parent"   rm -rf "$PARENT"

          # --- Network available ---
          assert_exists     "/etc/resolv.conf exists" "/etc/resolv.conf"

          # --- Running in different namespaces ---
          SANDBOX_USERNS="$(readlink /proc/self/ns/user)"
          SANDBOX_MNTNS="$(readlink /proc/self/ns/mnt)"
          HOST_USERNS="$(cat .host_userns)"
          HOST_MNTNS="$(cat .host_mntns)"

          if [ "$SANDBOX_USERNS" != "$HOST_USERNS" ]; then
            echo "OK: user namespace differs (host=$HOST_USERNS sandbox=$SANDBOX_USERNS)"
          else
            echo "FAIL: user namespace is the same as host ($SANDBOX_USERNS)"
            FAIL=1
          fi

          if [ "$SANDBOX_MNTNS" != "$HOST_MNTNS" ]; then
            echo "OK: mount namespace differs (host=$HOST_MNTNS sandbox=$SANDBOX_MNTNS)"
          else
            echo "FAIL: mount namespace is the same as host ($SANDBOX_MNTNS)"
            FAIL=1
          fi

          # --- Tmpfs permissions ---
          TMP_PERMS="$(stat -c '%a' /tmp)"
          if [ "$TMP_PERMS" = "1777" ] || [ "$TMP_PERMS" = "777" ]; then
            echo "OK: /tmp perms=$TMP_PERMS"
          else
            echo "FAIL: /tmp expected 1777 or 777, got $TMP_PERMS"
            FAIL=1
          fi

          HOME_PERMS="$(stat -c '%a' "$HOME")"
          if [ "$HOME_PERMS" = "1777" ] || [ "$HOME_PERMS" = "755" ] || [ "$HOME_PERMS" = "700" ]; then
            echo "OK: \$HOME perms=$HOME_PERMS"
          else
            echo "FAIL: \$HOME expected 1777, 755, or 700, got $HOME_PERMS"
            FAIL=1
          fi

          # --- Mount point permissions ---
          CLAUDE_DIR_PERMS="$(stat -c '%a' "$HOME/.claude")"
          if [ "$CLAUDE_DIR_PERMS" = "755" ] || [ "$CLAUDE_DIR_PERMS" = "700" ]; then
            echo "OK: ~/.claude perms=$CLAUDE_DIR_PERMS"
          else
            echo "FAIL: ~/.claude expected 755 or 700, got $CLAUDE_DIR_PERMS"
            FAIL=1
          fi

          REPO_PERMS="$(stat -c '%a' "$(pwd)")"
          if [ "$REPO_PERMS" = "755" ] || [ "$REPO_PERMS" = "775" ]; then
            echo "OK: repo perms=$REPO_PERMS"
          else
            echo "FAIL: repo expected 755 or 775, got $REPO_PERMS"
            FAIL=1
          fi

          # --- Permission boundary enforcement ---
          assert_denied     "cannot read /etc/shadow" cat /etc/shadow

          # --- Capabilities should be zero ---
          CAP_EFF="$(grep 'CapEff' /proc/self/status | awk '{print $2}')"
          if [ "$CAP_EFF" = "0000000000000000" ]; then
            echo "OK: effective capabilities are zero ($CAP_EFF)"
          else
            echo "FAIL: effective capabilities should be zero, got $CAP_EFF"
            FAIL=1
          fi

          # --- Mount propagation: create a mount inside sandbox ---
          # The host-side test script will verify this doesn't leak
          mkdir -p /tmp/propagation-test
          mount -t tmpfs tmpfs /tmp/propagation-test 2>/dev/null || true
          echo "sandbox-mount" > /tmp/propagation-test/marker 2>/dev/null || true
        '')
      ];
    };

  testScript = common.setup + ''
    # Save host namespace IDs so the mock claude can verify it's in different ones
    machine.succeed("su - testuser -c 'readlink /proc/self/ns/user > ~/projects/myrepo/.host_userns'")
    machine.succeed("su - testuser -c 'readlink /proc/self/ns/mnt > ~/projects/myrepo/.host_mntns'")

    machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail'")

    # --- Mount propagation escape check (host side) ---
    # Verify that mounts created inside the sandbox did not leak to the host
    machine.succeed("test ! -f /tmp/propagation-test/marker")
  '';
}
