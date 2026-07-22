# The gen-lib API-surface PROJECTION: project a consumer-supplied attrset of gen substrate libraries as an
# option-tree of members so a Nix LSP (nixd) completes/hovers a gen-lib member. THIN BY DESIGN — the gen
# libs are FLAT function attrsets carrying no type/signature metadata, so this projects member NAMES +
# `functionArgs` PARTIAL formals, NEVER typed signatures. Membership is the CONSUMER's concern: the caller
# supplies exactly the `libs` it wants surfaced (a fleet passes its substrate libs directly), so a mixed
# helper+lib bundle is filtered BEFORE it reaches here — there is NO hardcoded allowlist baked into this
# projection. The walk reads only `attrNames` + `functionArgs` (config-free): it never enters a resolution
# fixpoint, so no resolved `.config` is forced. Pure builtins (no prelude/schema dep) so the library stays
# nixpkgs-lib-free.
{ }:
let
  # DEFERRED ENRICHMENT (doc citations): a member's hover `description` wants per-lib doc text (a README or a
  # spec REFERENCE), but no doc source is reachable from a lib's pure function VALUE — the libs are flake
  # inputs (READMEs live in input store paths, absent from the `.lib` attrset) and specs live in a separate
  # papers repo. So `docFor` stubs to "" (empty description, never an error); wiring real docs needs the
  # lib-source paths threaded, out of this projection's pure scope.
  docFor = _libName: _member: "";

  # One member -> an option leaf: name + doc (deferred) + `functionArgs` formals when the member is a lambda.
  # A non-function member (a nested sub-namespace) projects a bare leaf carrying no `formals` key. Formals
  # are PARTIAL by nature: `functionArgs` reports only the outermost attrset pattern's fields (`{ a, b }`),
  # empty for a positional lambda (`x: …`) — the thin surface a completion offers, not a full signature.
  projectGenLibMember =
    libName: member: fn:
    {
      _type = "option";
      description = docFor libName member;
    }
    // (if builtins.isFunction fn then { formals = builtins.functionArgs fn; } else { });

  # One lib -> an attrset of its projected members. Descent is ONE level (lib -> members): a member that is
  # itself a sub-namespace projects as a single bare leaf, never re-walked. A lib carried as a bare function
  # (or any non-attrset) projects an empty member set rather than tripping `mapAttrs` — the guard keeps the
  # projection TOTAL over whatever the consumer supplies.
  projectGenLib =
    libName: value:
    if builtins.isAttrs value then builtins.mapAttrs (projectGenLibMember libName) value else { };
in
{
  # The projection entry: `genLibProjection { } { libs }` -> the option-tree of projected members, keyed by
  # the consumer's own lib names. The construction argument is empty today (the allowlist that lived here is
  # gone — membership is the consumer's, see the header); it is kept curried to mirror the other projections'
  # `<construct> { data }` shape and to hold future construction-time config without a signature break.
  #
  # KNOWN LIMIT (thin by design): member NAMES + `functionArgs` formals, NOT typed signatures — the gen libs
  # carry no type metadata. Doc citations are a deferred enrichment (see `docFor`): a member's `description`
  # is empty until lib-source paths are threaded.
  genLibProjection =
    { }:
    { libs }:
    builtins.mapAttrs projectGenLib libs;
}
