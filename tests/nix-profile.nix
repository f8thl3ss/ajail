{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-nix-profile";

  nodes.machine =
    { ... }:
    {
      imports = [ common.machineConfig ];
      # claude is NOT in environment.systemPackages — only ajail and git
    };

  testScript =
    let
      mockClaude = common.mkMockClaude ''
        assert_ok "claude runs inside sandbox" true

        # Verify other binaries from nix-profile are accessible too
        assert_ok "helper binary accessible" helper-bin
      '';

      # A second nix-store binary to verify all profile binaries are preserved
      helperBin = pkgs.writeShellScriptBin "helper-bin" ''
        echo "helper ok"
      '';

      # Simulate a nix profile: a derivation whose bin/ contains both binaries
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
      # Simulate ~/.nix-profile as a symlink to a nix store path (like real nix does).
      machine.succeed("su - testuser -c 'ln -s ${fakeProfile} ~/.nix-profile'")

      # Verify the symlink chain works
      machine.succeed("su - testuser -c 'test -x ~/.nix-profile/bin/claude'")
      machine.succeed("su - testuser -c 'test -x ~/.nix-profile/bin/helper-bin'")

      # Debug: print PATH as testuser
      machine.succeed("su - testuser -c 'echo PATH=$PATH'")

      # Run ajail with ~/.nix-profile/bin in PATH (like a real nix user)
      machine.succeed("su - testuser -c 'export PATH=\"$HOME/.nix-profile/bin:$PATH\" && echo PATH=$PATH && cd ~/projects/myrepo && RUST_BACKTRACE=1 ajail'")
    '';
}
