{ pkgs, common }:

let
  # Import nixpkgs with allowUnfree for claude-code
  unfree-pkgs = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
unfree-pkgs.testers.nixosTest {
  name = "ajail-claude-binary";

  nodes.machine = { ... }: {
    imports = [ common.machineConfig ];
    environment.systemPackages = [ unfree-pkgs.claude-code ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Verify claude binary is found
    machine.succeed("which claude")
    machine.succeed("claude --version")

    # Verify ajail can find and exec claude (will fail auth but should not fail with "not found")
    # Use --help which doesn't require auth
    machine.succeed("su - testuser -c 'claude --help'")
  '';
}
