# The option-declaration PROJECTION: `genLsp.optionsProjection { options }` re-keys a gen-merge option
# tree (`(evalModuleTree { ... }).options`, the evaluated `_type == "option"` leaves) into the shape a Nix
# LSP (nixd) walks — leaves preserved (`_type`/`type`/`description`/`default`), gen-schema refinement
# metadata stripped off each leaf's `.type`, submodule/attrsOf descent shapes kept. The fixture is a
# SYNTHETIC gen-merge tree (no den dependency); the refinement strip is pinned on a synthetic refined type.
{ merge, genLsp, ... }:
let
  # A synthetic option tree: a flat `int` leaf, a `submodule` leaf, an `attrsOf` leaf. Reading `.options`
  # gives the un-forced declaration tree — the projection never enters the fixpoint / forces `.config`.
  tree = merge.evalModuleTree {
    modules = [
      {
        options.foo = merge.mkOption {
          type = merge.types.int;
          description = "a foo";
          default = 42;
        };
        options.sub = merge.mkOption {
          type = merge.types.submodule {
            options.bar = merge.mkOption {
              type = merge.types.int;
              default = 1;
            };
          };
          description = "a sub";
          default = { };
        };
        options.reg = merge.mkOption {
          type = merge.types.attrsOf merge.types.int;
          description = "a reg";
          default = { };
        };
      }
    ];
  };
  projected = genLsp.optionsProjection { options = tree.options; };

  # Synthetic refined type (gen-schema refined.nix shape): a base type wrapped with `__schema` carrying
  # `refinements` + `baseType`. The base is a plain attrset (no functions) so the stripped result is
  # value-comparable. `stripRefinements` must return `baseType` and drop `__schema`.
  baseType = {
    name = "myBase";
  };
  refinedType = baseType // {
    __schema = {
      refinements = [
        {
          check = _: true;
          message = "m";
        }
      ];
      baseType = baseType;
    };
  };
  refinedLeaf = {
    opt = {
      _type = "option";
      type = refinedType;
      description = "a refined leaf";
      default = null;
    };
  };
  projectedRefined = genLsp.optionsProjection { options = refinedLeaf; };
in
{
  flake.tests.options = {
    # The projection returns an attrset (the re-keyed tree).
    test-projection-is-attrs = {
      expr = builtins.isAttrs projected;
      expected = true;
    };

    # A flat option leaf projects with `_type == "option"` and its `type`/`description`/`default`
    # preserved (the refinement-strip is identity on a non-refined type).
    test-leaf-shape = {
      expr = {
        optionType = projected.foo._type;
        typeName = projected.foo.type.name;
        description = projected.foo.description;
        default = projected.foo.default;
      };
      expected = {
        optionType = "option";
        typeName = "int";
        description = "a foo";
        default = 42;
      };
    };

    # Every projected leaf carries a `declarationPositions` list of nixd goto records — the mkOption is
    # syntactically literal in THIS test file, so `unsafeGetAttrPos` recovers a real site (line > 0).
    test-has-positions = {
      expr =
        let
          pos = projected.foo.declarationPositions;
          first = builtins.head pos;
        in
        {
          isList = builtins.isList pos;
          nonEmpty = pos != [ ];
          lineIsPositive = first.line > 0;
          recordKeys = builtins.sort (a: b: a < b) (builtins.attrNames first);
        };
      expected = {
        isList = true;
        nonEmpty = true;
        lineIsPositive = true;
        recordKeys = [
          "column"
          "file"
          "line"
        ];
      };
    };

    # A submodule leaf keeps its descent shape — the walk does NOT flatten sub-options out of the projected
    # `.type` (`type.name == "submodule"`, `getSubOptions` still present for a nixd submodule descent).
    test-submodule-descent-preserved = {
      expr = {
        optionType = projected.sub._type;
        typeName = projected.sub.type.name;
        hasGetSubOptions = projected.sub.type ? getSubOptions;
      };
      expected = {
        optionType = "option";
        typeName = "submodule";
        hasGetSubOptions = true;
      };
    };

    # An attrsOf leaf keeps its descent shape — `nestedTypes.elemType` survives the projection.
    test-attrsof-descent-preserved = {
      expr = {
        optionType = projected.reg._type;
        typeName = projected.reg.type.name;
        hasElemType = projected.reg.type.nestedTypes ? elemType;
      };
      expected = {
        optionType = "option";
        typeName = "attrsOf";
        hasElemType = true;
      };
    };

    # A gen-schema-refined `.type` is refinement-stripped: the projected type == the base type, with no
    # `__schema` metadata leaking through, and the leaf's `_type` preserved.
    test-refinement-stripped = {
      expr = {
        typeIsBase = projectedRefined.opt.type == baseType;
        noSchemaLeak = !(projectedRefined.opt.type ? __schema);
        leafPreserved = projectedRefined.opt._type == "option";
      };
      expected = {
        typeIsBase = true;
        noSchemaLeak = true;
        leafPreserved = true;
      };
    };
  };
}
