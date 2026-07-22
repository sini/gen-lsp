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
#
# The aspect/gen-lib projections and the MCP server package land in later tasks.
{ }:
let
  optionsProjectionLib = import ./options-projection.nix { };
in
{
  inherit (optionsProjectionLib)
    optionsProjection
    positions
    ;
}
