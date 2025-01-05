{
  description = "Jay - a static site generator for Roc";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc.url = "github:roc-lang/roc";
  };

  outputs = inputs: {
    devShell."x86_64-linux" =
      let
        pkgs = inputs.nixpkgs.legacyPackages."x86_64-linux";
      in
      pkgs.mkShell {
        packages = [
          inputs.roc.packages."x86_64-linux".cli
          pkgs.entr # for watch.sh
          pkgs.zig
          pkgs.zls
        ];
      };
  };
}
