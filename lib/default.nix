# gen-lsp — LSP/MCP projection tooling for the gen module stack.
#
# This library is DEP-FREE PURE BUILTINS: it imports NO gen library and NO nixpkgs
# `lib`. It reads gen value *shapes* — attrsets such as `{ _type = "option"; … }`
# produced by gen-merge option trees and gen-aspects aspect instances — using only
# `builtins`. gen-merge / gen-aspects appear only as CI test *fixtures* (synthetic
# trees to project against), never as inputs here, which is why the aggregator takes
# no arguments.
#
# The projection functions and the MCP server package land in later tasks; this is
# the empty-but-valid aggregator.
{ }:
{
}
