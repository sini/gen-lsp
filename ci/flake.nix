{
  inputs = {
    gen-harness.url = "github:sini/gen-harness";
    # Fixture deps: gen-merge builds synthetic option trees and gen-aspects builds
    # aspect instances for the projection tests to consume. The library under test
    # (../lib) takes NO inputs — it is dep-free pure builtins (see ci/tests/purity.nix).
    gen-merge.url = "github:sini/gen-merge";
    gen-aspects.url = "github:sini/gen-aspects";
    # nixpkgs is the CI runner's dependency (test harness + treefmt). mkCi reads
    # `inputs.nixpkgs.lib` directly, so the consumer flake must supply it.
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
  };

  outputs =
    inputs@{
      gen-harness,
      gen-merge,
      gen-aspects,
      ...
    }:
    gen-harness.lib.mkCi {
      inherit inputs;
      name = "gen-lsp";
      testModules = ./tests;
      specialArgs = {
        # The library under test.
        genLsp = import ../lib { };
        # Fixture builders for synthetic trees to project.
        merge = gen-merge.lib;
        aspects = gen-aspects.lib;
      };
    };
}
