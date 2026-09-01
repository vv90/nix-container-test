{
  description = "Rust dev container";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      passwd = pkgs.writeTextDir "etc/passwd" ''
        root:x:0:0:root:/root:${pkgs.bashInteractive}/bin/bash
        dev:x:1000:1000:dev:/home/dev:${pkgs.bashInteractive}/bin/bash
      '';

      group = pkgs.writeTextDir "etc/group" ''
        root:x:0:
        dev:x:1000:
      '';
    in
    {
      packages.${system}.default = pkgs.dockerTools.buildLayeredImage {
        name = "rust-dev";
        tag = "latest";

        contents = with pkgs; [
          bashInteractive
          coreutils

          gzip
          curl
          which

          git
          cacert

          rustc
          cargo
          rust-analyzer
          rustfmt
          clippy

          stdenv.cc

          passwd
          group

          codex
        ];

        extraCommands = ''
          mkdir -p home/dev/.cache
          mkdir -p workspaces
        '';

        fakeRootCommands = ''
          chown -R 1000:1000 home/dev
          chown -R 1000:1000 workspaces
        '';

        config = {
          User = "dev";
          WorkingDir = "/workspaces";

          Env = [
            "HOME=/home/dev"
          ];

          Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
        };
      };
    };
}
