{
  description = "Jay - a static site generator for Roc";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc.url = "github:roc-lang/roc";
    naersk.url = "github:nix-community/naersk";
    tree-sitter.url = "github:tree-sitter/tree-sitter/v0.24.5";
    tree-sitter.flake = false;
  };

  outputs = inputs: {
    devShell."x86_64-linux" =
      let
        pkgs = inputs.nixpkgs.legacyPackages."x86_64-linux";
        naersk = pkgs.callPackage inputs.naersk { };

        tree-sitter = naersk.buildPackage {
          src = "${inputs.tree-sitter}";
          postInstall = ''
            PREFIX=$out make install
          '';
        };

        highlight = naersk.buildPackage {
          src = "${inputs.tree-sitter}";
          cargoBuildOptions = defaults: defaults ++ [ "--package=tree-sitter-highlight" ];
          postInstall = ''
            install -D -m644 target/release/libtree_sitter_highlight.a $out/lib/libtree_sitter_highlight.a
            install -D -m644 $src/highlight/include/tree_sitter/highlight.h $out/include/tree_sitter/highlight.h
          '';
        };
      in
      pkgs.mkShell {
        packages = [
          inputs.roc.packages."x86_64-linux".cli
          pkgs.entr # for watch.sh
          pkgs.zig
          pkgs.zls
          tree-sitter
          highlight
        ];

        # Paths for build.zig to find these dependencies.
        TREE_SITTER_PATH = "${tree-sitter}";
        HIGHLIGHT_PATH = "${highlight}";
      };
  };
}
