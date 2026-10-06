{
  description = "brainfuck2dir: brainfuck source as directory trees. The converter itself is a 98KB brainfuck program; Zig is just the VM. NixOS and home-manager modules included.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # Zig cross-compiles from any host; static musl targets need no
      # cross toolchain, no sysroot, nothing.
      zigStaticTarget = {
        x86_64-linux = "x86_64-linux-musl";
        aarch64-linux = "aarch64-linux-musl";
      };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          brainfuck2dir = pkgs.callPackage ./package.nix { };
          default = self.packages.${system}.brainfuck2dir;
        }
        // lib.optionalAttrs (builtins.hasAttr system zigStaticTarget) {
          brainfuck2dir-static = pkgs.callPackage ./package.nix {
            zigTarget = zigStaticTarget.${system};
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${system}.brainfuck2dir;
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (self.packages.${system}) brainfuck2dir;
          zig-tests = pkgs.callPackage ./nix/zig-tests.nix { };
          bf-regen = pkgs.callPackage ./nix/bf-regen.nix { };
          smoke = pkgs.callPackage ./nix/smoke.nix {
            brainfuck2dir = self.packages.${system}.brainfuck2dir;
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig
              pkgs.zls
              pkgs.nixfmt
              pkgs.python3
            ];
            shellHook = ''
              echo "brainfuck2dir devshell (zig $(zig version))"
              echo "  zig build test          run unit tests"
              echo "  python3 tools/gen_b2d.py > src/b2d.bf   regenerate the converter"
              echo "  nix fmt                 format nix files"
            '';
          };
        }
      );

      overlays.default = final: _prev: {
        brainfuck2dir = final.callPackage ./package.nix { };
      };

      nixosModules.default = import ./nix/nixos-module.nix;
      homeManagerModules.default = import ./nix/home-manager-module.nix;

      # nixfmt 1.5 deprecated bare (no-argument) invocation; `nix fmt`
      # without paths calls the formatter with zero args, so wrap it:
      # no args = format every .nix file in the tree.
      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.writeShellScriptBin "nixfmt" ''
          if [ $# -eq 0 ]; then
            find . -name '*.nix' \
              -not -path './.git/*' \
              -not -path './.zig-cache/*' \
              -not -path './result*' \
              -print0 | xargs -0 ${lib.getExe pkgs.nixfmt}
          else
            exec ${lib.getExe pkgs.nixfmt} "$@"
          fi
        ''
      );
    };
}
