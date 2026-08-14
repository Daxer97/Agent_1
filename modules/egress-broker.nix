# Egress broker.
#
# The component that moves the inference credential outside the perimeter in
# which model-generated code runs. Code execution stays available to the
# agent, and the container is what contains it; that premise protects the
# host, but it does not protect what sits inside the container. A gateway key
# present in the process environment can be read by the agent itself, or by a
# compromised skill, with a single call. The broker keeps the real credential
# on the other side of a process boundary and hands the agentic runtime a
# low-sensitivity internal token instead — revocable, scoped, and worth
# nothing outside this host.
#
# The contract the implementation must honour is in pkgs/egress-broker.

{ config, lib, pkgs, egressBroker, ... }:

let
  cfg = config.hermes;
  runtime = cfg.secretStore.runtimeSecretsPath;
in
{
  config = lib.mkIf (builtins.elem "agent" cfg.rolesHosted) {
    users.users.hermes-broker = {
      isSystemUser = true;
      group = "hermes-broker";
      uid = cfg.broker.uid;
      shell = "${pkgs.shadow}/bin/nologin";
    };

    users.groups.hermes-broker.gid = cfg.broker.uid;

    systemd.services.egress-broker = {
      description = "HERMES-AGENT — egress broker";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "bao-agent-broker.service" ];
      requires = [ "bao-agent-broker.service" ];
      wants = [ "network-online.target" ];

      environment = {
        BROKER_UPSTREAM = cfg.broker.upstream;
        BROKER_LISTEN_HOST = cfg.broker.listenAddress;
        BROKER_LISTEN_PORT = toString cfg.broker.port;
        BROKER_TOKENS_FILE = "${runtime}/broker-tokens.json";
        BROKER_CREDENTIALS_FILE = "${runtime}/broker-credentials.json";
        BROKER_BUDGET_SOFT = toString cfg.broker.budgetSoft;
        BROKER_BUDGET_HARD = toString cfg.broker.budgetHard;
        BROKER_BUDGET_WINDOW_SECONDS = toString cfg.broker.budgetWindowSeconds;
        BROKER_MAX_CONNECTIONS = toString cfg.broker.maxConnections;
        BROKER_RESERVE_INTERACTIVE = toString cfg.broker.reserveInteractive;
        BROKER_TIMEOUT_SECONDS = toString (lib.toInt
          (lib.removeSuffix "s" cfg.broker.timeout));
        BROKER_LOG_LEVEL = lib.toUpper cfg.observability.logLevel;
        BROKER_REFERER = cfg.models.gateway.referer;
        BROKER_APP_TITLE = cfg.models.gateway.appTitle;
        OTEL_EXPORTER_OTLP_ENDPOINT =
          "http://${cfg.observability.address}:${toString cfg.observability.collectorGrpcPort}";
        OTEL_RESOURCE_ATTRIBUTES = "service.name=egress-broker";
      };

      serviceConfig = {
        ExecStart = "${egressBroker}/bin/egress-broker";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        User = "hermes-broker";
        Group = "hermes-broker";
        Restart = "always";
        RestartSec = "2s";

        # This service holds the only copy of the real credential on the
        # guest. Its surface is reduced further than that of any other
        # service here.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";

        # No dump: it would contain the credential in clear text.
        LimitCORE = 0;
      };
    };
  };
}
