//! gen-lsp enumeration MCP server (stdio).
//!
//! A thin, read-only Model Context Protocol server that exposes a gen-stack fleet's option / aspect / gen-lib
//! API surface to agents so they stop hallucinating fleet options and gen-lib signatures. It embeds NO Nix
//! evaluator: every tool drives the customer's own `nix` (resolved from `PATH`) as a subprocess (see
//! `tools.rs`), which is what keeps the enumeration correct for every customer on any interpreter (CppNix,
//! Lix, …).
//!
//! The consumer surface is GENERALIZED off den and parameterized on the command line: `--namespace` (default
//! `den`) prefixes the two consumer-scoped tools and the server id / env var; `--output-attr` (default
//! `den-lsp`) is the flake output the tools evaluate. The gen-lib tool stays the fixed `gen_lib_signature`.
//!
//! Transport: MCP stdio = newline-delimited JSON-RPC 2.0. One complete JSON message per line on stdin;
//! one response line per request on stdout; diagnostics on stderr. Notifications (no `id`) get no response.

mod tools;

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use tools::{tool_result_err, tool_result_ok, BuildErr, Server, LIB_TOOL};

fn main() {
    let server = parse_config();
    // A bad `--namespace` composes non-conformant tool names; fail fast with a clear diagnostic rather than
    // advertising tools the client (Claude/agents) would reject.
    if let Err(msg) = server.validate() {
        eprintln!("gen-lsp-mcp: {msg}");
        std::process::exit(2);
    }
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                write_msg(
                    &mut out,
                    &json!({
                        "jsonrpc": "2.0",
                        "id": Value::Null,
                        "error": { "code": -32700, "message": format!("parse error: {e}") }
                    }),
                );
                continue;
            }
        };
        if let Some(response) = server_handle(&server, &msg) {
            write_msg(&mut out, &response);
        }
    }
}

/// Dispatch one JSON-RPC message. Returns `Some(response)` for a request (has `id`), `None` for a
/// notification (no `id`) or a message with no `method` (e.g. a stray response).
fn server_handle(server: &Server, msg: &Value) -> Option<Value> {
    let method = msg.get("method").and_then(Value::as_str)?;
    let id = msg.get("id").cloned();
    match method {
        "initialize" => id.map(|id| ok(id, initialize_result(server, msg))),
        // Lifecycle / control notifications carry no id → no response.
        "notifications/initialized" | "notifications/cancelled" => None,
        "ping" => id.map(|id| ok(id, json!({}))),
        "tools/list" => id.map(|id| ok(id, json!({ "tools": server.tool_definitions() }))),
        "tools/call" => id.map(|id| tools_call(server, id, msg)),
        _ => id.map(|id| err(id, -32601, format!("method not found: {method}"))),
    }
}

/// The `initialize` result (MCP lifecycle). Version negotiation per spec: if the client sent a protocol
/// version we serve, echo it (the envelope here — `initialize` / `tools/list` / `tools/call` — is stable
/// across 2024-11-05 … 2025-06-18); otherwise advertise the latest we know. `capabilities.tools.listChanged`
/// is `false` — the tool list is static, so we never emit `notifications/tools/list_changed`. `serverInfo` and
/// the `instructions` are namespaced (default `den` → `den-lsp-mcp` / `den_schema` …).
fn initialize_result(server: &Server, msg: &Value) -> Value {
    // The protocol versions whose envelope this server serves; the first is the latest (default).
    const SUPPORTED: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];
    let requested = msg
        .pointer("/params/protocolVersion")
        .and_then(Value::as_str);
    let version = match requested {
        Some(v) if SUPPORTED.contains(&v) => v,
        _ => SUPPORTED[0],
    };
    let ns = &server.namespace;
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": { "listChanged": false } },
        "serverInfo": {
            "name": format!("{ns}-lsp-mcp"),
            "title": format!("{ns} LSP enumeration"),
            "version": env!("CARGO_PKG_VERSION")
        },
        "instructions": format!(
            "Enumeration tools for a {ns} fleet's option / aspect / gen-lib API surface. Call {schema} to \
             discover valid {ns}.* option paths, {aspects} for declared aspects and their settings, and \
             {lib} for gen-lib member names and formals — instead of guessing the API. All are read-only \
             and evaluate the customer's own `nix`.",
            schema = server.schema_tool(),
            aspects = server.aspects_tool(),
            lib = LIB_TOOL,
        )
    })
}

/// Run a `tools/call`. Unknown tool → JSON-RPC `-32602`; a bad-args / no-fleet / `nix eval` failure → an
/// `isError` tool result (visible to the model); success → the projection JSON.
fn tools_call(server: &Server, id: Value, msg: &Value) -> Value {
    let name = msg
        .pointer("/params/name")
        .and_then(Value::as_str)
        .unwrap_or("");
    let args = msg
        .pointer("/params/arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let expr = match server.build_expr(name, &args) {
        Ok(expr) => expr,
        Err(BuildErr::UnknownTool) => return err(id, -32602, format!("unknown tool: {name}")),
        Err(BuildErr::BadArgs(m)) => return ok(id, tool_result_err(m)),
        Err(BuildErr::NoFleet) => {
            return ok(
                id,
                tool_result_err(format!(
                    "no fleet configured: pass --fleet <flake-ref> or set {}",
                    server.fleet_env_var()
                )),
            )
        }
    };
    match server.nix_eval(&expr) {
        Ok(value) => ok(id, tool_result_ok(value)),
        Err(e) => ok(id, tool_result_err(e)),
    }
}

/// Parse the server configuration from the command line: `--fleet` / `--namespace` / `--output-attr` (each in
/// both `--flag value` and `--flag=value` forms). The fleet ref falls back to the `<NS>_FLEET` env var (keyed
/// by the resolved namespace, so `--namespace gen` reads `GEN_FLEET`).
fn parse_config() -> Server {
    let mut fleet: Option<String> = None;
    let mut namespace = "den".to_string();
    let mut output_attr = "den-lsp".to_string();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--fleet" => fleet = args.next(),
            "--namespace" => {
                if let Some(v) = args.next() {
                    namespace = v;
                }
            }
            "--output-attr" => {
                if let Some(v) = args.next() {
                    output_attr = v;
                }
            }
            other => {
                if let Some(rest) = other.strip_prefix("--fleet=") {
                    fleet = Some(rest.to_string());
                } else if let Some(rest) = other.strip_prefix("--namespace=") {
                    namespace = rest.to_string();
                } else if let Some(rest) = other.strip_prefix("--output-attr=") {
                    output_attr = rest.to_string();
                }
            }
        }
    }

    let mut server = Server {
        fleet,
        namespace,
        output_attr,
    };
    if server.fleet.is_none() {
        server.fleet = std::env::var(server.fleet_env_var()).ok();
    }
    server
}

fn ok(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn err(id: Value, code: i64, message: String) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

/// Write one JSON-RPC message as a single stdout line (MCP stdio framing), then flush.
fn write_msg(out: &mut impl Write, msg: &Value) {
    let _ = writeln!(out, "{}", serde_json::to_string(msg).unwrap_or_default());
    let _ = out.flush();
}
