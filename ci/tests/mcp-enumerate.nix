# The MCP server's Nix-side DATA CONTRACT: the JSON shape `genLsp.forNixdJSON` produces is exactly what the
# three MCP tools select into and serve. The server is a dumb thin transport — it runs `nix eval --json` over
# `<output-attr>.enumerate.<section>` and passes the bytes — so this test asserts the WIRE shape the tools
# depend on, over the server's exact wire path: `builtins.fromJSON (builtins.toJSON view)` (what `nix eval
# --json` + the Rust serde parse do end to end). The Rust smoke test (`mcp/tests/smoke.rs`) covers the MCP
# protocol envelope; this covers the data the envelope carries. Fixture: a SYNTHETIC gen-merge option tree +
# a synthetic aspect registry + a gen-lib bundle (no den dep), keyed GENERICALLY (`options`/`aspects`/`libs`).
{
  genLsp,
  merge,
  ...
}:
let
  tree = merge.evalModuleTree {
    modules = [
      {
        # a scalar leaf — its `_type` + type-name are what `<ns>_schema` surfaces.
        options.count = merge.mkOption {
          type = merge.types.int;
          default = 7;
          description = "a counter";
        };
        # a raw leaf — a second option so the tree is not a singleton.
        options.raw = merge.mkOption {
          type = merge.types.raw;
          default = "anything";
        };
      }
    ];
  };

  keySemantics = {
    settings = {
      category = "facet";
    };
  };
  aspects = {
    web = {
      name = "web";
      description = "web aspect";
      settings = {
        port = {
          default = 80;
        };
        host = {
          default = "localhost";
        };
      };
    };
  };
  libs = {
    mylib = {
      make =
        { a }:
        a;
    };
  };

  view = genLsp.forNixdJSON {
    options = tree.options;
    inherit aspects keySemantics libs;
  };
  # The server's exact wire path: serialize with `toJSON` (what `nix eval --json` emits) then re-parse (what
  # the Rust serde does). Everything the tools serve to a model goes through this round-trip.
  roundTrip = builtins.fromJSON (builtins.toJSON view);
in
{
  flake.tests.mcp-enumerate = {
    # The whole view is `toJSON`-safe — the server serializes it with `nix eval --json`. (An unserializable
    # node — a function, a derivation's self-referential attrs — would crash this; the enumeration view
    # sanitizes them to placeholders upstream.)
    test-view-is-json-safe = {
      expr = builtins.isString (builtins.toJSON view);
      expected = true;
    };

    # The three GENERIC section keys the tools select into: `<ns>_schema` → `.options`, `<ns>_aspects_list` →
    # `.aspects`, `gen_lib_signature` → `.libs`.
    test-section-keys = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames roundTrip);
      expected = [
        "aspects"
        "libs"
        "options"
      ];
    };

    # `<ns>_schema` → `.enumerate.options`: an option leaf is a JSON-safe record carrying `_type`, its
    # type-NAME (not a type record), and its scalar default.
    test-options-leaf-shape = {
      expr = {
        _type = roundTrip.options.count._type;
        type = roundTrip.options.count.type;
        default = roundTrip.options.count.default;
      };
      expected = {
        _type = "option";
        type = "int";
        default = 7;
      };
    };

    # `<ns>_aspects_list` → `.enumerate.aspects`: an aspect descends to its settings facet's fields, each
    # field's concrete default surfacing on the wire (aspect → facet → field + default).
    test-aspect-field-default = {
      expr = roundTrip.aspects.web.subOptions.settings.subOptions.port.default;
      expected = 80;
    };

    # `gen_lib_signature <lib> <member>` → `.enumerate.libs.<lib>.<member>`: a member's `functionArgs`
    # formals survive the wire as a plain attrset.
    test-lib-member-formals = {
      expr = roundTrip.libs.mylib.make.formals;
      expected = {
        a = false;
      };
    };
  };
}
