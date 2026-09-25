# gen-lsp — LSP/MCP projection tooling for the gen module stack

[![CI](https://github.com/sini/gen-lsp/actions/workflows/ci.yml/badge.svg)](https://github.com/sini/gen-lsp/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT) [![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/sini)

gen-lsp turns a gen fleet's **option / aspect / gen-lib API surface** into editor- and agent-facing
artifacts — the option tree a [nixd](https://github.com/nix-community/nixd) worker walks for hovers and
completions, and a JSON-safe enumeration an MCP server serves to coding agents so they stop hallucinating
option paths and library signatures.

It reads gen *value shapes* — attrsets tagged `{ _type = "option"; … }`, `keySemantics` maps, gen-lib
function bundles — and re-keys them into the exact shapes those tools consume. It is **dep-free pure
`builtins`**: it imports no gen library and no `nixpkgs.lib`.

## The gen ecosystem, and where gen-lsp sits

gen-lsp is a **boundary / tooling library**, the mirror image of
[gen-flake](https://github.com/sini/gen-flake). gen-flake is the one boundary that crosses resolved gen
**values** *out into nixpkgs* to build NixOS systems. gen-lsp is the boundary that crosses those same
value shapes *out to nixd and MCP* — an editor language server and an agent tool surface. Neither is
framework substrate: gen-lsp is **not** in `mkGenLibs`, it drives nothing, it imports nothing. It reads a
shape and re-emits it.

| Library                                            | Role                                                                                                           |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [gen-prelude](https://github.com/sini/gen-prelude) | Pure nixpkgs-lib-free utility base (builtins re-exports + vendored lib utils)                                  |
| [gen-merge](https://github.com/sini/gen-merge)     | Byte-mode module merge engine (`evalModuleTree`, byte-identical to `lib.evalModules` over the priority subset) |
| [gen-schema](https://github.com/sini/gen-schema)   | Typed registries (kinds, instances, collections, refs) re-hosted on gen-merge                                  |
| [gen-aspects](https://github.com/sini/gen-aspects) | Aspect type system (traits, classification, dispatch) re-hosted on gen-merge                                   |
| [gen-flake](https://github.com/sini/gen-flake)     | The nixpkgs boundary — compose purely, inject resolved values, build NixOS systems                             |
| [gen-lsp](https://github.com/sini/gen-lsp)         | **This lib** — the nixd/MCP boundary: project a gen option / aspect / gen-lib surface for editors and agents   |

gen-lsp reads the outputs of the composition engines (option trees from gen-merge, aspect instances from
gen-aspects, lib bundles from anywhere) but depends on none of them — they appear only as CI *fixtures*
(synthetic trees to project against), never as inputs. The purity invariant is pinned by
[`ci/tests/purity.nix`](ci/tests/purity.nix).

## The core idea: one projection, two views

An editor and an agent want the *same* surface rendered two different ways, so gen-lsp projects once and
renders twice:

- **`forNixd` — the in-process view.** An option leaf's `.type` is a full type record carrying functions
  (`check` / `merge` / `getSubOptions`); an aspect node's `getSubOptions` is a function. This view is for
  a **nixd worker's own C++ evaluator** — nixd has the evaluator, so it calls those functions itself and
  expands submodules in-process.
- **`forNixdJSON` — the wire view.** `builtins.toJSON` (what an MCP server's `nix eval --json` runs) cannot
  serialize a function. So the same three trees are re-projected **JSON-safe**: functions dropped, type
  records reduced to their **name** string, derivation / cyclic defaults rendered as placeholders, and
  every synthesized submodule descended into a nested `subOptions` tree.

Keeping *both* views in the library — not one of them in a downstream server — makes gen-lsp the single
source of truth and leaves the MCP server a dumb, thin transport. Both views key their three sections
**generically**: `options` (the option-declaration tree), `aspects` (the aspect registry), `libs` (the
gen-lib API surface). A consumer maps those neutral names onto its own nixd provider names in its own
wiring; gen-lsp never bakes in a consumer's namespace.

## The projections

gen-lsp is three projections plus the two composed views over them.

### `optionsProjection { options }`

Re-keys a gen-merge option tree — `(evalModuleTree { … }).options`, the evaluated `_type == "option"`
leaves — into the tree nixd walks. Each leaf keeps `_type` / `description` / `default`, has gen-schema
**refinement metadata stripped** off its `.type` (a `__schema`-carrying refined type is replaced by its
`baseType`, so `__schema` never leaks), and gains a `declarationPositions` goto list. The walk is
structure-only and reads a leaf's *static* `.type` — it never forces resolved `.config`. A submodule /
`attrsOf` leaf keeps its descent shape (`getSubOptions` / `nestedTypes.elemType`) intact.

### `positions`

The generic `raw → positions` source-site layer the option projection is built on, exposed standalone.
`positions.positionsOf { fields } raw` maps a raw attrset to its fields' declaration sites — nixd goto
records `{ file; line; column; }` — via `builtins.unsafeGetAttrPos`. It knows nothing of options; a later
graph/nav consumer reuses it by naming the fields worth probing on its own nodes. Reading a position is
structural: `unsafeGetAttrPos` reads a field's location metadata, never its value, so it never forces
resolved config. A synthesized leaf carrying no literal source field yields an empty list — never a faked
site.

### `aspectsProjection { keySemantics, structuralKeys ? … } { aspects }`

Synthesizes one nixd submodule option node per declared aspect instance, so an LSP completes aspect names
as submodules and each aspect's user-facing **facets** as sub-options. It is **facet-generic**: the
projectable facets are discovered from the *passed* `keySemantics` map (`{ <key> = { category = "class" | "channel" | "facet"; … }; }`), never hardcoded to a facet name. Only `category == "facet"` keys project;
`class` / `channel` content buckets and structural identity keys (`name` / `meta` / … , overridable via
`structuralKeys`) are skipped. The classifier mirrors den's `classifyKey`. The per-facet value descent is
structural: a settings-shaped facet (a record of `{ default; merge ? … }` field-specs) descends one level
into per-field leaves; any other value projects as a single opaque `raw` leaf.

### `genLibProjection { } { libs }`

Projects a consumer-supplied attrset of gen libraries as an option tree of members — member **names** plus
`builtins.functionArgs` **partial formals**. Thin by design: the gen libs are flat function attrsets
carrying no signature metadata, so this projects names + outermost-pattern formals, never typed
signatures. There is **no hardcoded allowlist** — membership is the consumer's concern (a fleet passes
exactly the libs it wants surfaced). Doc-citation hover text is a deferred enrichment (an empty
description today): a lib's README lives in an input store path and its spec lives in a separate papers
repo, neither reachable from the lib's pure function value. The construction argument is empty but kept
curried to hold future config without a signature break.

### `forNixd { … }` / `forNixdJSON { … }` / `enumerate`

`forNixd` composes the three projections into the in-process surface; `forNixdJSON` re-projects that same
surface JSON-safe for the wire (`= enumerate.fromForNixd (forNixd args)`). `enumerate` also exposes
`sanitize` (JSON-safe-ify a *single* projected section) and `fromForNixd` (a whole surface).

```nix
{
  options,                 # a gen-merge option tree — (evalModuleTree { … }).options
  aspects,                 # an aspect registry (attrset of instances keyed by name)
  keySemantics ? { },      # the facet key-vocabulary map that drives aspect projection
  structuralKeys ? null,   # null ⇒ aspectsProjection's own default list; a list forwards through
  libs ? { },              # the gen-lib bundle to surface
}
```

## Two accuracy notes worth knowing

**Wire depth.** `forNixdJSON` nests **both** submodule flavours, uniformly. A real gen-merge options
submodule implements the introspection half of the nixpkgs `mkOptionType` protocol — `getSubOptions`
evaluates the submodule's module tree and returns its declared option records — and a **synthesized**
aspect facet/field returns its records directly. Both descend through the same call, so an MCP-only
consumer reading `forNixdJSON` gets options-submodule fields as well as aspect fields + defaults.

*Previously* gen-merge stubbed `getSubOptions` to `_prefix: { }` on every type, so a real options
submodule stayed a bare `submodule` type-name on the wire and only a nixd worker could expand it
in-process. That limitation is retired; the in-process `forNixd` view remains available but is no longer
required for this.

**Derivation-safety.** The wire sanitizer carries a recursion **depth bound**, and that bound — not the
derivation tag — is the anti-runaway guard. A genuinely cyclic non-derivation default (self-referential
attrs) would recurse forever; the bound stops it. This is what a bare boolean `deepJsonSafe` predicate
lacked: with no bound it recursed into a derivation's mutually self-referential `all` / `out` / `drvAttrs`
and **stack-overflowed**, which `tryEval` cannot trap. The separate `"<derivation>"` **tag** is for compact,
correct output only — `builtins.toJSON` already special-cases a derivation to its `outPath`, so an untagged
drv serializes to a store-path string (valid but unhelpful, and a wasteful deep force); the tag emits the
clear placeholder instead. The tag is for output quality; the bound is for crash-safety.

## The MCP enumeration server

[`mcp/`](mcp/README.md) is a thin, read-only stdio [Model Context Protocol](https://modelcontextprotocol.io)
server (`nix build .#mcp`, hermetic — Cargo deps vendored from a committed lockfile). It embeds **no** Nix
evaluator: every tool shells out to the customer's own `nix` resolved from `PATH`, so the enumeration is
correct for any interpreter (CppNix, Lix, …) — the surface an agent sees is evaluated by the same `nix` the
customer builds with. It holds no projection logic; all shaping lives in gen-lsp's `forNixdJSON`.

Generalized off a den prototype and parameterized: `--namespace` (default `den`) prefixes the two
consumer-scoped tools and the server id / env var; `--output-attr` (default `den-lsp`) is the flake output
the tools evaluate; `--fleet <ref>` (or `<NS>_FLEET`) is the customer's fleet reference.

| tool                | args                                  | returns                                                                               |
| ------------------- | ------------------------------------- | ------------------------------------------------------------------------------------- |
| `<ns>_schema`       | —                                     | the projected `<ns>.*` option tree as JSON (`_type`, description, type name per leaf) |
| `<ns>_aspects_list` | —                                     | the fleet's declared aspects and, per aspect, its settings (name, default, type)      |
| `gen_lib_signature` | `lib` (required), `member` (optional) | gen-lib member names + `functionArgs` formals; with `member`, one signature           |

`gen_lib_signature` is **not** namespaced — it enumerates the gen substrate surface, the same ecosystem
regardless of what a consumer names its fleet output, whereas the first two describe the consumer's own
trees.

## Consumer wiring

A consumer exposes one namespaced flake output (den names it `den-lsp`) carrying both views over its built
fleet, then points nixd and the MCP server at it:

```nix
# the customer's fleet flake.nix
{
  inputs.gen-lsp.url = "github:sini/gen-lsp";
  outputs = { self, gen-lsp, ... }: {
    den-lsp = {
      # the wire view the MCP server reads
      enumerate = gen-lsp.lib.forNixdJSON {
        options = /* the built option tree */;
        aspects = /* the aspect registry */;
        keySemantics = /* the facet key-semantics map */;
        libs = /* the gen-lib bundle */;
      };
      # the in-process view a nixd worker walks (optional)
      options = gen-lsp.lib.forNixd { /* same inputs */ };
    };
  };
}
```

- Point `nixd.settings.options.<name>.expr` at `<output>.options.<section>`.
- Run the MCP server against `<output>.enumerate` (`--output-attr <output>`, `--namespace <name>`).

A downstream den flakeModule auto-exports this output; the general contract is what gen-lsp documents here.

## Layout

- [`lib/`](lib/) — the dep-free projection library (`nix eval .#lib`): `optionsProjection`, `positions`,
  `aspectsProjection`, `genLibProjection`, and the composed `forNixd` / `forNixdJSON` / `enumerate` views.
- [`mcp/`](mcp/README.md) — the Rust MCP enumeration server (`nix build .#mcp`): a thin stdio transport that
  drives the customer's `nix` over the fleet's `<output-attr>.enumerate` output.
- `ci/` — the CI flake (`nix flake check ./ci`): tests + treefmt on the shared `gen.lib.mkCi` harness.
  `nixpkgs` is a flake input **only** for the MCP binary; the library stays dep-free (`ci/tests/purity.nix`).

## Testing

```bash
nix develop ./ci --command ci # nix-unit suites, guarded
nix flake check ./ci          # nix-unit suites + treefmt; unguarded
cd mcp && cargo test          # the MCP smoke suite (needs `nix` on PATH — the hermetic build sets doCheck = false)
```

`ci` refuses when anything under a declared read root is unknown to git — any extension or name,
`_`-prefixed included — and the remedy is `git add` or a move. The bare `nix-unit --flake ./ci#tests`
and `nix flake check ./ci` are unguarded: they read a git-filtered copy of the tree, so an untracked
cell is silently absent and the run stays green.

The nix-unit suites cover each projection (`options`, `positions`, `aspects`, `genlib`), the composed
`enumerate` views (including the derivation-safety and two-views distinctions), the MCP data contract
(`mcp-enumerate`), and the `purity` invariant that keeps the library dep-free.

## Theoretical foundations

- **Refinement strip** — Cardelli, *Program Fragments, Linking, and Modularization* (POPL 1997), record
  subtyping: a refined type is projected to its base, the gen-schema module bridge.
- **Position threading** — `unsafeGetAttrPos` over a merged option leaf recovers the `mkOption` field source
  site because the option merge threads the declared attrset through (nixpkgs `opt // { … }`).
- **Facet dispatch** — the `keySemantics` / structural-key classifier mirrors den's `classifyKey` three-branch
  key semantics.

See `gen-specs/gen-lsp/REFERENCE.md` in the den-architecture papers repo for the durable contract — exact
projected shapes, forcing/laziness guarantees, and the cross-library contract.
