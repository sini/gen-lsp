{
  description = "gen-lsp: LSP/MCP projection tooling for the gen module stack";

  # nixpkgs is here ONLY for `packages.<system>.mcp` (the Rust MCP server, built with
  # `rustPlatform.buildRustPackage`). It is the conscious tooling-lib deviation: the
  # LIBRARY (./lib) stays DEP-FREE PURE BUILTINS — `lib = import ./lib { }`, no nixpkgs
  # and no gen library threaded in. `ci/tests/purity.nix` pins that invariant on the lib
  # (it no longer scans this flake for `nixpkgs`, since the flake legitimately ships a
  # binary that needs it). gen-merge / gen-aspects are pulled ONLY in ci/ as test fixtures.
  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # DEP-FREE: the projection library takes no arguments and imports nothing from nixpkgs
      # or gen (the purity invariant). Keep this line exactly `import ./lib { }`.
      lib = import ./lib { };

      packages = forAllSystems (pkgs: {
        # The Rust MCP enumeration server. Hermetic: cargo deps vendored from the committed
        # `mcp/Cargo.lock` (fixed-output crate fetches), no interpreter embedded — it drives
        # the customer's `nix` from PATH at runtime. `doCheck = false`: the `cargo test` smoke
        # suite needs `nix` on PATH + a fleet, neither available in the build sandbox — it runs
        # in a devshell instead (the hermetic build only compiles the binary).
        mcp = pkgs.rustPlatform.buildRustPackage {
          pname = "gen-lsp-mcp";
          version = "0.1.0";
          src = ./mcp;
          cargoLock.lockFile = ./mcp/Cargo.lock;
          doCheck = false;
          meta = {
            description = "gen-lsp enumeration MCP server (drives the customer's nix)";
            mainProgram = "gen-lsp-mcp";
            license = nixpkgs.lib.licenses.mit;
          };
        };
      });
    };
}
