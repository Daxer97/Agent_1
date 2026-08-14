# Memory guest.
#
# The knowledge store and its vector index. Reachable from the agentic guest
# for retrieval and retention, and from the ingress application interface for
# the inspection console. Not routable from the user network.

{ ... }:

{
  imports = [
    ../modules/memory-stack.nix
  ];
}
