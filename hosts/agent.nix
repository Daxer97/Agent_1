# Agentic guest.
#
# The only host on which model-generated code runs. It is never consolidated
# with another role: its separation is the premise every other control assumes.
# It holds no inference credential — the broker, which runs here as a separate
# user, is the only process that does.

{ ... }:

{
  imports = [
    ../modules/egress-broker.nix
    ../modules/hermes-agent.nix
    ../modules/hermes-profiles.nix
    ../modules/hermes-svc-workloads.nix
    ../modules/instrumentation.nix
  ];
}
