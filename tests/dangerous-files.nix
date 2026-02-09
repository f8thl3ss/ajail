{ pkgs, common }:

{
  deny = pkgs.testers.nixosTest {
    name = "ajail-dangerous-files-deny";

    nodes.machine =
      { ... }:
      {
        imports = [ common.machineConfig ];
        environment.systemPackages = [
          (common.mkMockClaude ''
            # --- Dangerous files should be read-only by default ---
            assert_denied "cannot write .gitconfig" bash -c 'echo x >> .gitconfig'
            assert_ok     "can read .gitconfig"     cat .gitconfig

            assert_denied "cannot write .git/config" bash -c 'echo x >> .git/config'
            assert_ok     "can read .git/config"     cat .git/config

            assert_denied "cannot create in .git/hooks" touch .git/hooks/new-hook
            assert_ok     "can read .git/hooks"         ls .git/hooks

            assert_denied "cannot create in .vscode" touch .vscode/new-file
            assert_ok     "can read .vscode"         ls .vscode

            assert_denied "cannot write .bashrc" bash -c 'echo x >> .bashrc'
            assert_ok     "can read .bashrc"     cat .bashrc

            # --- Regular files should still be writable ---
            assert_ok     "can write regular file"   bash -c 'echo test > normal-file'
            rm -f normal-file
          '')
        ];
      };

    testScript = common.setup + ''
      # Create dangerous files and directories in the repo
      machine.succeed("su - testuser -c 'echo gitcfg > ~/projects/myrepo/.gitconfig'")
      machine.succeed("su - testuser -c 'echo bashrc > ~/projects/myrepo/.bashrc'")
      machine.succeed("su - testuser -c 'mkdir -p ~/projects/myrepo/.git/hooks'")
      machine.succeed("su - testuser -c 'echo hook > ~/projects/myrepo/.git/hooks/pre-commit'")
      machine.succeed("su - testuser -c 'mkdir -p ~/projects/myrepo/.vscode'")
      machine.succeed("su - testuser -c 'echo settings > ~/projects/myrepo/.vscode/settings.json'")

      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail'")
    '';
  };

  allow = pkgs.testers.nixosTest {
    name = "ajail-dangerous-files-allow";

    nodes.machine =
      { ... }:
      {
        imports = [ common.machineConfig ];
        environment.systemPackages = [
          (common.mkMockClaude ''
            # --- Dangerous files should be writable with --allow-dangerous-writes ---
            assert_ok "can write .gitconfig"       bash -c 'echo x >> .gitconfig'
            assert_ok "can write .bashrc"           bash -c 'echo x >> .bashrc'
            assert_ok "can write .git/config"       bash -c 'echo x >> .git/config'
            assert_ok "can create in .git/hooks"    touch .git/hooks/new-hook
            assert_ok "can create in .vscode"       touch .vscode/new-file

            # Clean up
            rm -f .git/hooks/new-hook .vscode/new-file
          '')
        ];
      };

    testScript = common.setup + ''
      # Create dangerous files and directories in the repo
      machine.succeed("su - testuser -c 'echo gitcfg > ~/projects/myrepo/.gitconfig'")
      machine.succeed("su - testuser -c 'echo bashrc > ~/projects/myrepo/.bashrc'")
      machine.succeed("su - testuser -c 'mkdir -p ~/projects/myrepo/.git/hooks'")
      machine.succeed("su - testuser -c 'echo hook > ~/projects/myrepo/.git/hooks/pre-commit'")
      machine.succeed("su - testuser -c 'mkdir -p ~/projects/myrepo/.vscode'")
      machine.succeed("su - testuser -c 'echo settings > ~/projects/myrepo/.vscode/settings.json'")

      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail --allow-dangerous-writes'")
    '';
  };
}
