# The aspect-registry PROJECTION: synthesize one nixd-walkable SUBMODULE option node per DECLARED aspect
# instance so an LSP completes aspect names as submodules and each aspect's user-facing facets (its
# schema) as sub-options. Facet-generic: the projectable facets are discovered from a construction-time
# `keySemantics` map (the consumer's key vocabulary), NOT hardcoded to any facet name.
#
# The classifier mirrors den's `classifyKey` (concern-aspects.nix §2.2 three-branch key dispatch): a key
# in the STRUCTURAL list is identity (`name`/`meta`/… — a built-in submodule option, NOT a projectable
# facet); otherwise its category comes off the single `keySemantics` source (`class` content bucket /
# `channel` emission / `facet` schema); an unregistered key is unknown. Only `facet` keys project — the
# `class`/`channel` content buckets are handled by their own strata, never surfaced as options.
#
# The per-facet VALUE descent is STRUCTURAL, not name-based: a settings-shaped facet — a record of
# field-specs, each a `{ default; merge ? "replace"; }` record (§2.6 settings schema, concern-aspects
# settingsModule) — descends one level into per-field option leaves under a submodule; any other value
# projects as a single opaque leaf. So `settings` and any other consumer's facets project the same way,
# with zero hardcoded facet names. Pure builtins (no prelude/schema dep): the walk reads static
# declaration data (`.description`, a field-spec's `.default`) and never enters the resolution fixpoint.
{ }:
let
  # The structural identity keys (den concern-aspects.nix §2.2): built-in submodule options that frame an
  # aspect's identity, NOT projectable facets. Overridable per consumer via `aspectsProjection`'s argument.
  defaultStructuralKeys = [
    "name"
    "includes"
    "meta"
    "tags"
    "projects"
    "key"
    "description"
  ];

  # classifyKey (concern-aspects.nix §2.2): structural keys FIRST (identity, checked before the map so a
  # structural name never depends on a keySemantics lookup); else the key's `category` off the single
  # keySemantics source; else unknown. Generic over the passed map — no facet-name literal.
  classifyKey =
    structuralKeys: keySemantics: key:
    if builtins.elem key structuralKeys then
      "structural"
    else
      keySemantics.${key}.category or "unknown";

  # A field-spec (§2.6 settings schema): an attrset carrying a `.default` — the settings field shape a
  # facet's value descends into.
  isFieldSpec = v: builtins.isAttrs v && v ? default;

  # A settings-shaped facet VALUE: a non-empty record whose every value is a field-spec. The non-empty
  # guard keeps a genuinely opaque `{ }` (which carries no fields to descend) projecting as a single leaf
  # rather than a hollow submodule.
  isFieldSpecMap =
    v: builtins.isAttrs v && v != { } && builtins.all isFieldSpec (builtins.attrValues v);

  # One field-spec → an option leaf. Settings are `lazyAttrsOf raw`, so the leaf's `type` is `raw` and its
  # `default` is the field-spec's `.default` (`null` when the spec omits one). The `merge` mode is
  # declaration metadata, not part of the option surface a completion walks.
  fieldLeaf = spec: {
    _type = "option";
    default = spec.default or null;
    description = "";
    type = {
      name = "raw";
    };
  };

  # One facet VALUE → a sub-option node. Value-shape descent (structural, not name-based): a settings-shaped
  # record descends one level into per-field leaves under a submodule option (a nixd submodule descends
  # through `getSubOptions`); any other value projects as a single opaque `raw` leaf carrying the value as
  # its `default`.
  projectFacet =
    val:
    if isFieldSpecMap val then
      {
        _type = "option";
        description = "";
        type = {
          name = "submodule";
          getSubOptions = _: builtins.mapAttrs (_: fieldLeaf) val;
        };
      }
    else
      {
        _type = "option";
        default = val;
        description = "";
        type = {
          name = "raw";
        };
      };

  # One aspect instance → a submodule option node. The sub-options are exactly the instance's FACET keys
  # (structural identity + `class`/`channel` content buckets skipped by `classifyKey`); `description` falls
  # back to the built-in `"Aspect ${name}"` default. `getSubOptions` yields the projected facets so a nixd
  # submodule descends through it.
  aspectNode =
    structuralKeys: keySemantics: name: a:
    let
      facetKeys = builtins.filter (k: classifyKey structuralKeys keySemantics k == "facet") (
        builtins.attrNames a
      );
      subs = builtins.listToAttrs (
        map (k: {
          name = k;
          value = projectFacet a.${k};
        }) facetKeys
      );
    in
    {
      _type = "option";
      description = a.description or "Aspect ${name}";
      type = {
        name = "submodule";
        getSubOptions = _: subs;
      };
    };
in
{
  # The projection entry: given a consumer's construction-time `keySemantics` map (`{ <key> = { category =
  # "class" | "channel" | "facet"; … }; }`) and its structural-key list (defaulted to den's), return a
  # function projecting `{ aspects }` (an attrset of aspect instances keyed by name) into per-aspect
  # submodule option nodes. Facet-generic — the projectable facets are the `category == "facet"` keys the
  # map declares, so a consumer with differently-named facets projects them without any change here.
  #
  # KNOWN LIMIT: this projects DECLARED aspect instances (`attrNames aspects`), not a fixed catalog — an
  # empty registry projects nothing. Correct + sufficient for listing/completing already-declared aspects
  # and their facets; it does not discover undeclared aspects.
  aspectsProjection =
    {
      keySemantics,
      structuralKeys ? defaultStructuralKeys,
    }:
    { aspects }:
    builtins.mapAttrs (aspectNode structuralKeys keySemantics) aspects;
}
