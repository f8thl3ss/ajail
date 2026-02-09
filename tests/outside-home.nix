{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-outside-home";

  nodes.machine =
    { ... }:
    {
      imports = [ common.machineConfig ];
      environment.systemPackages = [
        (common.mkMockClaude ''
          # --- Repo writable ---
          assert_exists     "existing repo file"     "./existing-file"
          assert_ok         "can write to repo"      touch ./write-test
          rm -f ./write-test

          # --- Home isolation ---
          assert_not_exists "~/.secrets hidden"      "$HOME/.secrets"

          # --- Claude config accessible ---
          assert_exists     "~/.claude exists"       "$HOME/.claude"
          assert_exists     "~/.claude.json exists"  "$HOME/.claude.json"

          # --- /tmp isolated ---
          assert_not_exists "host /tmp hidden"       "/tmp/host-marker"
        '')
      ];
    };

  testScript = common.setup + ''
    # Create a git repo outside $HOME
    machine.succeed("mkdir -p /srv/project")
    machine.succeed("chown testuser:users /srv/project")
    machine.succeed("su - testuser -c 'cd /srv/project && git init'")
    machine.succeed("su - testuser -c 'echo existing > /srv/project/existing-file'")

    # Run ajail from a repo outside $HOME
    machine.succeed("su - testuser -c 'cd /srv/project && ajail'")
  '';
}
