{
  description = "gen-lsp: LSP/MCP projection tooling for the gen module stack";

  # gen-lsp is DEP-FREE PURE BUILTINS: the library (./lib) reads gen value *shapes*
  # (attrsets such as `{ _type = "option"; … }`) using only `builtins`. It imports NO
  # gen library and NO nixpkgs `lib`, so the root flake declares no inputs. gen-merge /
  # gen-aspects are pulled ONLY in ci/ as test fixtures. The nixpkgs input and the
  # `packages.mcp` output (the Rust MCP server) get ADDED in later tasks.
  outputs =
    { self }:
    {
      lib = import ./lib { };
    };
}
