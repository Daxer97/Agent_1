# Programmatic plane — unattended workloads.
#
# The trigger is a system timer: nothing listens, and no firewall rule exposes
# this plane. Its exposure is nevertheless wider than the interactive one,
# because the input arrives from systems — repositories, tickets, internal
# hooks — rather than from a person who reads what they paste. The primary
# countermeasure is that toolsets are granted by inclusion.

{ config, lib, pkgs, hermesEnv, ... }:

let
  cfg = config.hermes;
  runtime = cfg.secretStore.runtimeSecretsPath;

  brokerUrl = "http://${cfg.broker.host}:${toString cfg.broker.port}/v1";
  memoryUrl = "http://${cfg.guests.memory.address}:${toString cfg.memory.hindsight.apiPort}";
  otlpEndpoint = "http://${cfg.observability.address}:${toString cfg.observability.collectorGrpcPort}";

  mkTimer = name: workload: lib.nameValuePair "hermes-svc-${name}" {
    description = "Trigger for the ${name} programmatic workload";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = workload.schedule;
      Persistent = true;
      RandomizedDelaySec = workload.jitter;
    };
  };

  mkService = name: workload:
    let
      profile = "${cfg.agent.profilePrefixService}-${name}";
    in
    lib.nameValuePair "hermes-svc-${name}" {
      description = "Programmatic workload ${name}, running as profile ${profile}";
      after = [ "bao-agent-hermes.service" "egress-broker.service" ];
      requires = [ "egress-broker.service" ];

      environment = {
        HERMES_HOME = cfg.agent.servicePath;
        HERMES_PROFILE = profile;
        OPENAI_BASE_URL = brokerUrl;

        HERMES_MODEL_MAIN = cfg.models.main;
        HERMES_MODEL_AUX_DEFAULT = cfg.models.auxiliaryDefault;
        HERMES_DELEGATION_MODEL = cfg.models.delegation;

        # Granted by inclusion, never by exclusion: a list of exclusions only
        # protects against the capabilities somebody thought of excluding.
        HERMES_TOOLSETS = lib.concatStringsSep "," workload.toolsets;

        # In an unattended job the iteration cap is a spending cap before it
        # is a correctness cap, so it is declared for every workload.
        HERMES_MAX_ITERATIONS = toString workload.maxIterations;

        # Persistent memory stays off unless the workload must keep state
        # between runs, and then on a service bank disjoint from the user
        # ones.
        HERMES_MEMORY_MODE = workload.memoryMode;
        HINDSIGHT_API_URL = memoryUrl;

        HERMES_NEMO_RELAY_PLUGINS_TOML = "/etc/hermes/plugins-programmatic.toml";
        OTEL_EXPORTER_OTLP_ENDPOINT = otlpEndpoint;
        OTEL_RESOURCE_ATTRIBUTES =
          "service.name=hermes-svc,plane=programmatic,workload=${name}";
      };

      serviceConfig = {
        Type = "oneshot";
        Slice = "hermes-svc.slice";
        ExecStart = "${hermesEnv}/bin/hermes run --workload ${name} --output ${workload.outputPath}";
        EnvironmentFile = [ "${runtime}/hermes-svc.env" ];
        User = "hermes";
        Group = "hermes";
        TimeoutStartSec = workload.timeout;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ cfg.agent.servicePath workload.outputPath ];
      };
    };
in
{
  config = lib.mkIf
    (builtins.elem "agent" cfg.rolesHosted && cfg.programmatic.workloads != { })
    {
      systemd.timers = lib.mapAttrs' mkTimer cfg.programmatic.workloads;
      systemd.services = lib.mapAttrs' mkService cfg.programmatic.workloads;

      systemd.tmpfiles.rules = lib.mapAttrsToList
        (_: workload: "d ${workload.outputPath} 0750 hermes hermes -")
        cfg.programmatic.workloads;

      # Concurrency cap at the scheduler level. Together with the connection
      # share the broker reserves for the interactive plane, this is what
      # keeps a batch from degrading interactive latency — the failure that
      # satisfies every structural isolation check and violates the objective
      # anyway.
      systemd.slices."hermes-svc" = {
        description = "Programmatic plane workloads";
        sliceConfig = {
          TasksMax = toString cfg.programmatic.maxConcurrentWorkloads;
          CPUWeight = toString cfg.programmatic.cpuWeight;
          MemoryHigh = cfg.programmatic.memoryHigh;
        };
      };
    };
}
