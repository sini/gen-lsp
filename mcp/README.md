# `gen-lsp-mcp` — the gen-lsp enumeration MCP server

A thin, read-only [Model Context Protocol](https://modelcontextprotocol.io) server (stdio) that exposes a
gen-stack fleet's **option / aspect / gen-lib API surface** to coding agents as enumeration tools. It kills
agent API hallucination: instead of guessing a fleet's option paths or gen-lib signatures, an agent calls a
tool and gets the real, projected surface for the customer's actual fleet.

## Design principle (load-bearing): interpreter-agnostic — drive the customer's `nix`

The server embeds **no** Nix evaluator. Every tool shells out to `nix` resolved from `PATH` — whatever
interpreter the customer runs (CppNix, Lix, …) — as a subprocess:

```
nix eval --impure --json --extra-experimental-features "nix-command flakes" --expr '<expr>'
```

That is what keeps the enumeration correct for every customer: the surface an agent sees is evaluated by
the same `nix` the customer builds with. The server never references a specific interpreter binary or path.

## Generalized surface: `--namespace` / `--output-attr`

The server is a generalized extraction of a den-specific prototype. Two flags parameterize the consumer
surface (with den-flavored defaults so the out-of-the-box behavior matches the original):

| flag | default | effect |
| ---- | ------- | ------ |
| `--namespace <ns>` | `den` | prefixes the two consumer-scoped tool names, the `serverInfo` id, and the fleet env var. |
| `--output-attr <attr>` | `den-lsp` | the flake output attr the tools read (`(getFlake <fleet>).<output-attr>.enumerate.<section>`). |
| `--fleet <ref>` | — | the customer's fleet reference (flake ref / path); falls back to the `<NS>_FLEET` env var (`DEN_FLEET` at the default namespace, `GEN_FLEET` under `--namespace gen`, …). |

## The three tools

Tool wire names are underscore-only — MCP and the Anthropic tool API validate names against
`^[a-zA-Z0-9_-]{1,128}$`, so a dotted name would be rejected by the clients (Claude/agents) this server
targets. The composed namespaced names are re-validated at startup (a bad `--namespace` fails fast).

| tool | args | returns |
| ---- | ---- | ------- |
| `<ns>_schema` | — | the projected option tree (`<ns>.*` options) as JSON — each leaf carries `_type`, a description, and its option type name. |
| `<ns>_aspects_list` | — | the fleet's declared aspects and, per aspect, its settings (name, default, type). |
| `gen_lib_signature` | `lib` (required), `member` (optional) | gen substrate library member names + their `functionArgs` formals; with `member`, one member's signature. |

**Why `gen_lib_signature` is NOT namespaced.** The first two tools describe the *consumer's own* option and
aspect trees, so they carry the consumer's namespace. `gen_lib_signature` enumerates the gen substrate library
surface — the same gen ecosystem regardless of what the consumer names its fleet output — so it stays a fixed
name. (At the default namespace all three happen to read `den`-flavored defaults; only the first two rename.)

Each tool selects into the fleet's `<output-attr>.enumerate` output (gen-lsp's generic `options` / `aspects` /
`libs` sections) and `nix eval --json`s it:

- `<ns>_schema` → `(builtins.getFlake "<fleet>")."<output-attr>".enumerate.options`
- `<ns>_aspects_list` → `(builtins.getFlake "<fleet>")."<output-attr>".enumerate.aspects`
- `gen_lib_signature` → `(builtins.getFlake "<fleet>")."<output-attr>".enumerate.libs.<lib>[.<member>]`

`lib` / `member` are charset-validated (`[A-Za-z0-9_'-]`) and quoted into the attr-path, so no argument can
inject Nix; the fleet ref and output attr are Nix-string-escaped (backslash / quote / `$`).

## Fleet wiring

The fleet exposes ONE namespaced flake output (the `--output-attr`, default `den-lsp`) carrying both views of
the projection — `enumerate` (the JSON-safe view this server reads) and `options` (the raw view a nixd editor
worker walks):

