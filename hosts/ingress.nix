# Ingress guest — the trust boundary of the platform.
#
# It is the only dual-homed guest: one interface in the user-facing zone, one
# in the application zone. Every flow towards a downstream service is admitted
# from the application interface alone.

{ ... }:

{
  imports = [
    ../modules/authelia.nix
    ../modules/ingress.nix
    ../modules/hermes-profiles.nix
  ];
}
