{ pkgs, common }:

{
  allow = pkgs.testers.nixosTest {
    name = "ajail-unix-sockets-allow";

    nodes.machine =
      { ... }:
      {
        imports = [ common.machineConfig ];
        environment.systemPackages = [
          pkgs.python3
          (common.mkMockClaude ''
            # --- Unix socket creation should succeed with --allow-unix-sockets ---
            assert_ok "unix socket creation allowed" \
              python3 -c "import socket; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.close()"

            # --- TCP sockets should also work ---
            assert_ok "tcp socket creation allowed" \
              python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.close()"
          '')
        ];
      };

    testScript = common.setup + ''
      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail --allow-unix-sockets'")
    '';
  };

  deny = pkgs.testers.nixosTest {
    name = "ajail-unix-sockets-deny";

    nodes.machine =
      { ... }:
      {
        imports = [ common.machineConfig ];
        environment.systemPackages = [
          pkgs.python3
          (common.mkMockClaude ''
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

    testScript = common.setup + ''
      # Run WITHOUT --allow-unix-sockets — socket creation should be blocked
      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail'")
    '';
  };
}
