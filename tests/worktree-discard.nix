{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-worktree-discard";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ common.machineConfig ];
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "claude" ''
          git config user.email "test@test.com"
          git config user.name "Test"
          echo "unwanted" > unwanted.txt
          git add unwanted.txt
          git commit -m "unwanted change"
        '')
      ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Create a git repo with an initial commit
    machine.succeed("su - testuser -c 'git config --global user.email test@test.com'")
    machine.succeed("su - testuser -c 'git config --global user.name Test'")
    machine.succeed("su - testuser -c 'mkdir -p ~/projects/myrepo'")
    machine.succeed("su - testuser -c 'cd ~/projects/myrepo && git init && git checkout -b main'")
    machine.succeed("su - testuser -c 'cd ~/projects/myrepo && echo hello > file.txt && git add . && git commit -m initial'")

    # Claude config
    machine.succeed("su - testuser -c 'mkdir -p ~/.claude'")
    machine.succeed("su - testuser -c 'echo {} > ~/.claude.json'")

    # Run ajail with --worktree and auto-discard
    machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail --worktree --worktree-action discard'")

    # Verify: unwanted.txt does NOT exist in original repo
    machine.succeed("su - testuser -c 'test ! -f ~/projects/myrepo/unwanted.txt'")

    # Verify: git log does NOT contain the unwanted commit
    output = machine.succeed("su - testuser -c 'cd ~/projects/myrepo && git log --oneline'")
    assert "unwanted change" not in output, "Expected no 'unwanted change' in git log, got: " + output

    # Verify: no leftover ajail branches
    branches = machine.succeed("su - testuser -c 'cd ~/projects/myrepo && git branch'")
    assert "ajail-" not in branches, "Expected no ajail- branches, got: " + branches

    # Verify: no leftover worktrees
    worktrees = machine.succeed("su - testuser -c 'cd ~/projects/myrepo && git worktree list'")
    lines = [l.strip() for l in worktrees.strip().split("\n") if l.strip()]
    assert len(lines) == 1, "Expected exactly 1 worktree (main), got: " + worktrees
  '';
}
