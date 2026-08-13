# Observability guest.
#
# Used only when the observability role owns a guest of its own. While it is
# aliased onto the secret store guest this file is never evaluated: the flake
# builds a configuration for active roles only.

{ ... }:

{
  imports = [
    ../modules/observability.nix
    ../modules/observability-eval.nix
  ];
}
