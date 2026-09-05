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

        # There is deliberately no disable_mlock here. The field is gone in
        # openbao 2.4 — false is refused with a message naming the line, true
        # is accepted and warned about as unknown — and what it was for is
        # provided by the unit: the NixOS module sets MemorySwapMax=0, so the
        # kernel never swaps this cgroup's memory, which does not depend on a
        # process holding IPC_LOCK. That capability is unreachable anyway,
        # since the module runs the store under a dynamic user with an empty
        # capability bounding set.

        log_level = cfg.observability.logLevel;
      };
    };

    # There is no openbao account to own anything: the module runs the store
    # under a dynamic user, which exists only while the unit does. Rules
    # naming one are refused by systemd-tmpfiles with "unknown user", and the
    # directories they were meant to create are simply never created — which
    # is why the state directory was empty and the listener had no
    # certificate to read.
    #
    # The three that belong to the store are provided by the unit instead:
    # StateDirectory for its data, LogsDirectory for the audit trail, and the
    # certificate below. What is left here is the one directory that belongs
    # to root.
    systemd.tmpfiles.rules = [
      "d ${cfg.backup.stagingPath} 0700 root root -"
    ];

    systemd.services.openbao = {
      # The audit trail is written by the same dynamic user, so the directory
      # has to be one systemd hands it. LogsDirectory is that, and it is the
      # reason auditPath is asserted to live under /var/log.
      serviceConfig.LogsDirectory = lib.removePrefix "/var/log/" store.auditPath;

      path = [ pkgs.openssl ];

      # TLS is mandatory on the listener and the certificate cannot be placed
      # by hand: the account that must read it exists only while the unit
      # runs, and its state directory is private to that account. So the
      # store issues its own on first start, with the address in the subject
      # alternative name because that is what every client connects to.
      #
      # Self-signed and replaceable. A certificate from an internal authority
      # dropped in the same path, with the unit stopped, is the whole of what
      # changing it involves.
      preStart = ''
        # The names the certificate has to carry. The address is what the
        # other guests connect to; the host name is what an operator types;
        # loopback is what the CLI on this guest uses when BAO_ADDR is unset,
        # which is every `bao status` typed without a preamble.
        san=${lib.escapeShellArg (
          "subjectAltName=IP:${store.address},IP:127.0.0.1"
          + ",DNS:${cfg.guests.secrets.hostName},DNS:localhost")}

        # Regenerated when that set changes, not only when the file is
        # missing. Without the comparison a certificate outlives the parameter
        # it was issued from: change the address and the store keeps
        # presenting the old one, and the failure surfaces on the clients as a
        # name mismatch rather than here as a stale file.
        if [ ! -s /var/lib/openbao/tls/cert.pem ] \
           || [ "$(cat /var/lib/openbao/tls/san 2>/dev/null)" != "$san" ]; then
          mkdir -p /var/lib/openbao/tls
          openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
            -subj "/CN=${cfg.guests.secrets.hostName}" \
            -addext "$san" \
            -keyout /var/lib/openbao/tls/key.pem \
            -out /var/lib/openbao/tls/cert.pem
          chmod 600 /var/lib/openbao/tls/key.pem
          printf '%s' "$san" > /var/lib/openbao/tls/san
        fi

        # The public half, where the operator and the agents of the other
        # guests can read it. Nothing else publishes it, and every client
        # that verifies this listener needs it.
        install -m 0444 /var/lib/openbao/tls/cert.pem /run/openbao/cert.pem
      '';
    };

    assertions = [{
      assertion = lib.hasPrefix "/var/log/" store.auditPath;
      message = ''
        hermes.secretStore.auditPath is ${store.auditPath}, and the store
        writes its audit trail as a dynamic user that can only be given a
        directory under /var/log, through LogsDirectory. A path elsewhere
        would be created by nobody and the audit device would fail to enable
        — after the phase that depends on it has reported success.
      '';
    }];

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
