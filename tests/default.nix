{ pkgs, ajail }:

let
  common = import ./common.nix { inherit pkgs ajail; };
  args = { inherit pkgs common; };
in
{
  sandbox = import ./sandbox.nix args;
  config-dir = import ./config-dir.nix args;
  worktree-merge = import ./worktree-merge.nix args;
  worktree-discard = import ./worktree-discard.nix args;
  ssh-agent-allow = (import ./ssh-agent.nix args).allow;
  ssh-agent-deny = (import ./ssh-agent.nix args).deny;
  claude-binary = import ./claude-binary.nix args;
  home-claude = import ./home-claude.nix args;
  outside-home = import ./outside-home.nix args;
  nix-profile = import ./nix-profile.nix args;
  docker-socket-allow = (import ./docker-socket.nix args).allow;
  docker-socket-deny = (import ./docker-socket.nix args).deny;
  path-readonly = import ./path-readonly.nix args;
}