```nix
# the customer's fleet flake.nix
{
  inputs.gen-lsp.url = "github:sini/gen-lsp";
  outputs = { self, gen-lsp, ... }: {
    den-lsp = {
      enumerate = gen-lsp.lib.forNixdJSON {
        options = /* the built option tree */;
        aspects = /* the aspect registry */;
        keySemantics = /* the facet key-semantics map */;
        libs = /* the gen-lib bundle */;
      };
      options = gen-lsp.lib.forNixd { /* same inputs */ };  # (optional) the nixd editor surface
    };
  };
}
```

A locked flake ref (`github:…`, or a committed local flake) is the real customer case — its `getFlake` is
pure; the server passes `--impure` only so an unlocked/dirty local path also works during development.

`gen-lsp.lib.forNixdJSON` is the JSON-safe **enumeration view** over the projections. It exists because the
raw `forNixd` projections are built for a nixd editor worker's **in-process** walk — an option leaf's `.type`
is a function-carrying type record, an aspect node's `getSubOptions` is a function — so `builtins.toJSON`
(what `nix eval --json` runs) cannot serialize them. The enumeration view re-projects each tree into JSON-safe
records (leaf → `_type`/description/type-name/JSON-safe default/formals; aspect facets descended recursively to
their field defaults; libs pass through). Real options submodules nest on the wire too — gen-merge implements
`getSubOptions` as part of the nixpkgs `mkOptionType` protocol, so both they and synthesized aspect facets
descend through the same call. (They did not, while gen-merge stubbed that method; a nixd worker was needed.)

## Build / run

```
nix build .#mcp                                       # build the binary (Nix, hermetic — vendored Cargo.lock)
nix run .#mcp -- --fleet "path:/path/to/your/fleet" --namespace <ns> --output-attr <attr>
```

Point `--fleet` at a flake exposing `<output-attr>.enumerate` (the JSON-safe view — see [Fleet
wiring](#fleet-wiring)); a den consumer gets `den-lsp.enumerate` auto-exported, so the bare
`nix run .#mcp -- --fleet <ref>` defaults (`--namespace den`, `--output-attr den-lsp`) just work.

For an MCP client, register the binary as a stdio server and pass `--fleet <ref>` (or set `<NS>_FLEET`), plus
`--namespace` / `--output-attr` if the fleet is not a default-`den` fleet.

## Why hand-rolled (not the `rmcp` SDK)

MCP-over-stdio is newline-delimited JSON-RPC 2.0 (one JSON message per line). This server hand-rolls that
protocol on top of `serde_json` only — no async runtime, no MCP SDK. The reason is the Nix package build:
`buildRustPackage` vendors from a committed `Cargo.lock`, and a tiny dependency tree (serde_json + its few
transitive crates) keeps that build hermetic and fast. `rmcp` pulls in a large `tokio`-based tree; the extra
surface buys nothing for three read-only tools.

The hand-rolled envelope is spec-conformant (checked against the MCP 2025-06-18 spec, not approximated):
`initialize` returns a real `InitializeResult` (negotiated `protocolVersion` — the client's echoed when
supported, else the latest we serve; `capabilities.tools.listChanged = false`; `serverInfo`; `instructions`),
`tools/list` returns `Tool` objects with JSON-Schema `inputSchema`, and `tools/call` returns a `CallToolResult`
(a `text` content block whose text is the serialized JSON, plus `structuredContent`, plus `isError`). Unknown
tools are a JSON-RPC `-32602` protocol error; tool-execution failures are `isError: true` results. Methods
handled: `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`. The smoke test asserts
these exact wire shapes.

## Tests

- **Server side** — `mcp/tests/smoke.rs` (a `cargo test` integration test): starts the server against a
  synthetic hermetic fleet flake, drives `initialize` / `tools/list` / a `tools/call` per tool (each a real
  `nix eval` subprocess) + the two error paths, and a second session proving `--namespace` / `--output-attr`
  are configurable end-to-end. Requires `nix` on PATH — so the hermetic package build sets `doCheck = false`
  (run `cargo test` in a devshell instead).
- **Nix side (data contract)** — `ci/tests/mcp-enumerate.nix` (nix-unit): builds a synthetic enumerate view
  via `genLsp.forNixdJSON` and asserts the JSON shape the tools serve (`.options` / `.aspects` / `.libs` keys,
  an aspect field default that surfaces) round-trips through `toJSON`/`fromJSON` (the server's wire path).
