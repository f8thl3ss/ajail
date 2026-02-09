{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-home-claude";

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
      '';
    in
    common.setup + ''
      # Install mock claude under ~/.local/bin (simulating a home-dir install)
      machine.succeed("su - testuser -c 'mkdir -p ~/.local/bin'")
      machine.succeed("su - testuser -c 'cp ${mockClaude}/bin/claude ~/.local/bin/claude'")
      machine.succeed("su - testuser -c 'chmod +x ~/.local/bin/claude'")

      # Add ~/.local/bin to PATH and run ajail
      machine.succeed("su - testuser -c 'export PATH=\"$HOME/.local/bin:$PATH\" && cd ~/projects/myrepo && ajail'")
    '';
}
