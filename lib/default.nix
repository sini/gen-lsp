# gen-lsp — LSP/MCP projection tooling for the gen module stack.
#
# This library is DEP-FREE PURE BUILTINS: it imports NO gen library and NO nixpkgs
# `lib`. It reads gen value *shapes* — attrsets such as `{ _type = "option"; ... }`
# produced by gen-merge option trees and gen-aspects aspect instances — using only
# `builtins`. gen-merge / gen-aspects appear only as CI test *fixtures* (synthetic
# trees to project against), never as inputs here, which is why the aggregator takes
# no arguments.
#
# Surface so far:
#   * `optionsProjection { options }` — re-key a gen-merge option tree into the shape
#     a Nix LSP (nixd) walks: `_type == "option"` leaves with refinement-stripped
#     `.type` + a `declarationPositions` goto list.
#   * `positions` — the generic `raw -> positions` source-site layer the projection
#     attributes with, standalone-reusable by later graph/nav consumers.
#   * `aspectsProjection { keySemantics, structuralKeys ? … } { aspects }` — project
#     aspect instances into per-aspect submodule option nodes, facet-generic (the
#     projectable facets are discovered from the consumer's `keySemantics` map, never
#     hardcoded to a facet name).
#   * `genLibProjection { } { libs }` — project a consumer-supplied attrset of gen
#     libraries into an option-tree of members (names + `functionArgs` formals); no
#     hardcoded allowlist, membership is the consumer's concern.
#   * `forNixd { options, aspects, keySemantics ? , structuralKeys ? , libs ? }` — the
#     composed IN-PROCESS view (the three projections, functions intact, for a nixd
#     worker's own evaluator).
#   * `forNixdJSON { … }` / `enumerate` — the composed WIRE view: the same three trees
#     re-projected JSON-safe (functions dropped, derivation/cyclic defaults rendered as
#     placeholders) for an MCP server's `nix eval --json`.
#
# The MCP server package lands in a later task.
{ }:
let
  optionsProjectionLib = import ./options-projection.nix { };
  aspectsProjectionLib = import ./aspects-projection.nix { };
  genLibProjectionLib = import ./genlib-projection.nix { };
  enumerateLib = import ./enumerate.nix { };
in
{
  inherit (optionsProjectionLib)
    optionsProjection
    positions
    ;
  inherit (aspectsProjectionLib)
    aspectsProjection
    ;
  inherit (genLibProjectionLib)
    genLibProjection
    ;
  inherit (enumerateLib)
    enumerate
    forNixd
    forNixdJSON
    ;
}
