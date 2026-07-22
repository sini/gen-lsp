# The JSON-safe enumeration VIEW over the projections — ONE projection, TWO views. `forNixd` (composed here)
# is the IN-PROCESS view a nixd worker walks: an option leaf's `.type` is a gen-schema/nixpkgs type RECORD
# carrying functions (`check`/`merge`/`getSubOptions`) and an aspect node's `.type.getSubOptions` is itself a
# function — nixd calls them in its own evaluator. `forNixdJSON` is the WIRE view — `builtins.toJSON` (what an
# MCP enumeration server's `nix eval --json` subprocess runs) cannot serialize a function ("cannot convert a
# function to JSON"), so `enumerate` re-projects each tree into a JSON-safe ENUMERATION shape: an option leaf
# keeps its `_type`/description/type-NAME/(JSON-safe default), every function dropped; an aspect node descends
# ONE level to list its facets; the gen surface (flat member names + string `functionArgs` formals) passes
# through. Keeping BOTH views in the library (not one in a downstream server) makes the library the single
# source of truth and leaves the MCP server a dumb thin transport (`nix eval --json`, no logic). Pure builtins
# (no prelude/gen dep) so the library stays nixpkgs-lib-free.
{ }:
let
  optionsProjectionLib = import ./options-projection.nix { };
  aspectsProjectionLib = import ./aspects-projection.nix { };
  genLibProjectionLib = import ./genlib-projection.nix { };
  inherit (optionsProjectionLib) optionsProjection;
  inherit (aspectsProjectionLib) aspectsProjection;
  inherit (genLibProjectionLib) genLibProjection;

  # A projected option leaf: an attrset tagged `_type == "option"` (the same predicate the projections walk).
  isOpt = v: builtins.isAttrs v && v ? _type && v._type == "option";

  # A type record's display NAME — the JSON-safe scalar an agent completes on (`str`/`submodule`/`attrsOf`/…).
  # Reading `.name` forces only that string field, never the type's `check`/`merge`/`getSubOptions` functions.
  # A typeless leaf (a gen-lib member, or a leaf whose refined type was stripped to null) projects `null`.
  typeName = t: if t == null then null else (t.name or "unknown");

  # The recursion depth bound: a defensive backstop against a cyclic `default` value that is NOT a derivation
  # (a derivation is short-circuited by its `type` tag below; this bounds any OTHER self-referential attrs a
  # default might carry). At the bound a node renders opaque (`"<...>"`) rather than descending forever.
  maxDepth = 64;

  # Deep-sanitize a `default` VALUE into a JSON-safe one. The load-bearing case is a DERIVATION default: a
  # derivation is an attrset whose `drvAttrs`/`outPath`/`all` are mutually self-referential, so a naive
  # `isAttrs`-recursion (or `toJSON`) STACK-OVERFLOWS — and a stack overflow is UNCATCHABLE by `tryEval`
  # (unlike a `throw`), so it MUST be ruled out by TAG before any descent: an attrset whose `type` reads
  # `"derivation"` short-circuits to `"<derivation>"`. Every other unserializable node is mapped to a
  # placeholder too (a function -> `"<function>"`; a throwing node, trapped per-level by `tryEval`, ->
  # `"<error>"`; past the depth bound -> `"<...>"`), so the result is TOTAL — a scalar rides through, an
  # attrset/list is sanitized element-wise, and the emitted default never breaks `nix eval --json`.
  jsonSafe =
    depth: v:
    let
      t = builtins.tryEval v;
      val = t.value;
    in
    if !t.success then
      "<error>"
    else if builtins.isFunction val then
      "<function>"
    else if builtins.isAttrs val then
      (
        if (val.type or null) == "derivation" then
          "<derivation>"
        else if depth <= 0 then
          "<...>"
        else
          builtins.mapAttrs (_: jsonSafe (depth - 1)) val
      )
    else if builtins.isList val then
      (if depth <= 0 then "<...>" else map (jsonSafe (depth - 1)) val)
    else
      val;

  # `default` is included, sanitized to a JSON-safe value (`jsonSafe`) so an unserializable node rides through
  # as a placeholder rather than crashing or vanishing — an enumeration serving concrete simple defaults still
  # signals the shape of a complex one (`"<derivation>"`) instead of silently dropping it.
  defaultAttr = opt: if opt ? default then { default = jsonSafe maxDepth opt.default; } else { };

  # One option leaf -> its JSON-safe enumeration record: `_type`/description/type-NAME, plus `default` (JSON-
  # safe) and `formals` when present (a gen-lib member carries `functionArgs` formals, not a `.type`).
  cleanLeaf =
    opt:
    {
      _type = "option";
      description = opt.description or "";
      type = typeName (opt.type or null);
    }
    // defaultAttr opt
    // (if opt ? formals then { formals = opt.formals; } else { });

  # The tree walk (mirrors the projections' own walk): sanitize at each option leaf, recurse through every
  # other attrset, pass non-attrs through. A leaf's `.type` is reduced to its NAME here — NO descent into a
  # submodule leaf's `getSubOptions` (BOUNDED: option trees nest recursively, so the agent completes PATHS
  # from the attrset nesting + each option's type-name/description, never a fully-expanded — possibly non-
  # terminating — type tree).
  cleanTree =
    node:
    if isOpt node then
      cleanLeaf node
    else if builtins.isAttrs node then
      builtins.mapAttrs (_: cleanTree) node
    else
      node;

  # One aspect node -> its JSON-safe record: description + its facet sub-options, descended ONE level. This is
  # the one place a submodule is descended, because the aspect-list contract is "aspect names + their facets":
  # force the facet option nodes via `getSubOptions {}` ONE level (bounded — a flat facet set) and clean each
  # with `cleanLeaf`, which reduces a settings-shaped facet to its `submodule` type-name (its fields ride
  # inside that facet's own submodule type, descended further only by a nixd worker in-process, not on the
  # wire). Declaration-only (the projection synthesizes the facet nodes from static records), so this stays
  # resolution-fixpoint-free like the projection it reads.
  cleanAspect = node: {
    _type = "option";
    description = node.description or "";
    type = "submodule";
    settings = builtins.mapAttrs (_: cleanLeaf) (node.type.getSubOptions { });
  };

  # The three-section keys the composed views emit — the nixd option-provider config section names (`den` =
  # the option-declaration tree, `den-aspects` = the aspect registry, `gen` = the gen-lib API surface). Both
  # views key IDENTICALLY so a fleet exposes them under one namespaced output and the MCP server and a nixd
  # worker index the same sections.
  forNixd =
    {
      options,
      aspects,
      keySemantics ? { },
      # `null` is the "not supplied" sentinel: when omitted, `aspectsProjection` applies its OWN structural-key
      # default (rather than this composer duplicating that list); a supplied list is forwarded through.
      structuralKeys ? null,
      libs ? { },
    }:
    {
      den = optionsProjection { inherit options; };
      "den-aspects" = aspectsProjection (
        { inherit keySemantics; } // (if structuralKeys == null then { } else { inherit structuralKeys; })
      ) { inherit aspects; };
      gen = genLibProjection { } { inherit libs; };
    };

  # The JSON-safe enumeration view object: sanitize a forNixd surface (or a single tree) to the WIRE shape.
  enumerate = {
    # Sanitize a forNixd option-leaf tree (`den` or `gen` — both are option-leaf trees) to JSON-safe shape.
    optionsView = cleanTree;
    # Sanitize a forNixd `den-aspects` registry: aspect name -> node, each descended one level for its facets.
    aspectsView = builtins.mapAttrs (_: cleanAspect);
    # The convenience over a WHOLE forNixd surface: the three JSON-safe trees keyed exactly as `forNixd` keys
    # them. This is the value a fleet exposes for the MCP enumeration server — every leaf serializes cleanly
    # under `nix eval --json`, functions dropped, aspect facets listed.
    fromForNixd = surface: {
      den = cleanTree surface.den;
      "den-aspects" = builtins.mapAttrs (_: cleanAspect) surface."den-aspects";
      gen = cleanTree surface.gen;
    };
  };

  # The WIRE consumer entry: the same inputs `forNixd` takes, returning the three JSON-safe enumeration trees
  # (`enumerate.fromForNixd` over `forNixd`). A fleet exposes BOTH views under one namespaced flake output so
  # the MCP server `nix eval --json`s the enumeration while a nixd worker points at the in-process view.
  forNixdJSON = args: enumerate.fromForNixd (forNixd args);
in
{
  inherit enumerate forNixd forNixdJSON;
}
