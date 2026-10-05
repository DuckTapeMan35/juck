{
  description = "juck - a Lisp with JSON syntax";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zls.url = "github:zigtools/zls"; # master targets Zig 0.17; no 0.17 release yet
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
      grammarVersion =
        (builtins.fromJSON (builtins.readFile ./tree_sitter_juck/tree-sitter.json)).metadata.version;
    in
    {
      packages = forAllSystems (
        system: pkgs: rec {
          # The tree-sitter parser, generated from grammar.js and compiled.
          tree-sitter-juck = pkgs.tree-sitter.buildGrammar {
            language = "juck";
            version = grammarVersion;
            src = ./tree_sitter_juck;
            generate = true;
          };

          # The Neovim plugin: Lua files, parser and highlight queries.
          juck-nvim = pkgs.vimUtils.buildVimPlugin {
            pname = "juck-nvim";
            version = grammarVersion;
            src = ./editors/nvim;
            postInstall = ''
              mkdir -p $out/parser $out/queries/juck
              cp ${tree-sitter-juck}/parser $out/parser/juck.so
              cp ${tree-sitter-juck}/queries/*.scm $out/queries/juck/
            '';
          };
        }
      );

      devShells = forAllSystems (
        system: pkgs: {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_17 # ezi-gex requires Zig >= 0.17
              zls.packages.${system}.zls
              pkgs.tree-sitter
              pkgs.nodejs
            ];
          };
        }
      );
    };
}
