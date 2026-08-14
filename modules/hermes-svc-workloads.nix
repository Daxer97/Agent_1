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

  durationSeconds = value:
    let
      match = builtins.match "([0-9]+)(ms|s|m|h|d)?" value;
      amount = lib.toInt (lib.head match);
      unit = if lib.last match == null then "s" else lib.last match;
    in
    amount * { ms = 1; s = 1; m = 60; h = 3600; d = 86400; }.${unit};

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

        # The concurrency cap is a mutual exclusion between the runs, not a
        # cgroup property. It waits rather than failing: two workloads whose
        # calendars overlap should queue, and a refusal here would be counted
        # as a failed run by the alert that watches them.
        ExecStart =
          "${pkgs.util-linux}/bin/flock --wait ${toString (durationSeconds workload.timeout)} "
          + "/run/hermes-svc.lock "
          + "${hermesEnv}/bin/hermes run --workload ${name} --output ${workload.outputPath}";
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

      systemd.tmpfiles.rules = [
        # The lock the runs take against each other. Created here rather than
        # by the units: /run is not writable by the service user, and a
        # runtime directory owned by a unit is removed when that unit stops —
        # which is every time a workload finishes.
        "f /run/hermes-svc.lock 0660 hermes hermes -"
      ] ++ lib.mapAttrsToList
        (_: workload: "d ${workload.outputPath} 0750 hermes hermes -")
        cfg.programmatic.workloads;

      # Resource share of the batch plane. Together with the connection share
      # the broker reserves for the interactive plane, this is what keeps a
      # batch from degrading interactive latency — the failure that satisfies
      # every structural isolation check and violates the objective anyway.
      #
      # The concurrency cap is NOT expressed here. TasksMax counts tasks, not
      # units: set to the number of admitted workloads it caps the runs at one
      # thread each, and the first thread the runtime starts — or the first
      # subprocess a code-execution tool spawns — fails with EAGAIN. The cap
      # is the lock taken by the runs themselves.
      systemd.slices."hermes-svc" = {
        description = "Programmatic plane workloads";
        sliceConfig = {
          CPUWeight = toString cfg.programmatic.cpuWeight;
          MemoryHigh = cfg.programmatic.memoryHigh;
        };
      };

      assertions = [{
        assertion = cfg.programmatic.maxConcurrentWorkloads == 1;
        message = ''
          hermes.programmatic.maxConcurrentWorkloads is enforced by a single
          lock shared by the workload units, which admits one run at a time.
          A higher cap needs a counted semaphore; declaring it without one
          would record a limit that nothing applies.
        '';
      }];
    };
}
