{
  description = "bombadil — crate2nix (IFD) experiment: per-crate derivations, no committed Cargo.nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    crate2nix.url = "github:nix-community/crate2nix";
  };

  nixConfig = {
    extra-substituters = "https://bombadil.cachix.org";
    extra-trusted-public-keys = "bombadil.cachix.org-1:6L4epM9zwhEcAwouNgBa8ENtsgLNfedtQgqtdnQhZiM=";
  };

  outputs =
    {
      nixpkgs,
      crate2nix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # Ghostty source, derived from the source of truth instead of duplicated:
      # the commit is GHOSTTY_COMMIT in libghostty-vt-sys's build.rs, read from
      # the libghostty checkout at the rev Cargo.lock locks. Fetched by rev so
      # there is no separate hash to keep in sync.
      cargoLock = builtins.fromTOML (builtins.readFile ./Cargo.lock);
      libghosttyGit =
        builtins.match "git\\+(https://[^?]+)\\?rev=([0-9a-f]+).*"
          (builtins.head (builtins.filter (p: p.name == "libghostty-vt-sys") cargoLock.package)).source;
      libghosttySrc = builtins.fetchGit {
        url = builtins.elemAt libghosttyGit 0;
        rev = builtins.elemAt libghosttyGit 1;
      };
      # Match the `const GHOSTTY_COMMIT: &str = "<hex>"` declaration specifically
      # (the `:` excludes the bare-identifier uses elsewhere in build.rs).
      ghosttyCommit = builtins.head (
        builtins.match ".*GHOSTTY_COMMIT:[^\"]*\"([0-9a-f]+)\".*" (
          builtins.readFile "${libghosttySrc}/crates/libghostty-vt-sys/build.rs"
        )
      );
      ghosttySrc = builtins.fetchGit {
        url = "https://github.com/ghostty-org/ghostty";
        rev = ghosttyCommit;
      };
      ghosttyZigDeps = pkgs.callPackage "${ghosttySrc}/build.zig.zon.nix" {
        name = "bombadil-ghostty-zig-deps";
      };

      # crate2nix generates a Cargo.nix from Cargo.lock *at evaluation time* via
      # import-from-derivation. Nothing is committed to the repo. This is the
      # whole point of this branch: per-crate derivations, paid for with IFD.
      #
      # crate2nix is patched (nix/crate2nix-git-workspace.patch) so that git
      # dependencies which are cargo workspace members (boa_engine, from the boa
      # monorepo) vendor with a self-contained manifest; otherwise generation
      # fails with "failed to find a workspace root".
      crate2nixPatched = pkgs.applyPatches {
        name = "crate2nix-git-workspace";
        src = crate2nix;
        patches = [ ./nix/crate2nix-git-workspace.patch ];
      };
      crate2nixTools = import "${crate2nixPatched}/tools.nix" { inherit pkgs; };
      cargoNix =
        import
          (crate2nixTools.generatedCargoNix {
            name = "bombadil";
            src = ./.;
          })
          {
            inherit pkgs;
            buildRustCrateForPkgs =
              p:
              p.buildRustCrate.override {
                defaultCrateOverrides = p.defaultCrateOverrides // {
                  # libghostty-vt-sys drives a Zig build of ghostty; give it the
                  # toolchain, the vendored source and a writable Zig cache.
                  libghostty-vt-sys = attrs: {
                    nativeBuildInputs = (attrs.nativeBuildInputs or [ ]) ++ [
                      p.zig_0_15
                      p.pkg-config
                      p.git
                    ];
                    GHOSTTY_SOURCE_DIR = "${ghosttySrc}";
                    GHOSTTY_ZIG_SYSTEM_DIR = "${ghosttyZigDeps}";
                    preConfigure = ''
                      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
                      export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
                    '';
                  };
                  # Skip building the wasm inspect UI in the CLI build script (it
                  # shells out to trunk); the build script writes a placeholder.
                  # crate2nix builds each crate in isolation, so the workspace-
                  # relative `../../target/inspect` path used by build.rs and the
                  # include_dir! macro escapes the writable build directory. Rewrite
                  # it to a crate-local path so the placeholder can be created and
                  # embedded.
                  bombadil-cli = attrs: {
                    BOMBADIL_SKIP_INSPECT_BUILD = "1";
                    prePatch = (attrs.prePatch or "") + ''
                      sed -i 's#\.\./\.\./target/inspect#target/inspect#g' \
                        build.rs src/inspect_server.rs
                    '';
                  };
                };
              };
          };
    in
    {
      packages.${system}.default = cargoNix.workspaceMembers."bombadil-cli".build;

      # Each workspace member built as its own check (one derivation per crate),
      # except: bombadil-cli (already the default package) and bombadil-inspect
      # (a wasm32-only cdylib that does not build for the host).
      checks.${system} = builtins.mapAttrs (_: m: m.build) (
        builtins.removeAttrs cargoNix.workspaceMembers [
          "bombadil-cli"
          "bombadil-inspect"
        ]
      );

      apps.${system}.default = {
        type = "app";
        program = "${cargoNix.workspaceMembers."bombadil-cli".build}/bin/bombadil";
      };
    };
}
