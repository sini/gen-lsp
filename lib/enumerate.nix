# The JSON-safe enumeration VIEW over the projections — ONE projection, TWO views. `forNixd` (composed here)
# is the IN-PROCESS view a nixd worker walks: an option leaf's `.type` is a gen-schema/nixpkgs type RECORD
# carrying functions (`check`/`merge`/`getSubOptions`) and an aspect node's `.type.getSubOptions` is itself a
# function — nixd calls them in its own evaluator. `forNixdJSON` is the WIRE view — `builtins.toJSON` (what an
# MCP enumeration server's `nix eval --json` subprocess runs) cannot serialize a function ("cannot convert a
# function to JSON"), so `enumerate` re-projects each tree into a JSON-safe ENUMERATION shape: an option leaf
# keeps its `_type`/description/type-NAME/(JSON-safe default), every function dropped, and a SUBMODULE leaf is
# DESCENDED recursively through `getSubOptions` into a nested `subOptions` tree so an agent reads the full
# shape + each field's default. Keeping BOTH views in the library (not one in a downstream server) makes the
# library the single source of truth and leaves the MCP server a dumb thin transport (`nix eval --json`, no
# logic). Pure builtins (no prelude/gen dep) so the library stays nixpkgs-lib-free.
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
  # default might carry) AND against a self-referential submodule type in the `subOptions` descent. At the
  # bound a node renders opaque (`"<...>"`) / stops descending rather than recursing forever.
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
  # safe) and `formals` when present (a gen-lib member carries `functionArgs` formals, not a `.type`). The
  # recursive `subOptions` descent is attached by `cleanNode`, not here (this is the leaf's own scalar shape).
  cleanLeaf =
    opt:
    {
      _type = "option";
      description = opt.description or "";
      type = typeName (opt.type or null);
    }
    // defaultAttr opt
    // (if opt ? formals then { formals = opt.formals; } else { });

  # The sub-options one SUBMODULE level down, JSON-safe-guarded. A gen-merge submodule DEFERS `getSubOptions`
  # (it returns `{ }` — its sub-options are reachable only by evaluating `getSubModules` through the module
  # fixpoint, which needs `evalModuleTree`, out of this pure lib): such a real option submodule bottoms out
  # EMPTY here and is expanded by a nixd worker in-process instead. A SYNTHESIZED submodule (an aspect facet
  # or field node, whose `getSubOptions = _: <records>`) returns its sub-options, which the walk surfaces. The
  # call is `tryEval`-guarded and shape-checked so a forcing/throwing/non-attrs descent degrades to empty,
  # never crashing the wire view; only a `submodule`-named type is descended (a scalar/attrsOf leaf is not).
  subOptionsOf =
    t:
    if t == null || (t.name or null) != "submodule" then
      { }
    else
      let
        r = builtins.tryEval (if t ? getSubOptions then t.getSubOptions [ ] else { });
      in
      if r.success && builtins.isAttrs r.value then r.value else { };

  # The unified WIRE walk (one function for every section — options tree, aspect registry, gen surface): at an
  # option leaf, sanitize it (`cleanLeaf`) AND descend its submodule sub-options RECURSIVELY into a nested
  # `subOptions` tree (so an agent reads aspect -> facet -> field + each field's default); at a plain attrset
  # (the option-tree's own nesting, or an aspect registry keyed by name) recurse member-wise; pass non-attrs
  # through. The `subOptions` key is attached ONLY when the descent yields a non-empty set — a deferred
  # gen-merge options submodule stays a bare `submodule` type-name (nixd expands it in-process), a synthesized
  # aspect facet surfaces its fields. Bounded by `depth` (the submodule-descent axis is the only unbounded one
  # — a self-referential submodule type terminates at the bound; plain-attrset nesting is a finite value).
  cleanNode =
    depth: node:
    if isOpt node then
      let
        base = cleanLeaf node;
        subs = if depth > 0 then subOptionsOf (node.type or null) else { };
        cleanedSubs = builtins.mapAttrs (_: cleanNode (depth - 1)) subs;
      in
      if cleanedSubs == { } then base else base // { subOptions = cleanedSubs; }
    else if builtins.isAttrs node then
      builtins.mapAttrs (_: cleanNode depth) node
    else
      node;

  # The unified WIRE sanitizer over any single projected section.
  sanitize = cleanNode maxDepth;

  # The composed IN-PROCESS view: the three projections keyed GENERICALLY (`options` = the option-declaration
  # tree, `aspects` = the aspect registry, `libs` = the gen-lib API surface). gen-lsp is a general library, so
  # it emits neutral section names; a consumer maps these onto its own nixd option-provider section names (a
  # den fleet routes `options` -> its `den` provider, etc.) in its own binding, NOT here.
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
      options = optionsProjection { inherit options; };
      aspects = aspectsProjection (
        { inherit keySemantics; } // (if structuralKeys == null then { } else { inherit structuralKeys; })
      ) { inherit aspects; };
      libs = genLibProjection { } { inherit libs; };
    };

  # The JSON-safe enumeration view object: sanitize a single projected tree, or a WHOLE forNixd surface.
  enumerate = {
    # Sanitize one projected section (an option-leaf tree or an aspect registry) to the JSON-safe WIRE shape.
    inherit sanitize;
    # Sanitize a WHOLE forNixd surface: every section cleaned, keyed exactly as `forNixd` keyed it. Key-
    # agnostic (maps over whatever sections the surface carries), so it tracks `forNixd`'s section names.
    fromForNixd = builtins.mapAttrs (_: sanitize);
  };

  # The WIRE consumer entry: the same inputs `forNixd` takes, returning the JSON-safe enumeration surface
  # (`enumerate.fromForNixd` over `forNixd`). A fleet exposes BOTH views under one namespaced flake output so
  # the MCP server `nix eval --json`s the enumeration while a nixd worker points at the in-process view.
  forNixdJSON = args: enumerate.fromForNixd (forNixd args);
in
{
  inherit enumerate forNixd forNixdJSON;
}
