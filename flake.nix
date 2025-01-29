{
  description = "Jay - a static site generator for Roc";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc.url = "github:roc-lang/roc/0.0.0-alpha2-rolling";
  };

  outputs =
    inputs:
    let
      mkShell =
        target:
        let
          pkgs = inputs.nixpkgs.legacyPackages."${target}";
        in
        pkgs.mkShell {
          packages = [
            inputs.roc.packages."${target}".cli
            pkgs.entr # for watch.sh
            pkgs.zig
            pkgs.zls
          ];
        };
    in
    {
      devShell."x86_64-linux" = mkShell "x86_64-linux";
      devShell."x86_64-darwin" = mkShell "x86_64-darwin";
      devShell."aarch64-darwin" = mkShell "aarch64-darwin";
    };
}
