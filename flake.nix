{
  description = "Enso development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs = { self , flake-utils, nixpkgs,... }:
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
                  zig # 0.14.1
                  zls
                  python312
                  python312Packages.lxml
              ];

              shellHook = ''
                # nop, but in the future perhaps 'exec zsh' or something
              '';
            };
          }
      );
}
