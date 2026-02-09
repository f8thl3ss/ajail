{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-config-dir";

  nodes.machine =
    { ... }:
    {
      imports = [ common.machineConfig ];
      environment.systemPackages = [
        (common.mkMockClaude ''
          # --- CLAUDE_CONFIG_DIR set and accessible ---
          if [ -z "$CLAUDE_CONFIG_DIR" ]; then
            echo "FAIL: CLAUDE_CONFIG_DIR not set"
            FAIL=1
          else
            echo "OK: CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
          fi

          assert_exists     "config dir exists"       "$CLAUDE_CONFIG_DIR"
          assert_exists     "test-marker readable"    "$CLAUDE_CONFIG_DIR/test-marker"
          assert_ok         "can read test-marker"    cat "$CLAUDE_CONFIG_DIR/test-marker"
          assert_ok         "can write to config dir" touch "$CLAUDE_CONFIG_DIR/write-test"
          rm -f "$CLAUDE_CONFIG_DIR/write-test"

          # --- Home still isolated ---
          assert_not_exists "~/.secrets hidden"       "$HOME/.secrets"
          assert_not_exists "~/.ssh hidden"           "$HOME/.ssh"

          # --- Default ~/.claude should NOT have the test-marker ---
          assert_not_exists "default config not leaked" "$HOME/.claude/test-marker"
        '')
      ];
    };

  testScript = common.setup + ''
    # Custom config dir outside $HOME
    machine.succeed("mkdir -p /opt/claude-config")
    machine.succeed("echo marker > /opt/claude-config/test-marker")
    machine.succeed("chown -R testuser:users /opt/claude-config")

    machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail --claude-config-dir /opt/claude-config'")
  '';
}
