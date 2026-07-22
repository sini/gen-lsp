# The aspect-registry PROJECTION: `genLsp.aspectsProjection { keySemantics, structuralKeys ? … } { aspects }`
# projects each aspect instance into a nixd-walkable submodule option node whose sub-options are the
# instance's FACET keys. Facet-generic — the projectable facets come off a construction-time `keySemantics`
# map, so this fixture hand-builds a SYNTHETIC map + instances (plain attrsets; no gen-aspects/den dep) with
# TWO differently-named facets to prove the projection is not `settings`-hardcoded, plus a `class` bucket and
# structural keys that must be skipped, and a settings-shaped facet that must descend to its fields.
{ genLsp, ... }:
let
  keySemantics = {
    settings = {
      category = "facet";
    };
    # a SECOND, differently-named facet — proves the projection reads the map, not a `settings` literal.
    guards = {
      category = "facet";
    };
    # a class content bucket — routed by category, must be skipped (never a projected option).
    colmena = {
      category = "class";
    };
  };
  aspects = {
    web = {
      # structural identity keys — NOT projectable facets.
      name = "web";
      description = "the web aspect";
      meta = { };
      # a settings-shaped facet: a record of field-specs (`{ default; merge ? }`) — descends to its fields.
      settings = {
        port = {
          default = 80;
          merge = "replace";
        };
        host = {
          default = "localhost";
        };
      };
      # a second facet under a different name.
      guards = {
        strict = {
          default = true;
        };
      };
      # class content — skipped.
      colmena = {
        imports = [ ];
      };
    };
  };

  proj = genLsp.aspectsProjection { inherit keySemantics; } { inherit aspects; };
  webSubs = proj.web.type.getSubOptions [ ];
  settingsSubs = webSubs.settings.type.getSubOptions [ ];
in
{
  flake.tests.aspects = {
    # The aspect node is a nixd submodule option (an LSP completes it as a submodule).
    test-node-is-submodule-option = {
      expr = proj.web._type + "/" + proj.web.type.name;
      expected = "option/submodule";
    };

    # The node's `description` is the instance's own (falls back to `"Aspect ${name}"` when absent).
    test-description = {
      expr = proj.web.description;
      expected = "the web aspect";
    };

    # BOTH differently-named facets project as sub-options — the projection is keySemantics-driven, not
    # `settings`-hardcoded.
    test-both-facets-project = {
      expr = builtins.sort builtins.lessThan (
        builtins.filter (k: k == "settings" || k == "guards") (builtins.attrNames webSubs)
      );
      expected = [
        "guards"
        "settings"
      ];
    };

    # The settings-shaped facet descends one level into per-field option leaves — `port`'s default rides
    # through from its field-spec.
    test-settings-field-descended = {
      expr = settingsSubs.port.default;
      expected = 80;
    };

    # The descended field is an option leaf (a nixd leaf, not a further submodule).
    test-settings-field-is-leaf = {
      expr = settingsSubs.host._type + "/" + settingsSubs.host.type.name;
      expected = "option/raw";
    };

    # A `class` content bucket is NOT projected as a facet option.
    test-class-not-projected = {
      expr = webSubs ? colmena;
      expected = false;
    };

    # Structural identity keys are NOT projected as facet options.
    test-structural-not-projected = {
      expr = webSubs ? name || webSubs ? meta;
      expected = false;
    };
  };
}
