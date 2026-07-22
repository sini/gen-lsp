# Standalone (non-flake) entry. Flake consumers should use the `.lib` output.
#
# gen-lsp is dep-free pure builtins, so there is no fetchTree/lock dance here: the
# library takes no arguments.
import ./lib { }
