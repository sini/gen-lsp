# gen-lsp

`gen-lsp` is LSP/MCP projection tooling for the [gen](https://github.com/sini/gen)
module stack — it turns gen-merge option trees and gen-aspects aspect instances into
editor-facing artifacts (hovers, completions, diagnostics) served over the Language
Server and Model Context protocols.

## Design: dep-free pure builtins

The library (`./lib`) is **dep-free pure `builtins`**. It imports no gen library and no
nixpkgs `lib`; it reads gen value *shapes* — attrsets such as `{ _type = "option"; … }`
— directly. This keeps the projection layer decoupled from the engines that produce the
trees it reads. gen-merge and gen-aspects appear only as CI *fixtures* (synthetic trees
to project against), never as runtime inputs. The purity invariant is enforced by
`ci/tests/purity.nix`.

## Status

Scaffold — an empty-but-valid gen library whose CI runs. Later tasks add the projection
library and a Rust MCP server (`packages.mcp`).

## Layout

- `lib/` — the dep-free projection library (`nix eval .#lib`).
- `ci/` — the CI flake (`nix flake check ./ci`): tests + treefmt, on the shared
  `gen.lib.mkCi` harness.
