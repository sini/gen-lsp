# The shared SOURCE-POSITION layer: a generic `raw -> positions` map that recovers the source-declaration
# site of an attrset's fields as nixd goto records `{ file; line; column; }`. Pure builtins (no prelude/
# schema dep) so `lib/**` stays nixpkgs-lib-free.
#
# The engine is `builtins.unsafeGetAttrPos <field> <attrs>`: for a SYNTACTICALLY-LITERAL attr field (the
# un-merged source AST) it returns the field's `{ file; line; column; }`, else `null`. A gen-merge MERGED
# option leaf preserves its `mkOption { ... }` field source positions (the option merge threads the
# declared attrset through, like nixpkgs `opt // { ... }`), so probing a merged leaf's `type`/`default`/
# `description` recovers the DECLARATION site — no raw-decl-module hoisting needed. A SYNTHESIZED leaf
# (built from a record, carrying no literal source field) yields `null`, hence an EMPTY position list
# (never a faked site).
#
# GENERIC BY DESIGN: the layer knows nothing of options — it maps (a field-preference list, a raw attrset)
# to positions. A later graph/nav consumer reuses it by naming the fields worth probing on its own nodes
# (e.g. a graph node's `id`/`label`). Reading a position is STRUCTURAL: `unsafeGetAttrPos` reads a field's
# location metadata, never its VALUE, so a position read never forces resolved config (laziness).
{ }:
let
  # One field's source position, or `null`: guard non-attrs (a bare value has no attr position) so the
  # layer is total over any `raw`.
  attrPos =
    field: raw:
    if builtins.isAttrs raw && raw ? ${field} then builtins.unsafeGetAttrPos field raw else null;
in
{
  inherit attrPos;

  # The generic `raw -> positions` map: the FIRST field (in preference order) carrying a real source
  # position yields a singleton `[ { file; line; column; } ]`; none yields `[ ]`. Singleton by construction
  # — a merged leaf's `type`/`default`/`description` all point INSIDE the same declaration block, so the
  # first hit is the declaration anchor (later distinct sites, if a source ever exposes them, extend here).
  # Partial-applies to the intended shape: `positionsOf { fields = [ ... ]; }` IS a reusable `raw -> positions`.
  positionsOf =
    { fields }:
    raw:
    let
      hits = builtins.filter (p: p != null) (builtins.map (f: attrPos f raw) fields);
    in
    if hits == [ ] then [ ] else [ (builtins.head hits) ];
}
