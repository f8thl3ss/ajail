{ pkgs, common }:

pkgs.testers.nixosTest {
  name = "ajail-custom-command";

  nodes.machine =
    { ... }:
    {
      imports = [ common.machineConfig ];
      environment.systemPackages = [
        (common.mkMockCommand "opencode" ''
          # Verify we are actually running as opencode
          CMD_NAME="$(basename "$0")"
          if [ "$CMD_NAME" = "opencode" ]; then
            echo "OK: running as opencode (argv0=$CMD_NAME)"
          else
            echo "FAIL: expected argv0=opencode, got $CMD_NAME"
            FAIL=1
          fi

          # Verify sandbox is functional
          assert_exists     "repo dir exists"          "."
          assert_exists     "existing repo file"       "./existing-file"
          assert_ok         "can write to repo"        touch ./write-test
          rm -f ./write-test

          # Verify home isolation still works
          assert_not_exists "~/.secrets hidden"        "$HOME/.secrets"
        '')
      ];
    };

  testScript = common.setup + ''
    machine.succeed("su - testuser -c 'cd ~/projects/myrepo && ajail --command opencode'")
  '';
}
