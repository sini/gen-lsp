# The gen-lib API-surface PROJECTION: `genLsp.genLibProjection { } { libs }` projects a consumer-supplied
# attrset of gen libraries into an option-tree of members — member NAMES + `functionArgs` PARTIAL formals,
# thin by design (the gen libs carry no signature metadata). The fixture hand-builds a SYNTHETIC `libs`
# bundle (plain attrsets/lambdas; no gen-* dep) MIXING function members, a positional lambda, a non-function
# sub-namespace, and two lib entries that are NOT attrsets — proving membership is the consumer's (every
# supplied key is projected, no allowlist filters) and the projection is TOTAL over odd inputs.
{ genLsp, ... }:
let
  libs = {
    # a lib = an attrset of function/value members.
    mylib = {
      # a lambda with an attrset pattern — its `functionArgs` formals ride through.
      make = { a, b }: a + b;
      # a POSITIONAL lambda — a function, but `functionArgs` is empty (no named args).
      helper = x: x;
      # a non-function member (a nested sub-namespace) — a bare leaf, no `formals`.
      sub = {
        nested = 1;
      };
    };
    other = {
      run =
        {
          flag ? true,
        }:
        flag;
    };
    # a lib carried as a BARE FUNCTION (non-attrset) — must project gracefully to `{ }`.
    weird = x: x;
    # a lib carried as a scalar (non-attrset, non-function) — must project gracefully to `{ }`.
    scalar = 42;
  };
  proj = genLsp.genLibProjection { } { inherit libs; };
in
{
  flake.tests.genlib = {
    # NO allowlist: every supplied lib key is projected (a mixed bundle is the consumer's concern to filter).
    test-no-allowlist = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames proj);
      expected = [
        "mylib"
        "other"
        "scalar"
        "weird"
      ];
    };

    # A lambda member projects as an option leaf carrying its `functionArgs` formals.
    test-member-formals = {
      expr = {
        optionType = proj.mylib.make._type;
        description = proj.mylib.make.description;
        formals = builtins.sort builtins.lessThan (builtins.attrNames proj.mylib.make.formals);
      };
      expected = {
        optionType = "option";
        # doc citation is a deferred enrichment -> empty description.
        description = "";
        formals = [
          "a"
          "b"
        ];
      };
    };

    # A positional lambda is still a function -> it carries a `formals` key, but empty (no named args).
    test-positional-lambda = {
      expr = {
        hasFormals = proj.mylib.helper ? formals;
        formals = proj.mylib.helper.formals;
      };
      expected = {
        hasFormals = true;
        formals = { };
      };
    };

    # A non-function member (a sub-namespace) projects a BARE leaf — no `formals`, no descent into `nested`.
    test-non-function-member = {
      expr = {
        optionType = proj.mylib.sub._type;
        hasFormals = proj.mylib.sub ? formals;
        noDescent = proj.mylib.sub ? nested;
      };
      expected = {
        optionType = "option";
        hasFormals = false;
        noDescent = false;
      };
    };

    # A lib carried as a bare function projects an EMPTY member set (graceful, no `mapAttrs` trip).
    test-bare-function-lib = {
      expr = proj.weird;
      expected = { };
    };

    # A lib carried as a scalar projects an EMPTY member set (graceful).
    test-scalar-lib = {
      expr = proj.scalar;
      expected = { };
    };
  };
}
