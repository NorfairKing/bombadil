{
  lib,
  pkgs,
  callPackage,
  crane,
  root,
  pkg-config,
  zig_0_15,
  git,
  chromium,
  freefont_ttf,
  makeFontsConf,
  rustPlatform,
  fetchCrate,
  buildWasmBindgenCli,
}:
let
  # Rust toolchain (oxalica/rust-overlay): stable, with the wasm32 target for
  # the inspect UI and both musl targets for the static release binaries.
  # Defined as a function of `pkgs` so that crane can splice a correctly
  # cross-targeted toolchain for the musl builds.
  mkToolchain =
    p:
    p.rust-bin.stable.latest.default.override {
      targets = [
        "wasm32-unknown-unknown"
        "x86_64-unknown-linux-musl"
        "aarch64-unknown-linux-musl"
      ];
    };
  rustToolchain = mkToolchain pkgs;

  # One crane lib per target. The native one drives the dev build, clippy, the
  # tests and the wasm inspect UI; the musl ones cross-compile the static
  # release binaries.
  craneLib = (crane.mkLib pkgs).overrideToolchain mkToolchain;
  craneLibStatic = (crane.mkLib pkgs.pkgsCross.musl64).overrideToolchain mkToolchain;
  craneLibAarch64 = (crane.mkLib pkgs.pkgsCross.aarch64-multiplatform-musl).overrideToolchain mkToolchain;

  # Cargo.toml / Cargo.lock are the source of truth for dependency pins; read
  # them so we don't duplicate versions and revisions that already live there.
  cargoToml = builtins.fromTOML (builtins.readFile (root + "/Cargo.toml"));
  cargoLock = builtins.fromTOML (builtins.readFile (root + "/Cargo.lock"));
  lockedPackage =
    name: lib.findFirst (p: p.name == name) (throw "${name} not found in Cargo.lock") cargoLock.package;

  # wasm-bindgen-cli must match the `wasm-bindgen` crate version exactly, or
  # trunk's offline build fails the schema check. Take that version straight from
  # Cargo.lock; nixpkgs only ships 0.2.121 so we build it from crates.io. The
  # hashes are specific to the version -- if the lock bumps wasm-bindgen they
  # will mismatch, which is the signal to refresh them.
  wasmBindgenCli = buildWasmBindgenCli rec {
    src = fetchCrate {
      pname = "wasm-bindgen-cli";
      inherit (lockedPackage "wasm-bindgen") version;
      hash = "sha256-zRawtjxMOdTMX+mZaiNR3YYfTiZJhf9qj7kXSSeMxrc=";
    };
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit src;
      inherit (src) pname version;
      hash = "sha256-aZCfgR23Qb0Pn4Mm4ToMtuuRQqSJjXCR9li/VvP5CTM=";
    };
  };

  # Ghostty source, derived from the source of truth instead of duplicated. The
  # libghostty repo + rev come straight from Cargo.toml; the ghostty commit is
  # the GHOSTTY_COMMIT constant in that crate's build.rs (the only place it is
  # recorded). Provided as a vendored tree so the build script skips its in-tree
  # `git clone` (no network in the sandbox), and fetched by rev so there is no
  # separate hash to keep in sync.
  libghosttyDep = cargoToml.workspace.dependencies.libghostty-vt;
  libghosttySrc = builtins.fetchGit {
    url = libghosttyDep.git;
    inherit (libghosttyDep) rev;
  };
  ghosttyCommit =
    let
      buildRs = builtins.readFile "${libghosttySrc}/crates/libghostty-vt-sys/build.rs";
      # const GHOSTTY_COMMIT: &str = "<hex>";
      afterDecl = lib.elemAt (lib.splitString ''GHOSTTY_COMMIT: &str = "'' buildRs) 1;
    in
    lib.head (lib.splitString "\"" afterDecl);
  ghosttySrc = builtins.fetchGit {
    url = "https://github.com/ghostty-org/ghostty";
    rev = ghosttyCommit;
  };
  # Pre-fetched Zig package cache for ghostty's build.zig, passed via --system so
  # the Zig build stays hermetic.
  ghosttyZigDeps = callPackage "${ghosttySrc}/build.zig.zon.nix" {
    name = "bombadil-ghostty-zig-deps";
  };
  ghosttyEnv = {
    GHOSTTY_SOURCE_DIR = "${ghosttySrc}";
    GHOSTTY_ZIG_SYSTEM_DIR = "${ghosttyZigDeps}";
  };

  # Source for the real builds: keep Rust/cargo sources plus the non-Rust assets
  # that the crates embed (TypeScript specs, snapshots, HTML, fixtures, ...).
  #
  # The *dependency* derivations below do NOT use this directly: crane's
  # buildDepsOnly re-derives a dummy source from it that contains only Cargo.toml
  # / Cargo.lock / .cargo/config.toml (with every .rs replaced by a stub). That
  # is what makes the dependency cache immune to source changes.
  src = lib.cleanSourceWith {
    src = root;
    name = "bombadil-source";
    filter =
      path: type:
      (lib.hasSuffix ".ts" path)
      || (lib.hasSuffix ".json" path)
      || (lib.hasSuffix ".snap" path)
      || (lib.hasSuffix ".html" path)
      || (lib.hasSuffix ".xml" path)
      || (lib.hasSuffix ".js" path)
      || (lib.hasSuffix ".css" path)
      || (lib.hasSuffix ".txt" path)
      || (lib.hasSuffix ".dat" path)
      || (craneLib.filterCargoSources path type);
  };

  # Arguments shared by every native (build-host) derivation. The ghostty
  # toolchain is needed to compile bombadil-terminal's libghostty-vt build
  # script.
  commonArgs = {
    inherit src;
    strictDeps = true;
    nativeBuildInputs = [
      pkg-config
      zig_0_15
      git
    ];
    # Exclude the inspect crate from workspace builds: it targets wasm32 and is
    # built separately (see `inspect` below).
    cargoExtraArgs = "--workspace --exclude bombadil-inspect";
  }
  // ghosttyEnv;

  # The single shared dependency derivation for native builds. Reused by the dev
  # binary, clippy and the test suite. Building the inspect UI is skipped here
  # (the build script writes a placeholder) so this needs no wasm tooling.
  deps = craneLib.buildDepsOnly (
    commonArgs
    // {
      pname = "bombadil-deps";
      version = "0.0.0";
      BOMBADIL_SKIP_INSPECT_BUILD = "1";
    }
  );

  # wasm dependency build for the inspect UI. Built explicitly (rather than
  # letting buildTrunkPackage derive it) so the trunk-specific build command
  # below does not leak into the dependency derivation.
  inspectDeps = craneLib.buildDepsOnly {
    inherit src;
    pname = "bombadil-inspect-deps";
    version = "0.0.0";
    cargoExtraArgs = "--package bombadil-inspect";
    CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
    doCheck = false;
  };

  inspect = craneLib.buildTrunkPackage {
    inherit src;
    pname = "bombadil-inspect";
    version = "0.1.0";
    cargoArtifacts = inspectDeps;
    trunkIndexPath = "lib/bombadil-inspect/index.html";
    wasm-bindgen-cli = wasmBindgenCli;
    # The inspect index.html declares its Rust crate without an explicit href, so
    # trunk resolves the crate from the manifest in the working directory. Run it
    # from the crate directory (as the CLI's build.rs does) rather than the repo
    # root, whose Cargo.toml is a virtual workspace manifest with no package.
    buildPhaseCargoCommand = ''
      local profileArgs=""
      if [[ "$CARGO_PROFILE" == "release" ]]; then
        profileArgs="--release=true"
      fi
      ( cd lib/bombadil-inspect && trunk build $profileArgs index.html )
    '';
  };

  # Drop the prebuilt inspect UI where the CLI build script expects it, then tell
  # the build script to skip running trunk. The script only writes its
  # placeholder when target/inspect/index.html is absent, so the real UI wins.
  embedInspect = ''
    mkdir -p target/inspect
    cp -r ${inspect}/. target/inspect/
    chmod -R +w target/inspect
  '';

  # Build a release CLI binary for a given crane lib / rust target. Linux
  # targets are statically linked against musl.
  mkBin =
    {
      cl,
      pname,
      cargoArtifacts,
      cargoTarget ? null,
    }:
    cl.buildPackage (
      commonArgs
      // {
        inherit pname cargoArtifacts;
        cargoExtraArgs = "--package bombadil-cli";
        doCheck = false;
        BOMBADIL_SKIP_INSPECT_BUILD = "1";
        preBuild = embedInspect;
        meta = {
          mainProgram = "bombadil";
          description = "Property-based testing for web UIs, autonomously exploring and validating correctness properties, finding harder bugs earlier.";
        };
      }
      // lib.optionalAttrs (cargoTarget != null) {
        CARGO_BUILD_TARGET = cargoTarget;
        CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
      }
    );

  mkCrossDeps =
    {
      cl,
      pname,
      cargoTarget,
    }:
    cl.buildDepsOnly (
      commonArgs
      // {
        inherit pname;
        version = "0.0.0";
        BOMBADIL_SKIP_INSPECT_BUILD = "1";
        CARGO_BUILD_TARGET = cargoTarget;
        CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
      }
    );

  staticDeps = mkCrossDeps {
    cl = craneLibStatic;
    pname = "bombadil-static-deps";
    cargoTarget = "x86_64-unknown-linux-musl";
  };
  aarch64Deps = mkCrossDeps {
    cl = craneLibAarch64;
    pname = "bombadil-aarch64-deps";
    cargoTarget = "aarch64-unknown-linux-musl";
  };
