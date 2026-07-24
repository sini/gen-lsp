//! The three enumeration tools + the `nix` invocation.
//!
//! LOAD-BEARING design principle: **interpreter-agnostic — drive the customer's `nix`, don't embed one.**
//! Every tool shells out to `nix` resolved from `PATH` (CppNix, Lix, or any other interpreter the customer
//! uses), so the enumeration always matches the customer's own evaluator. We NEVER reference a specific
//! interpreter binary or path. Each tool builds a selector expression into the fleet's `<output-attr>.enumerate`
//! output (gen-lsp's `forNixdJSON`, the JSON-safe enumeration view of the projections) and runs
//! `nix eval --impure --json --expr '<expr>'`, returning the parsed JSON.
//!
//! This server is a DUMB THIN TRANSPORT: it holds no projection logic. All shaping lives in gen-lsp's two
//! views of one projection — `forNixd` (functions intact, for a nixd worker's in-process C++ walk) and
//! `forNixdJSON` (wire-serializable, what this server serves). The server only shells `nix eval --json` and
//! passes bytes.
//!
//! GENERALIZED off den: the consumer-facing surface is parameterized. `--output-attr` (default `den-lsp`) is
//! the flake output the tools read; `--namespace` (default `den`) prefixes the two consumer-scoped tool names
//! (`<ns>_schema` / `<ns>_aspects_list`). The gen-lib tool stays the fixed `gen_lib_signature` — it enumerates
//! the namespace-independent gen substrate library surface, not the consumer's own option/aspect tree. The
//! enumeration view keys its sections GENERICALLY: `options` (the option-declaration tree), `aspects` (the
//! aspect registry), `libs` (the gen-lib API surface).

use serde_json::{json, Value};
use std::process::Command;

/// The gen-lib enumeration tool name. FIXED (not namespaced): it enumerates the gen substrate library
/// surface — the same gen ecosystem regardless of what a consumer names its own fleet output — whereas
/// `<ns>_schema` / `<ns>_aspects_list` describe the consumer's own option/aspect tree, so those are namespaced.
pub const LIB_TOOL: &str = "gen_lib_signature";

/// The configured enumeration server: the customer's fleet reference (a flake ref / path) the tools evaluate
/// the `<output-attr>.enumerate` output over, plus the `namespace` (consumer tool-name prefix) and the
/// `output-attr` (the flake output attr carrying the projections).
pub struct Server {
    pub fleet: Option<String>,
    pub namespace: String,
    pub output_attr: String,
}

/// Why building a tool's expression failed — distinguishes a protocol error (unknown tool → JSON-RPC error)
/// from a tool-execution error (bad args / no fleet → an `isError` tool result the model can read).
pub enum BuildErr {
    /// The tool name is not one of the three — a JSON-RPC `-32602` (invalid params).
    UnknownTool,
    /// The arguments are invalid (missing/ill-formed) — reported as an `isError` tool result.
    BadArgs(String),
    /// No fleet was configured (`--fleet` / `<NS>_FLEET`) — reported as an `isError` tool result.
    NoFleet,
}

impl Server {
    /// The namespaced option-schema tool name (`<ns>_schema`).
    pub fn schema_tool(&self) -> String {
        format!("{}_schema", self.namespace)
    }

    /// The namespaced aspects tool name (`<ns>_aspects_list`).
    pub fn aspects_tool(&self) -> String {
        format!("{}_aspects_list", self.namespace)
    }

    /// The environment variable the fleet ref falls back to (`<NS>_FLEET`, uppercased namespace).
    pub fn fleet_env_var(&self) -> String {
        format!("{}_FLEET", self.namespace.to_uppercase())
    }

    /// Validate that the composed namespaced tool names are MCP-conformant (`^[A-Za-z0-9_-]{1,128}$`). Called
    /// at startup so a bad `--namespace` fails fast instead of advertising tools Claude/agents would reject.
    /// The fixed `gen_lib_signature` is conformant by construction, so only the namespaced names are checked.
    pub fn validate(&self) -> Result<(), String> {
        for name in [self.schema_tool(), self.aspects_tool()] {
            if !is_mcp_tool_name(&name) {
                return Err(format!(
                    "composed tool name {name:?} is not MCP-conformant (^[A-Za-z0-9_-]{{1,128}}$); \
                     --namespace {:?} is invalid",
                    self.namespace
                ));
            }
        }
        Ok(())
    }

