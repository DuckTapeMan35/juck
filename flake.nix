{
  description = "juck - A LISP dialect with JSON syntax";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zls.url = "github:zigtools/zls";
  };

  outputs =
    {
      self,
      nixpkgs,
      zls,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        system: pkgs: {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_17
              zls.packages.${system}.zls
              pkgs.tree-sitter
              pkgs.nodejs
            ];
          };
        }
      );
    };
}
