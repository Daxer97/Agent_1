# Secret store server.
#
# The store holds every operational secret, with a policy per identity and an
# audit device that records each access, granted or denied. The audit trail is
# what turns the central invariant — no agentic guest can read an inference
# credential — into something demonstrable rather than asserted.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  store = cfg.secretStore;
in
{
  config = lib.mkIf (builtins.elem "secrets" cfg.rolesHosted) {
    services.openbao = {
      enable = true;
      package = pkgs.openbao;

      settings = {
        ui = false;

        # TLS is mandatory. The store is not exposed in the clear even on an
        # internal network.
        listener.tcp = [{
          address = "0.0.0.0:${toString store.port}";
          tls_cert_file = "/var/lib/openbao/tls/cert.pem";
          tls_key_file = "/var/lib/openbao/tls/key.pem";
          tls_min_version = "tls12";
        }];

        storage.file.path = "/var/lib/openbao/data";
        api_addr = "https://${store.address}:${toString store.port}";
        cluster_addr = "https://${store.address}:${toString store.clusterPort}";

        # Key material must not reach swap.
        disable_mlock = false;

        log_level = cfg.observability.logLevel;
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/openbao/data 0700 openbao openbao -"
      "d /var/lib/openbao/tls  0700 openbao openbao -"
      "d ${store.auditPath}    0700 openbao openbao -"
      "d ${cfg.backup.stagingPath} 0700 root root -"
    ];

    # The unseal method is an operational choice with a consequence worth
    # knowing before it is discovered at three in the morning: with manual
    # unsealing, a reboot of this guest requires human intervention and every
    # service that depends on the store stays down until it happens.
    warnings = lib.optional (store.unsealMethod == "shamir-manual") ''
      The secret store is configured for manual unsealing. A restart of
      ${cfg.guests.secrets.hostName} will require an operator to supply
      ${toString store.keyThreshold} of the ${toString store.keyShares} unseal
      shares before any dependent service can start.
    '';
  };
}
