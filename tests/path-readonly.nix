{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-path-readonly";

  nodes.machine =
    { ... }:
    {
      imports = [ common.machineConfig ];
    };

  testScript =
    let
      mockClaude = common.mkMockClaude ''
        # --- PATH dirs under $HOME should be read-only ---
        assert_denied "cannot write to nix-profile bin dir" touch ~/.nix-profile/bin/evil
        assert_denied "cannot overwrite claude binary" cp /dev/null ~/.nix-profile/bin/claude
        assert_denied "cannot remove claude binary" rm ~/.nix-profile/bin/claude
        assert_denied "cannot write to helper binary" cp /dev/null ~/.nix-profile/bin/helper-bin

        # --- Binaries should still be executable ---
        assert_ok "claude binary is executable" test -x ~/.nix-profile/bin/claude
        assert_ok "helper binary is executable" test -x ~/.nix-profile/bin/helper-bin
      '';

      helperBin = pkgs.writeShellScriptBin "helper-bin" ''
        echo "helper ok"
      '';

      fakeProfile = pkgs.symlinkJoin {
        name = "fake-nix-profile";
        paths = [
          mockClaude
          helperBin
        ];
      };
    in
    common.setup
    + ''
      # Simulate ~/.nix-profile as a symlink to a nix store path
      machine.succeed("su - testuser -c 'ln -s ${fakeProfile} ~/.nix-profile'")

      # Run ajail — PATH dirs should be mounted read-only
      machine.succeed("su - testuser -c 'export PATH=\"$HOME/.nix-profile/bin:$PATH\" && cd ~/projects/myrepo && ajail'")
    '';
}