in
{
  inherit deps inspect;

  # Native dev binary (the default package).
  bin = mkBin {
    cl = craneLib;
    pname = "bombadil";
    cargoArtifacts = deps;
  };

  # Static musl release binaries.
  binStatic = mkBin {
    cl = craneLibStatic;
    pname = "bombadil-static";
    cargoArtifacts = staticDeps;
    cargoTarget = "x86_64-unknown-linux-musl";
  };
  binAarch64 = mkBin {
    cl = craneLibAarch64;
    pname = "bombadil-aarch64";
    cargoArtifacts = aarch64Deps;
    cargoTarget = "aarch64-unknown-linux-musl";
  };

  clippy = craneLib.cargoClippy (
    commonArgs
    // {
      inherit (deps) version;
      cargoArtifacts = deps;
      pname = "bombadil-clippy";
      BOMBADIL_SKIP_INSPECT_BUILD = "1";
      cargoClippyExtraArgs = "--all-targets -- -D warnings";
    }
  );

  fmt = craneLib.cargoFmt {
    inherit src;
    pname = "bombadil-fmt";
  };

  tests = craneLib.cargoTest (
    commonArgs
    // {
      cargoArtifacts = deps;
      pname = "bombadil-tests";
      # Browser integration tests need an outbound-isolated network namespace
      # that the Nix sandbox does not provide; run the rest of the workspace.
      cargoExtraArgs = "--workspace --exclude bombadil-inspect --exclude bombadil-browser-integration-tests";
      BOMBADIL_SKIP_INSPECT_BUILD = "1";
      nativeCheckInputs = [ chromium ];
      preCheck = ''
        export FONTCONFIG_FILE=${makeFontsConf { fontDirectories = [ freefont_ttf ]; }}
        export HOME=$(mktemp -d)
        mkdir -p $HOME/.cache $HOME/.config $HOME/.local $HOME/.pki
        mkdir -p $HOME/.config/google-chrome/Crashpad
        export XDG_CONFIG_HOME=$HOME/.config
        export XDG_CACHE_HOME=$HOME/.cache
        export INSTA_WORKSPACE_ROOT=$(pwd)
        export INSTA_UPDATE=no
        export CHROME=${lib.getExe chromium}
      '';
    }
  );

  npm-package = callPackage ./npm-package.nix { inherit src; };

  devShell = pkgs.mkShell {
    inputsFrom = [ ];
    packages = [
      rustToolchain
      pkgs.rust-analyzer
      wasmBindgenCli
      pkgs.trunk
      pkgs.binaryen
      zig_0_15
      pkg-config
      git
      chromium
    ];
    GHOSTTY_SOURCE_DIR = "${ghosttySrc}";
    GHOSTTY_ZIG_SYSTEM_DIR = "${ghosttyZigDeps}";
    CHROME = lib.getExe chromium;
  };
}
