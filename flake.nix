{
  description = "ajail - Run Claude Code in a Linux namespace sandbox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs =
    { nixpkgs, rust-overlay, ... }:
    let
      system = "x86_64-linux";
      overlays = [ (import rust-overlay) ];
      pkgs = import nixpkgs { inherit system overlays; };
      stableToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
      rustPlatform = pkgs.makeRustPlatform {
        cargo = stableToolchain;
        rustc = stableToolchain;
      };

      ajail = rustPlatform.buildRustPackage {
        pname = "ajail";
        version = "0.1.0";
        src = pkgs.lib.cleanSource ./.;
        cargoLock.lockFile = ./Cargo.lock;
      };

      tests = import ./tests { inherit pkgs ajail; };
    in
    {
      overlays.default = final: prev: {
        ajail = final.rustPlatform.buildRustPackage {
          pname = "ajail";
          version = "0.1.0";
          src = final.lib.cleanSource ./.;
          cargoLock.lockFile = ./Cargo.lock;
        };
      };

      packages.${system} = {
        default = ajail;
        ajail = ajail;
      };

      checks.${system} = {
        inherit (tests)
          sandbox
          config-dir
          worktree-merge
          worktree-discard
          ssh-agent-allow
          ssh-agent-deny
          claude-binary
          home-claude
          outside-home
          nix-profile
          docker-socket-allow
          docker-socket-deny
          path-readonly
          dangerous-files-deny
          dangerous-files-allow
          pid-namespace
          unix-sockets-allow
          unix-sockets-deny
          unix-sockets-aarch64-allow
          unix-sockets-aarch64-deny
          ;
      };

      devShells.${system}.default =
        with pkgs;
        mkShell {
          packages = [
            cargo-expand
            cargo-llvm-cov
            cargo-nextest
            clang
            gitleaks
            glib
            nil
            nixd
            nixfmt
            pkg-config
            wild
          ];
          nativeBuildInputs = [ stableToolchain ];
        };
    };
}
