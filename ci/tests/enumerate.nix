# The composed views + JSON-safe enumeration: `genLsp.forNixd { … }` is the IN-PROCESS view (the three
# projections, type records + `getSubOptions` functions intact, for a nixd worker's own evaluator);
# `genLsp.forNixdJSON { … }` is the WIRE view (the same three trees re-projected JSON-safe for an MCP
# server's `nix eval --json`). The LOAD-BEARING case is a DERIVATION-valued `default`: a naive JSON-safety
# walk `isAttrs`-recurses into a derivation's self-referential attrs and STACK-OVERFLOWS — an eval error
# `tryEval` CANNOT trap — so the enumeration must short-circuit a derivation by its `type` tag to a
# `"<derivation>"` placeholder BEFORE descending. The fixture is a SYNTHETIC gen-merge tree carrying a
# derivation default, a function default, a scalar default, and a submodule, plus a synthetic aspect
# registry + gen-lib bundle (no den dep).
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
  tree = merge.evalModuleTree {
    modules = [
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
        # a submodule — its in-process `.type` carries `getSubOptions`; the wire view reduces it to a name.
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
          default = 8080;
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
    # THE FIX (load-bearing): a derivation-valued `default` does NOT crash — the whole wire surface is
    # `toJSON`-safe. Pre-fix this expr STACK-OVERFLOWS (uncatchable), crashing the eager asserter's gate.
    test-derivation-default-json-safe = {
      expr = builtins.isString (builtins.toJSON jsonView);
      expected = true;
    };

    # The derivation default is projected as the `"<derivation>"` placeholder (short-circuited by its tag).
    test-derivation-placeholder-value = {
      expr = jsonView.den.pkg.default;
      expected = "<derivation>";
    };

    # A scalar default rides through the sanitizer unchanged (identity on scalars).
    test-scalar-default-preserved = {
      expr = jsonView.den.count.default;
      expected = 7;
    };

    # A function-valued default is mapped to a placeholder — never a `toJSON` "cannot convert a function".
    test-function-default-placeholder = {
      expr = jsonView.den.fn.default;
      expected = "<function>";
    };

    # `forNixd` (in-process) and `forNixdJSON` (wire) key the three sections IDENTICALLY.
    test-fornixd-keys = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames inProc);
      expected = [
        "den"
        "den-aspects"
        "gen"
      ];
    };
    test-fornixdjson-keys = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames jsonView);
      expected = [
        "den"
        "den-aspects"
        "gen"
      ];
    };

    # ONE projection, TWO views: the in-process submodule `.type` carries a `getSubOptions` FUNCTION (nixd
    # descends it in its own evaluator); the wire view reduces the same `.type` to its NAME string.
    test-two-views-distinction = {
      expr = {
        inProcessHasFn = inProc.den.grp.type ? getSubOptions;
        wireIsName = jsonView.den.grp.type;
      };
      expected = {
        inProcessHasFn = true;
        wireIsName = "submodule";
      };
    };

    # The gen surface passes through JSON-safe: a member's `functionArgs` formals survive as a plain attrset.
    test-gen-surface-formals = {
      expr = jsonView.gen.mylib.make.formals;
      expected = {
        a = false;
      };
    };

    # An aspect enumerates ONE level to its facets: the aspect node is a `submodule`, its `settings`-facet
    # (keySemantics-classified) rides through reduced to its own `submodule` type-name.
    test-aspect-enumeration = {
      expr =
        let
          w = jsonView."den-aspects".web;
        in
        {
          aspectType = w.type;
          description = w.description;
          facetKeys = builtins.attrNames w.settings;
          settingsFacetType = w.settings.settings.type;
        };
      expected = {
        aspectType = "submodule";
        description = "web aspect";
        facetKeys = [ "settings" ];
        settingsFacetType = "submodule";
      };
    };
  };
}
