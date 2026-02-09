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
    name = "ajail-ssh-agent-allow";

    nodes.machine = { ... }: {
      imports = [ common.machineConfig ];
      environment.systemPackages = [
        (common.mkMockClaude ''
          # --- SSH_AUTH_SOCK should be set ---
          if [ -z "$SSH_AUTH_SOCK" ]; then
            echo "FAIL: SSH_AUTH_SOCK not set"
            FAIL=1
          else
            echo "OK: SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
          fi

          # --- Socket should exist and be a socket ---
          if [ -S "$SSH_AUTH_SOCK" ]; then
            echo "OK: SSH_AUTH_SOCK is a socket"
          else
            echo "FAIL: SSH_AUTH_SOCK is not a socket or does not exist"
            FAIL=1
          fi

          # --- Socket should be readable ---
          assert_ok "can stat SSH_AUTH_SOCK" stat "$SSH_AUTH_SOCK"
        '')
      ];
    };

    testScript = common.setup + ''
      # Create a fake SSH agent socket outside /tmp and $HOME (both get tmpfs overlays)
      machine.succeed("mkdir -p /run/user/1000")
      machine.succeed("chown testuser:users /run/user/1000")
      machine.succeed("su - testuser -c '${mkSocket} /run/user/1000/ssh-agent.sock'")

      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && SSH_AUTH_SOCK=/run/user/1000/ssh-agent.sock ajail --allow-ssh-agent'")
    '';
  };

  deny = pkgs.testers.nixosTest {
    name = "ajail-ssh-agent-deny";

    nodes.machine = { ... }: {
      imports = [ common.machineConfig ];
      environment.systemPackages = [
        (common.mkMockClaude ''
          # --- Socket should NOT be accessible without --allow-ssh-agent ---
          # The socket is under $HOME/.ssh-agent/ which gets hidden by the $HOME tmpfs overlay
          if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ]; then
            echo "FAIL: SSH_AUTH_SOCK socket is accessible without --allow-ssh-agent"
            FAIL=1
          else
            echo "OK: SSH_AUTH_SOCK socket is not accessible"
          fi
        '')
      ];
    };

    testScript = common.setup + ''
      # Place the socket under $HOME so it gets hidden by the home tmpfs overlay
      machine.succeed("su - testuser -c 'mkdir -p ~/.ssh-agent'")
      machine.succeed("su - testuser -c '${mkSocket} /home/testuser/.ssh-agent/agent.sock'")

      # Run WITHOUT --allow-ssh-agent — socket under $HOME should be hidden
      machine.succeed("su - testuser -c 'cd ~/projects/myrepo && SSH_AUTH_SOCK=/home/testuser/.ssh-agent/agent.sock ajail'")
    '';
  };
}
