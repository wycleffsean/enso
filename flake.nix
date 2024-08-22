{
  description = "Enso development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self , flake-utils, nixpkgs ,... }:
      flake-utils.lib.eachDefaultSystem (system:
          let
                pkgs = nixpkgs.legacyPackages.${system};
          in {
            devShells.default = let
              pkgs = import nixpkgs {
                inherit system;
              };
            in pkgs.mkShell {
              # create an environment with nodejs_18, pnpm, and yarn
              packages = with pkgs; [
                  zig
                  python312
              ];

              shellHook = ''
                # nop, but in the future perhaps 'exec zsh' or something
              '';
            };
          }
      );
}