    /// The MCP tool catalogue (`tools/list`): 3 read-only enumeration tools with JSON-Schema input schemas.
    /// Names are composed from `namespace` (the two consumer-scoped tools) + the fixed `gen_lib_signature`;
    /// descriptions keep the conceptual dotted phrasing (`<ns>.*` option paths) for the model.
    pub fn tool_definitions(&self) -> Value {
        let ns = &self.namespace;
        json!([
            {
                // Wire names are underscore-only — MCP / the Anthropic tool API validate tool names against
                // `^[a-zA-Z0-9_-]{1,128}$`, so a dotted name (`<ns>.schema`) is rejected by the very clients
                // (Claude/agents) this server targets. Descriptions keep the conceptual `<ns>.*` phrasing.
                "name": self.schema_tool(),
                "title": format!("{ns} option schema"),
                "description": format!("Enumerate the {ns} option-declaration tree ({ns}.* options) for the configured fleet, as JSON. Each leaf carries _type, a human description, and its option type name (str/submodule/attrsOf/…). Use this to discover the valid {ns}.<...> option paths for a fleet instead of guessing the API."),
                "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
            },
            {
                "name": self.aspects_tool(),
                "title": format!("{ns} declared aspects"),
                "description": "List the fleet's declared aspects and, per aspect, its settings (name, default, type). Use this to discover which aspects a fleet declares and each aspect's settings fields.",
                "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
            },
            {
                "name": LIB_TOOL,
                "title": "gen-lib member signature",
                "description": "Return gen substrate library member names and their functionArgs formals. Pass `lib` (e.g. \"select\", \"resolve\", \"scope\") to list that library's members; add `member` to return a single member's signature (formals). Use this instead of guessing gen-lib function names/arguments.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "lib": { "type": "string", "description": "gen library name, e.g. select, resolve, scope, graph" },
                        "member": { "type": "string", "description": "optional member name within the library" }
                    },
                    "required": ["lib"],
                    "additionalProperties": false
                }
            }
        ])
    }

    /// Build the Nix selector expression for a tool call:
    /// `(builtins.getFlake "<fleet>")."<output-attr>".enumerate.<sel>`. The fleet ref and output-attr are
    /// Nix-string-escaped; `lib`/`member` are charset-validated and quoted, so an attr name with a hyphen
    /// selects safely and no argument can inject Nix. The section keys are generic: `<ns>_schema` → `.options`,
    /// `<ns>_aspects_list` → `.aspects`, `gen_lib_signature` → `.libs.<lib>[.<member>]`.
    pub fn build_expr(&self, name: &str, args: &Value) -> Result<String, BuildErr> {
        let fleet = self.fleet.as_deref().ok_or(BuildErr::NoFleet)?;
        let base = format!(
            "(builtins.getFlake \"{}\").\"{}\".enumerate",
            nix_escape_str(fleet),
            nix_escape_str(&self.output_attr)
        );
        if name == self.schema_tool() {
            Ok(format!("{base}.options"))
        } else if name == self.aspects_tool() {
            Ok(format!("{base}.aspects"))
        } else if name == LIB_TOOL {
            let lib = args
                .get("lib")
                .and_then(Value::as_str)
                .ok_or_else(|| BuildErr::BadArgs("missing required argument `lib`".into()))?;
            if !is_attr_name(lib) {
                return Err(BuildErr::BadArgs(format!("invalid `lib` name: {lib:?}")));
            }
            let mut expr = format!("{base}.libs.\"{lib}\"");
            if let Some(member) = args.get("member").and_then(Value::as_str) {
                if !is_attr_name(member) {
                    return Err(BuildErr::BadArgs(format!(
                        "invalid `member` name: {member:?}"
                    )));
                }
                expr = format!("{expr}.\"{member}\"");
            }
            Ok(expr)
        } else {
            Err(BuildErr::UnknownTool)
        }
    }

    /// Evaluate an expression through the customer's `nix` (resolved from `PATH` — interpreter-agnostic) and
    /// parse its JSON. `--extra-experimental-features` is passed so the flake evaluation works regardless of
    /// the customer's nix.conf (additive; it enables the two features `getFlake`/`eval --expr` require).
    /// `--impure` is required to `getFlake` a local/unlocked/dirty path (the dev case); it is harmless for a
    /// locked flake ref (the real customer case), whose `getFlake` is pure — `--impure` permits impurity, it
    /// does not introduce it, and this projection is pure either way.
    pub fn nix_eval(&self, expr: &str) -> Result<Value, String> {
        let output = Command::new("nix")
            .args([
                "eval",
                "--impure",
                "--json",
                "--extra-experimental-features",
                "nix-command flakes",
                "--expr",
                expr,
            ])
            .output()
            .map_err(|e| format!("failed to spawn `nix` from PATH: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "`nix eval` failed ({}):\n{}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        serde_json::from_slice(&output.stdout)
            .map_err(|e| format!("`nix eval` returned non-JSON output: {e}"))
    }
}

/// A safe Nix attribute-name / member charset: identifiers, plus `-` and `'` (gen member names like
/// `inputs'`) — never a quote or interpolation, so the validated string cannot escape the quoted attr-path.
fn is_attr_name(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '\'')
}

/// An MCP / Anthropic tool-name charset (`^[A-Za-z0-9_-]{1,128}$`): no `'`, no dot — the guard the composed
/// namespaced tool names must satisfy so Claude/agents (this server's clients) accept them.
fn is_mcp_tool_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Escape a string for a Nix `"..."` literal: backslash, double-quote, AND `$` (defense-in-depth — `\$`
/// neutralizes any `${...}` antiquotation in an operator-supplied fleet ref / output attr). Backslash is
/// doubled FIRST so the `\` introduced by the `$` escape is not itself re-doubled.
fn nix_escape_str(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('$', "\\$")
}

/// A successful `tools/call` result: the JSON as a text content block (always) plus `structuredContent`
/// when the value is a JSON object (the MCP structured-output channel). `isError` false.
pub fn tool_result_ok(value: Value) -> Value {
    let text = serde_json::to_string_pretty(&value).unwrap_or_else(|_| value.to_string());
    let mut result = json!({
        "content": [ { "type": "text", "text": text } ],
        "isError": false
    });
    if value.is_object() {
        result["structuredContent"] = value;
    }
    result
}

/// A failed `tools/call` result: the error message as text, `isError` true — visible to the model (the MCP
/// convention for tool-execution failures, as opposed to a JSON-RPC protocol error).
pub fn tool_result_err(message: String) -> Value {
    json!({
        "content": [ { "type": "text", "text": message } ],
        "isError": true
    })
}
