{ pkgs, common }:

let
  pkgsAarch64 = import pkgs.path {
    system = "aarch64-linux";
  };

  ajailAarch64 = pkgsAarch64.rustPlatform.buildRustPackage {
    pname = "ajail";
    version = "0.1.0";
    src = pkgsAarch64.lib.cleanSource ./..;
    cargoLock.lockFile = ../Cargo.lock;
  };

  commonAarch64 = import ./common.nix {
    pkgs = pkgsAarch64;
    ajail = ajailAarch64;
  };
in
{
  allow = pkgsAarch64.testers.nixosTest {
    name = "ajail-unix-sockets-aarch64-allow";

    nodes.machine =
      { ... }:
      {
        imports = [ commonAarch64.machineConfig ];
        environment.systemPackages = [
          pkgsAarch64.python3
          (commonAarch64.mkMockClaude ''
            # --- Unix socket creation should succeed with --allow-unix-sockets ---
            assert_ok "unix socket creation allowed" \
              python3 -c "import socket; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.close()"

            # --- TCP sockets should also work ---
            assert_ok "tcp socket creation allowed" \
              python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.close()"
          '')
        ];
      };

    testScript = commonAarch64.setup + ''
      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail --allow-unix-sockets'")
    '';
  };

  deny = pkgsAarch64.testers.nixosTest {
    name = "ajail-unix-sockets-aarch64-deny";

    nodes.machine =
      { ... }:
      {
        imports = [ commonAarch64.machineConfig ];
        environment.systemPackages = [
          pkgsAarch64.python3
          (commonAarch64.mkMockClaude ''
            # --- Unix socket creation should be blocked by default ---
            assert_denied "unix socket creation blocked" \
              python3 -c "import socket; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)"

            # --- TCP sockets should still work ---
            assert_ok "tcp socket creation allowed" \
              python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.close()"

            # --- Regular file I/O should still work ---
            assert_ok "file I/O works" \
              python3 -c "open('/tmp/test-file', 'w').write('hello')"
          '')
        ];
      };

    testScript = commonAarch64.setup + ''
      # Run WITHOUT --allow-unix-sockets — socket creation should be blocked
      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail'")
    '';
  };
}
