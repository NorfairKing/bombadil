{
  # Cachix PULL is already configured by the flake's
  # nixConfig.extra-substituters (= https://bombadil.cachix.org), which NixCI
  # honors -- no credentials needed. NixCI's own `cachix` block here is only for
  # PUSHING and requires a CACHIX_AUTH_TOKEN / CACHIX_SIGNING_KEY repo secret, so
  # it is left out until pushing is enabled.

  # No automatic dependency discovery. We specify the build graph by hand below,
  # which lets NixCI skip the closure analysis it would otherwise run to infer
  # ordering. On a no-op rebuild -- where every job is already a cache hit --
  # that analysis is the only cost, so turning it off makes a no-op as fast as
  # possible.
  #
  # Only real build inputs are declared, to maximise parallelism: clippy, the
  # tests and the binaries do not depend on each other, so they all start as
  # soon as their inputs (`deps` / `inspect`) are ready. The musl binaries
  # compile their own (cross) dependencies, so they only wait on `inspect`,
  # which they embed. fmt, npm-package and the dev shell have no inputs here.
  dependency-discovery = false;
  dependencies = {
    "checks.x86_64-linux.clippy" = [ "packages.x86_64-linux.deps" ];
    "checks.x86_64-linux.tests" = [ "packages.x86_64-linux.deps" ];
    "packages.x86_64-linux.default" = [
      "packages.x86_64-linux.deps"
      "packages.x86_64-linux.inspect"
    ];
    "packages.x86_64-linux.bombadil-static" = [ "packages.x86_64-linux.inspect" ];
    "packages.x86_64-linux.bombadil-aarch64" = [ "packages.x86_64-linux.inspect" ];
  };
}
