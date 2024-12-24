{
  description = "Jay - a static site generator for Roc";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc.url = "github:roc-lang/roc";
    naersk.url = "github:nix-community/naersk";
    tree-sitter.url = "github:tree-sitter/tree-sitter/v0.24.5";
    tree-sitter.flake = false;

    # Tree-sitter grammars
    tree-sitter-roc.url = "github:faldor20/tree-sitter-roc";
    tree-sitter-roc.flake = false;
  };

  outputs = inputs: {
    devShell."x86_64-linux" =
      let
        pkgs = inputs.nixpkgs.legacyPackages."x86_64-linux";
        naersk = pkgs.callPackage inputs.naersk { };

        # Nixpkgs contains a buildGrammar helper as well as a lot of prebuilt
        # tree-sitter grammars. Those are compiled as a shared library and omit
        # the header files, so not quite what this project needs.
        grammar =
          input:
          pkgs.stdenv.mkDerivation {
            pname = "tree-sitter-roc";
            version = "0.0.0";
            src = "${input}";

            nativeBuildInputs = [
              pkgs.nodejs
              pkgs.tree-sitter
            ];

            CFLAGS = [
              "-Isrc"
              "-O2"
            ];
            CXXFLAGS = [
              "-Isrc"
              "-O2"
            ];

            buildPhase = ''
              tree-sitter generate
            '';

            installPhase = ''
              mkdir $out

              mkdir -p $out/src/tree_sitter
              cp -r src/tree_sitter/*.h $out/src/tree_sitter
              cp src/parser.c $out/src/parser.c
              if [[ -e src/scanner.cc ]]; then
                cp src/scanner.cc $out/src/scanner.cc
              elif [[ -e src/scanner.c ]]; then
                cp src/scanner.c $out/src/scanner.c
              fi

              if [[ -d queries ]]; then
                cp -r queries $out
              fi

              mkdir -p $out/include
              cp -r bindings/c/*.h $out/include
            '';
          };

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

        tree-sitter-roc = grammar inputs.tree-sitter-roc;
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
        TREE_SITTER_GRAMMAR_PATHS = "${tree-sitter-roc}";
      };
  };
}
