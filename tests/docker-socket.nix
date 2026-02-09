{ pkgs, common }:

let
  mkSocket = pkgs.writeScript "mk-socket" ''
    #!${pkgs.python3}/bin/python3
    import socket, sys
    s = socket.socket(socket.AF_UNIX)
    s.bind(sys.argv[1])
  '';
in
{
  allow = pkgs.testers.nixosTest {
    name = "ajail-docker-socket-allow";

    nodes.machine =
      { ... }:
      {
        imports = [ common.machineConfig ];
        environment.systemPackages = [
          (common.mkMockClaude ''
            # --- Docker socket should be accessible with --allow-docker ---
            if [ -e /var/run/docker.sock ]; then
              echo "OK: Docker socket is accessible"
            else
              echo "FAIL: Docker socket is not accessible"
              FAIL=1
            fi
          '')
        ];
      };

    testScript = common.setup + ''
      # Create a fake Docker socket and make it accessible to testuser
      machine.succeed("${mkSocket} /var/run/docker.sock")
      machine.succeed("chown testuser:users /var/run/docker.sock")

      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail --allow-docker'")
    '';
  };

  deny = pkgs.testers.nixosTest {
    name = "ajail-docker-socket-deny";

    nodes.machine =
      { ... }:
      {
        imports = [ common.machineConfig ];
        environment.systemPackages = [
          (common.mkMockClaude ''
            # --- Docker socket should NOT be accessible without --allow-docker ---
            if [ -S /var/run/docker.sock ]; then
              echo "FAIL: Docker socket is accessible without --allow-docker"
              FAIL=1
            else
              echo "OK: Docker socket is not accessible"
            fi
          '')
        ];
      };

    testScript = common.setup + ''
      # Create a fake Docker socket and make it accessible to testuser
      machine.succeed("${mkSocket} /var/run/docker.sock")
      machine.succeed("chown testuser:users /var/run/docker.sock")

      # Run WITHOUT --allow-docker — socket should be hidden
      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail'")
    '';
  };
}
