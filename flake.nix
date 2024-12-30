{
  description = "Jay - a static site generator for Roc";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc.url = "github:roc-lang/roc";
    naersk.url = "github:nix-community/naersk";
    tree-sitter.url = "github:tree-sitter/tree-sitter/v0.24.5";
    tree-sitter.flake = false;

    # Tree-sitter grammars
    tree-sitter-elm.url = "github:elm-tooling/tree-sitter-elm";
    tree-sitter-elm.flake = false;
    tree-sitter-haskell.url = "github:tree-sitter/tree-sitter-haskell";
    tree-sitter-haskell.flake = false;
    tree-sitter-json.url = "github:tree-sitter/tree-sitter-json";
    tree-sitter-json.flake = false;
    tree-sitter-nix.url = "github:nix-community/tree-sitter-nix";
    tree-sitter-nix.flake = false;
    tree-sitter-roc.url = "github:faldor20/tree-sitter-roc";
    tree-sitter-roc.flake = false;
    tree-sitter-ruby.url = "github:tree-sitter/tree-sitter-ruby";
    tree-sitter-ruby.flake = false;
    tree-sitter-rust.url = "github:tree-sitter/tree-sitter-rust/v0.23.2";
    tree-sitter-rust.flake = false;
    tree-sitter-zig.url = "github:tree-sitter-grammars/tree-sitter-zig";
    tree-sitter-zig.flake = false;
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
          name: input:
          let
            uppername = pkgs.lib.toUpper name;
          in
          pkgs.stdenv.mkDerivation {
            name = "tree-sitter-${name}";
            src = "${input}";

            nativeBuildInputs = [ pkgs.nodejs ];

            CFLAGS = [
              "-Isrc"
              "-O2"
            ];
            CXXFLAGS = [
              "-Isrc"
              "-O2"
            ];

            buildPhase = ''
              ${tree-sitter}/bin/tree-sitter generate
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

              # tree-sitter-haskell has a unicode.h file.
              if [[ -e src/unicode.h ]]; then
                cp src/unicode.h $out/src/unicode.h
              fi

              if [[ -d queries ]]; then
                cp -r queries $out
              fi

              mkdir -p $out/include
              cat <<EOF > $out/include/tree-sitter-${name}.h
              #ifndef TREE_SITTER_${uppername}_H_
              #define TREE_SITTER_${uppername}_H_

              typedef struct TSLanguage TSLanguage;

              #ifdef __cplusplus
              extern "C" {
              #endif

              const TSLanguage *tree_sitter_${name}(void);

              #ifdef __cplusplus
              }
              #endif

              #endif // TREE_SITTER_${uppername}_H_
              EOF
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

        grammars = [
          (grammar "elm" inputs.tree-sitter-elm)
          (grammar "haskell" inputs.tree-sitter-haskell)
          (grammar "json" inputs.tree-sitter-json)
          (grammar "nix" inputs.tree-sitter-nix)
          (grammar "roc" inputs.tree-sitter-roc)
          (grammar "ruby" inputs.tree-sitter-ruby)
          (grammar "rust" inputs.tree-sitter-rust)
          (grammar "zig" inputs.tree-sitter-zig)
        ];
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
        TREE_SITTER_GRAMMAR_PATHS = builtins.concatStringsSep ":" grammars;
      };
  };
}
