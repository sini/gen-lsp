# The composed views + JSON-safe enumeration: `genLsp.forNixd { … }` is the IN-PROCESS view (the three
# projections, type records + `getSubOptions` functions intact, for a nixd worker's own evaluator);
# `genLsp.forNixdJSON { … }` is the WIRE view (the same three trees re-projected JSON-safe for an MCP
# server's `nix eval --json`). The LOAD-BEARING case is a DERIVATION-valued `default`: a naive JSON-safety
# walk `isAttrs`-recurses into a derivation's self-referential attrs and STACK-OVERFLOWS — an eval error
# `tryEval` CANNOT trap — so the enumeration must short-circuit a derivation by its `type` tag to a
# `"<derivation>"` placeholder BEFORE descending. The fixture is a SYNTHETIC gen-merge tree carrying a
# derivation default, a function default, a scalar default, and a submodule, plus a synthetic aspect
# registry + gen-lib bundle (no den dep). Sections are keyed GENERICALLY (`options`/`aspects`/`libs`).
{
  genLsp,
  merge,
  ...
}:
let
  drv = derivation {
    name = "x";
    system = "x86_64-linux";
    builder = "/bin/sh";
  };
  tree = merge.evalModuleTree { } [
    {
      # a DERIVATION default — the self-referential attrs that overflow a naive JSON-safety walk.
      options.pkg = merge.mkOption {
        type = merge.types.raw;
        default = drv;
      };
      # a scalar default — rides through the sanitizer unchanged.
      options.count = merge.mkOption {
        type = merge.types.int;
        default = 7;
      };
      # a function default — unserializable, mapped to a placeholder (not a `toJSON` throw).
      options.fn = merge.mkOption {
        type = merge.types.raw;
        default = (x: x);
      };
      # a real gen-merge submodule — it DEFERS `getSubOptions` (returns `{ }`, sub-options reachable only
      # through the module fixpoint), so the wire view bottoms it out at the `submodule` type-name.
      options.grp = merge.mkOption {
        type = merge.types.submodule {
          options.inner = merge.mkOption {
            type = merge.types.int;
            default = 3;
          };
        };
        default = { };
      };
    }
  ];

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

  args = {
    options = tree.options;
    inherit aspects keySemantics libs;
  };
  inProc = genLsp.forNixd args;
  jsonView = genLsp.forNixdJSON args;
in
{
  flake.tests.enumerate = {
    # THE FIX (load-bearing): a derivation-valued `default` does NOT crash the wire surface — it stays
    # `toJSON`-safe (`builtins.toJSON` itself special-cases a derivation to its `outPath`; the derivation TAG
    # is for a compact `"<derivation>"` marker, see test-derivation-placeholder-value). The ORIGINAL bool-
    # predicate `deepJsonSafe` had NO depth bound and recursed into a derivation's self-referential attrs ->
    # stack overflow (uncatchable by `tryEval`), crashing the eager asserter's whole gate; the DEPTH BOUND in
    # the total sanitizer is what makes this terminate.
    test-derivation-default-json-safe = {
      expr = builtins.isString (builtins.toJSON jsonView);
      expected = true;
    };

    # The derivation default is projected as the `"<derivation>"` placeholder (short-circuited by its tag).
    test-derivation-placeholder-value = {
      expr = jsonView.options.pkg.default;
      expected = "<derivation>";
    };

    # A scalar default rides through the sanitizer unchanged (identity on scalars).
    test-scalar-default-preserved = {
      expr = jsonView.options.count.default;
      expected = 7;
    };

    # A function-valued default is mapped to a placeholder — never a `toJSON` "cannot convert a function".
    test-function-default-placeholder = {
      expr = jsonView.options.fn.default;
      expected = "<function>";
    };

    # gen-lsp is a general library: the composed views key the three sections GENERICALLY (a consumer maps
    # these onto its own nixd provider names). `forNixd` (in-process) and `forNixdJSON` (wire) key identically.
    test-fornixd-keys = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames inProc);
      expected = [
        "aspects"
        "libs"
        "options"
      ];
    };
    test-fornixdjson-keys = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames jsonView);
      expected = [
        "aspects"
        "libs"
        "options"
      ];
    };

    # ONE projection, TWO views: the in-process submodule `.type` carries a `getSubOptions` FUNCTION (nixd
    # descends it in its own evaluator); the wire view reduces the same `.type` to its NAME string.
    test-two-views-distinction = {
      expr = {
        inProcessHasFn = inProc.options.grp.type ? getSubOptions;
        wireIsName = jsonView.options.grp.type;
      };
      expected = {
        inProcessHasFn = true;
        wireIsName = "submodule";
      };
    };

    # A real gen-merge options submodule EXPANDS on the wire: gen-merge implements the introspection half
    # of the nixpkgs `mkOptionType` protocol, so `getSubOptions` returns the declared sub-options instead
    # of the old `_prefix: { }` stub, and the walk attaches `subOptions` like it already did for a
    # synthesized aspect facet. One rule for both, no wire-depth caveat.
    #
    # Pins the CONTENTS, not just presence: `? subOptions` alone would go green again on any regression
    # that re-empties the descent (an empty set still attaches nothing, and an inverted boolean says
    # nothing about what came back). The field name and its resolved default are the actual contract.
    test-options-submodule-expanded = {
      # `or`-guarded so a regression reports a readable DIFF through the asserter rather than throwing
      # `attribute 'subOptions' missing` and crashing the whole gate. Not vacuous: an empty descent
      # yields `false` / `[ ]` / `<<absent>>`, none of which match.
      expr =
        let
          subs = jsonView.options.grp.subOptions or { };
        in
        {
          attached = jsonView.options.grp ? subOptions;
          fields = builtins.attrNames subs;
          innerDefault = (subs.inner or { }).default or "<<absent>>";
        };
      expected = {
        attached = true;
        fields = [ "inner" ];
        innerDefault = 3;
      };
    };

    # The gen surface passes through JSON-safe: a member's `functionArgs` formals survive as a plain attrset.
    test-gen-surface-formals = {
      expr = jsonView.libs.mylib.make.formals;
      expected = {
        a = false;
      };
    };

    # AN ASPECT ENUMERATES RECURSIVELY to its FIELDS + DEFAULTS: the aspect node is a `submodule`, its
    # keySemantics-classified `settings` facet is descended through `getSubOptions` (synthesized, so the wire
    # view CAN expand it) into per-field option leaves — `port`'s default 80 surfaces on the wire, not just
    # the facet name. This is the `aspects.list` contract: aspect -> facet -> field + concrete default.
    test-aspect-fields-descended = {
      expr =
        let
          w = jsonView.aspects.web;
        in
        {
          aspectType = w.type;
          description = w.description;
          facetKeys = builtins.attrNames w.subOptions;
          settingsFacetType = w.subOptions.settings.type;
          portDefault = w.subOptions.settings.subOptions.port.default;
          hostDefault = w.subOptions.settings.subOptions.host.default;
          portFieldType = w.subOptions.settings.subOptions.port.type;
        };
      expected = {
        aspectType = "submodule";
        description = "web aspect";
        facetKeys = [ "settings" ];
        settingsFacetType = "submodule";
        portDefault = 80;
        hostDefault = "localhost";
        portFieldType = "raw";
      };
    };
  };
}
