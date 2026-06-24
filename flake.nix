{
  description = "Property-based testing for web UIs";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = "https://bombadil.cachix.org";
    extra-trusted-public-keys = "bombadil.cachix.org-1:6L4epM9zwhEcAwouNgBa8ENtsgLNfedtQgqtdnQhZiM=";
  };

  outputs =
    {
      nixpkgs,
      crane,
      rust-overlay,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      bombadil = pkgs.callPackage ./nix/bombadil.nix {
        inherit crane;
        root = ./.;
      };
    in
    {
      # Each derivation is exposed under exactly ONE attribute so NixCI does not
      # schedule the same build twice. The build artifacts live in `packages`,
      # the validations that are not artifacts (clippy, rustfmt, tests) live in
      # `checks`, and the dev shell lives in `devShells`. NixCI builds all three.
      packages.${system} = {
        default = bombadil.bin;
        bombadil-static = bombadil.binStatic;
        bombadil-aarch64 = bombadil.binAarch64;
        # `deps` is exposed so the dependency-cache isolation can be checked:
        # editing any source file must not change its derivation path.
        inherit (bombadil) inspect npm-package deps;
      };

      checks.${system} = {
        inherit (bombadil)
          clippy
          fmt
          tests
          ;
      };

      devShells.${system}.default = bombadil.devShell;

      apps.${system}.default = {
        type = "app";
        program = "${bombadil.bin}/bin/bombadil";
        meta = bombadil.bin.meta;
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;
    };
}
