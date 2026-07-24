# Purity invariant: the gen-lsp *library* (./lib) is DEP-FREE PURE BUILTINS. It must
# import NO `nixpkgs.lib` and NO gen-* library — it reads gen value *shapes* using only
# `builtins`. This pins "pure" as a checked property, not an aspiration: a stray `lib.foo`,
# an `evalModules`, a `fetchTree` dep-dance, or a `gen-<lib>` input creeping into the
# library source fails CI.
#
# Scope: lib/**.nix + default.nix (the LIBRARY and its dep-free entry). NOT ci/ (the test
# harness legitimately uses nixpkgs.lib + gen-merge / gen-aspects fixtures) and — since
# `packages.mcp` landed — NOT flake.nix: the flake now LEGITIMATELY carries a `nixpkgs`
# input to build the Rust MCP binary. The invariant is "the LIB is dep-free," not "the
# flake has zero nixpkgs". So the flake is checked by a DIFFERENT assertion below: its
# `lib` output must be exactly `import ./lib { }` (empty args → nothing threaded into the
# lib), which — together with the token scan proving no nixpkgs/gen reference EXISTS in the
# lib source — is what keeps nixpkgs unreachable from the library.
{ genPrelude, lib, ... }:
let
  libDir = ../../lib;

  # Comment-stripped source: drop everything from the first `#` on each line. Safe here
  # because `#` appears only in comments across these files (no `#` in string literals),
  # so documentation may freely mention forbidden tokens without tripping the invariant.
  stripComments =
    text:
    lib.concatStringsSep "\n" (
      map (line: lib.head (lib.splitString "#" line)) (lib.splitString "\n" text)
    );

  nixFiles = lib.filter (lib.hasSuffix ".nix") (lib.attrNames (builtins.readDir libDir));
  sources =
    map (name: {
      inherit name;
      code = stripComments (builtins.readFile (libDir + "/${name}"));
    }) nixFiles
    ++ [
      {
        name = "default.nix";
        code = stripComments (builtins.readFile ../../default.nix);
      }
    ];

  # Tokens that signal a nixpkgs-lib tether, the module-system (Korora-class) tier, a
  # dep-fetch dance, or a gen-ecosystem library import. gen-lsp reads value shapes with
  # `builtins` only, so none of these may appear in the library source.
  forbidden = [
    "nixpkgs" # a nixpkgs flake input / reference
    "lib." # any nixpkgs lib call (lib.types, lib.mapAttrs, …)
    "{ lib }" # the `{ lib }` parameter signature
    "{ lib," # the `{ lib, … }` parameter signature
    "evalModules" # module-system tier
    "mkOption" # module-system tier
    "fetchTree" # no dep-fetch dance — the lib takes no deps
    "gen-prelude" # gen-ecosystem library imports
    "gen-types"
    "gen-merge"
    "gen-schema"
    "gen-aspects"
    "gen-algebra"
    "gen-resolve"
  ];

  violations = lib.concatMap (
    src:
    map (tok: "${src.name}: '${tok}'") (lib.filter (tok: genPrelude.hasInfix tok src.code) forbidden)
  ) sources;

  # The flake's `lib` output must remain the bare, empty-args import of the dep-free
  # library — nothing (nixpkgs, gen) threaded in. With the token scan above proving the
  # lib source references no forbidden dep, this closes the loop: the library is both
  # dep-free in its own source AND instantiated with no deps by the flake.
  flakeSource = stripComments (builtins.readFile ../../flake.nix);
  libOutputIsDepFree = genPrelude.hasInfix "lib = import ./lib { };" flakeSource;
in
{
  flake.tests.purity = {
    test-library-source-is-dep-free-pure-builtins = {
      expr = violations;
      expected = [ ];
    };

    # The flake exposes the library via the empty-args `import ./lib { }` (no nixpkgs/gen
    # passed into the lib), even though the flake itself now carries a `nixpkgs` input for
    # the `packages.mcp` binary.
    test-flake-lib-output-is-dep-free-import = {
      expr = libOutputIsDepFree;
      expected = true;
    };
  };
}
