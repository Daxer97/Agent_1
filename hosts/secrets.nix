# Secret store guest.
#
# It also hosts the observability role when that role is aliased onto this one.
# The modules below gate themselves on the roles this guest actually hosts, so
# consolidating or separating them is a parameter change rather than a change
# of configuration.
#
# The constraint that survives consolidation: the secret store must not share
# an out-of-memory event with the observability stack. It is blocking at boot,
# and the memory guardrails in the observability modules are what enforce that.

{ ... }:

{
  imports = [
    ../modules/secret-store.nix
    ../modules/observability.nix
    ../modules/observability-eval.nix
  ];
}
