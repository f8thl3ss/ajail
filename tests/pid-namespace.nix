{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-pid-namespace";

  nodes.machine =
    { ... }:
    {
      imports = [ common.machineConfig ];
      environment.systemPackages = [
        (common.mkMockClaude ''
          # --- Running as PID 1 in new PID namespace ---
          MY_PID=$$
          if [ "$MY_PID" -eq 1 ]; then
            echo "OK: running as PID 1"
          else
            echo "FAIL: expected PID 1, got $MY_PID"
            FAIL=1
          fi

          # --- /proc is mounted and functional ---
          if [ -d /proc/self ]; then
            echo "OK: /proc/self exists"
          else
            echo "FAIL: /proc/self does not exist"
            FAIL=1
          fi

          if [ -f /proc/self/status ]; then
            echo "OK: /proc/self/status readable"
          else
            echo "FAIL: /proc/self/status not readable"
            FAIL=1
          fi

          # --- Few processes visible (isolated PID namespace) ---
          NPROCS=$(ls -1d /proc/[0-9]* 2>/dev/null | wc -l)
          if [ "$NPROCS" -lt 10 ]; then
            echo "OK: few processes visible ($NPROCS)"
          else
            echo "FAIL: too many processes visible ($NPROCS), PID namespace may not be isolated"
            FAIL=1
          fi

          # --- PID namespace differs from host ---
          SANDBOX_PIDNS="$(readlink /proc/self/ns/pid)"
          HOST_PIDNS="$(cat .host_pidns)"
          if [ "$SANDBOX_PIDNS" != "$HOST_PIDNS" ]; then
            echo "OK: PID namespace differs (host=$HOST_PIDNS sandbox=$SANDBOX_PIDNS)"
          else
            echo "FAIL: PID namespace is the same as host ($SANDBOX_PIDNS)"
            FAIL=1
          fi
        '')
      ];
    };

  testScript = common.setup + ''
    # Save host PID namespace ID so the mock claude can verify it's in a different one
    machine.succeed("su - testuser -c 'readlink /proc/self/ns/pid > ~/projects/myrepo/.host_pidns'")

    machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail'")
  '';
}
