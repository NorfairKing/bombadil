{
  # Cachix PULL is already configured by the flake's
  # nixConfig.extra-substituters (= https://bombadil.cachix.org), which NixCI
  # honors -- no credentials needed. NixCI's own `cachix` block here is only for
  # PUSHING and requires a CACHIX_AUTH_TOKEN / CACHIX_SIGNING_KEY repo secret, so
  # it is left out until pushing is enabled.

  # No automatic dependency discovery: declare the build graph by hand (the
  # workspace-member dependency graph) so NixCI skips the closure analysis. That
  # makes a no-op rebuild as fast as possible, while still building each shared
  # workspace crate before the members that depend on it.
  dependency-discovery = false;
  dependencies = {
    "checks.x86_64-linux.bombadil-schema" = [ "checks.x86_64-linux.small-string" ];
    "checks.x86_64-linux.bombadil" = [
      "checks.x86_64-linux.bombadil-schema"
      "checks.x86_64-linux.bombadil-ltl"
    ];
    "checks.x86_64-linux.bombadil-terminal" = [
      "checks.x86_64-linux.bombadil"
      "checks.x86_64-linux.bombadil-schema"
      "checks.x86_64-linux.small-string"
    ];
    "checks.x86_64-linux.bombadil-browser" = [
      "checks.x86_64-linux.bombadil"
      "checks.x86_64-linux.bombadil-browser-keys"
      "checks.x86_64-linux.bombadil-schema"
      "checks.x86_64-linux.bombadil-ltl"
    ];
    "checks.x86_64-linux.bombadil-browser-integration-tests" = [
      "checks.x86_64-linux.bombadil"
      "checks.x86_64-linux.bombadil-browser"
      "checks.x86_64-linux.bombadil-ltl"
      "checks.x86_64-linux.bombadil-schema"
    ];
    "packages.x86_64-linux.default" = [
      "checks.x86_64-linux.bombadil"
      "checks.x86_64-linux.bombadil-browser"
      "checks.x86_64-linux.bombadil-ltl"
      "checks.x86_64-linux.bombadil-browser-keys"
      "checks.x86_64-linux.bombadil-schema"
      "checks.x86_64-linux.bombadil-terminal"
    ];
  };
}
