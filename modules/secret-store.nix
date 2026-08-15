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

  durationDays = value:
    let
      match = builtins.match "([0-9]+)(ms|s|m|h|d)?" value;
      amount = lib.toInt (lib.head match);
      unit = if lib.last match == null then "s" else lib.last match;
      seconds = amount * { ms = 1; s = 1; m = 60; h = 3600; d = 86400; }.${unit};
    in
    (seconds + 86399) / 86400;
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
        #
        # Written the way the module types it, which is not the way the HCL
        # documentation shows it. In HCL a listener is a repeated block keyed
        # by its kind — listener "tcp" { ... } — so the JSON translation is a
        # list under the kind. The NixOS option is instead an attribute set
        # keyed by a name of one's choosing, with the kind given as `type`,
        # and it type-checks: a list here is rejected as not being a listener,
        # which is what "not of type `JSON value'" was reporting.
        listener.default = {
          type = "tcp";
          address = "0.0.0.0:${toString store.port}";
          tls_cert_file = "/var/lib/openbao/tls/cert.pem";
          tls_key_file = "/var/lib/openbao/tls/key.pem";
          tls_min_version = "tls12";
        };

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

    # The audit trail has a declared retention, longer than the general one
    # because it is the documentary evidence that the separation of policies
    # is applied rather than merely declared. Nothing else would rotate it: it
    # is a file the store appends to for as long as it runs, on the guest
    # whose disk already carries every observability backend.
    #
    # Copied and truncated rather than renamed: the store holds the descriptor
    # open, and a rotation that renames the file leaves it writing to an inode
    # with no name — the trail keeps growing and stops being readable.
    services.logrotate.settings.openbao-audit = {
      files = "${store.auditPath}/*.log";
      frequency = "daily";
      rotate = durationDays cfg.observability.retention.audit;
      maxage = durationDays cfg.observability.retention.audit;
      copytruncate = true;
      compress = true;
      missingok = true;
      notifempty = true;
    };

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
