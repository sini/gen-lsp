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

The projection library — `optionsProjection`, `aspectsProjection`, `genLibProjection`,
and the composed `forNixd` / `forNixdJSON` views — and the Rust MCP enumeration server
(`packages.<system>.mcp`) are in place. `nixpkgs` is a flake input ONLY for the MCP
package; the library stays dep-free (`ci/tests/purity.nix`).

## Layout

- `lib/` — the dep-free projection library (`nix eval .#lib`).
- `mcp/` — the Rust MCP enumeration server (`nix build .#mcp`): a thin stdio transport
  that drives the customer's `nix` over the fleet's `<output-attr>.enumerate` output.
  Generalized off den: `--namespace` / `--output-attr` (see `mcp/README.md`).
- `ci/` — the CI flake (`nix flake check ./ci`): tests + treefmt, on the shared
  `gen.lib.mkCi` harness.
