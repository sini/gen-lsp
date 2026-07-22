# The shared source-position layer: `genLsp.positions` is a generic `raw -> positions` map recovering an
# attrset's field declaration sites as nixd goto records `{ file; line; column; }`, via
# `builtins.unsafeGetAttrPos`. `optionsProjection` attributes each option leaf's `declarationPositions`
# with it; a later graph/nav feature reuses the SAME layer on its own nodes. Reading a position is
# STRUCTURAL — it never forces a leaf's VALUE (the laziness seam).
{ merge, genLsp, ... }:
let
  # A merged option leaf whose `mkOption` block is syntactically literal in THIS file — so probing it
  # recovers a source site INSIDE this test file.
  tree = merge.evalModuleTree {
    modules = [
      {
        options.foo = merge.mkOption {
          type = merge.types.int;
          description = "a foo";
          default = 42;
        };
      }
    ];
  };
  projected = genLsp.optionsProjection { options = tree.options; };
  fooPos = projected.foo.declarationPositions;
  firstFoo = builtins.head fooPos;

  # Genericity: a raw literal that is NOT an option leaf, run through the generic layer, recovers ITS OWN
  # field's source position — proving the layer is reusable beyond option leaves (a graph node's
  # `label`/`id` field would be probed the same way).
  rawNode = {
    label = "n";
  };
  genericPos = genLsp.positions.positionsOf { fields = [ "label" ]; } rawNode;
in
{
  flake.tests.positions = {
    # A real declared option leaf carries a non-empty `declarationPositions` list of nixd goto records
    # (`{ file; line; column; }`) — line/col path taken, so line > 0 — at THIS file (the literal's site).
    test-leaf-carries-positions = {
      expr = {
        isList = builtins.isList fooPos;
        nonEmpty = fooPos != [ ];
        recordKeys = builtins.sort (a: b: a < b) (builtins.attrNames firstFoo);
        lineIsPositive = firstFoo.line > 0;
        columnIsPositive = firstFoo.column > 0;
        fileIsString = builtins.isString firstFoo.file;
        fileIsThisFile = builtins.match ".*/positions\\.nix" firstFoo.file != null;
      };
      expected = {
        isList = true;
        nonEmpty = true;
        recordKeys = [
          "column"
          "file"
          "line"
        ];
        lineIsPositive = true;
        columnIsPositive = true;
        fileIsString = true;
        fileIsThisFile = true;
      };
    };

    # THE GENERIC LAYER: `positions.positionsOf { fields } raw` is not options-specific — a bare raw literal
    # yields a singleton position at its probed field's source site; an absent field yields NO position
    # (honest — never a faked location).
    test-generic-layer-reusable = {
      expr = {
        isSingleton = builtins.length genericPos == 1;
        lineIsPositive = (builtins.head genericPos).line > 0;
        fileIsThisFile = builtins.match ".*/positions\\.nix" (builtins.head genericPos).file != null;
        absentFieldEmpty = genLsp.positions.positionsOf { fields = [ "nope" ]; } rawNode == [ ];
      };
      expected = {
        isSingleton = true;
        lineIsPositive = true;
        fileIsThisFile = true;
        absentFieldEmpty = true;
      };
    };

    # `attrPos` is TOTAL over any raw: a non-attrs input has no attr position, yielding `null` (never a
    # crash) — the guard that makes the layer safe to point at arbitrary nodes.
    test-attrpos-total-over-nonattrs = {
      expr = genLsp.positions.attrPos "x" 42;
      expected = null;
    };
  };
}
