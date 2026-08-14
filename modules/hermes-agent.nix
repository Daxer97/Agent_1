# The two agentic containers.
#
# One module produces both planes. That is deliberate and is the structural
# mitigation of the risk that the two drift apart: skill versions, model
# slugs, iteration caps and guardrails have a single definition, so they
# cannot diverge quietly while both configurations keep working.
#
# What the two planes do not share is equally deliberate: profile, memory
# bank, inference credential, workspace and concurrency budget are distinct.
# The one internal component they do share is the egress broker, and it keeps
# them apart by token and by credential.

{ config, lib, pkgs, hermesEnv, ... }:

let
  cfg = config.hermes;
  runtime = cfg.secretStore.runtimeSecretsPath;

  brokerUrl = "http://${cfg.broker.host}:${toString cfg.broker.port}/v1";
  memoryUrl = "http://${cfg.guests.memory.address}:${toString cfg.memory.hindsight.apiPort}";
  otlpEndpoint = "http://${cfg.observability.address}:${toString cfg.observability.collectorGrpcPort}";

  boolFlag = value: if value then "true" else "false";

  # Environment shared by both planes. Everything here is compile-time
  # configuration; nothing in it is a secret.
  commonEnvironment = {
    OPENAI_BASE_URL = brokerUrl;

    HERMES_MODEL_MAIN = cfg.models.main;
    HERMES_MODEL_DELIBERATION = cfg.models.deliberation;
    HERMES_MODEL_AUX_DEFAULT = cfg.models.auxiliaryDefault;
    HERMES_DELEGATION_MODEL = cfg.models.delegation;
    HERMES_TEMPERATURE_MAIN = toString cfg.models.temperatureMain;

    HERMES_REASONING_MAIN = boolFlag cfg.models.reasoning.main;
    HERMES_REASONING_EFFORT_MAIN = cfg.models.reasoning.mainEffort;
    HERMES_REASONING_DELEGATION = boolFlag cfg.models.reasoning.delegation;
    HERMES_REASONING_AUX = boolFlag cfg.models.reasoning.auxiliary;

    HERMES_MAX_SPAWN_DEPTH = toString cfg.agent.maxSpawnDepth;
    HERMES_MAX_CONCURRENT_CHILDREN = toString cfg.agent.maxConcurrentChildren;

    # Bounds and breakers. Declared here rather than left to the client
    # defaults: the recall bound in particular is what turns an unreachable
    # memory backend into a degraded turn instead of a stalled one, and a
    # bound that is never applied degrades nothing — the turn waits, no error
    # reaches the user, and the alert that watches for it only sees the
    # latency afterwards.
    HERMES_TIMEOUT_INFERENCE = cfg.agent.timeouts.inference;
    HERMES_TIMEOUT_RECALL = cfg.agent.timeouts.recall;
    HERMES_RETRY_BROKER = toString cfg.agent.retries.broker;
    HERMES_RETRY_MEMORY = toString cfg.agent.retries.memory;
    HERMES_CB_BROKER_THRESHOLD = toString cfg.agent.circuitBreaker.brokerThreshold;
    HERMES_CB_BROKER_RESET = cfg.agent.circuitBreaker.brokerReset;
    HERMES_CB_MEMORY_THRESHOLD = toString cfg.agent.circuitBreaker.memoryThreshold;

    OTEL_EXPORTER_OTLP_ENDPOINT = otlpEndpoint;
  };

  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
  };

  jsonFormat = pkgs.formats.json { };

  # Client-side memory configuration, shared by every profile served here.
  # The bank template is the tenancy boundary: it is what separates one
  # user's memory from another's. Because the backend key has no per-bank
  # scope, a mistake here collapses several users onto one bank and produces
  # no error at all.
  memoryClientConfig = jsonFormat.generate "hindsight.json" {
    mode = "local_external";
    api_url = memoryUrl;
    bank_id_template = cfg.memory.hindsight.bankTemplate;
    recall_budget = cfg.memory.hindsight.recallBudget;
    recall_max_tokens = cfg.memory.hindsight.recallMaxTokens;
    recall_prefetch_method = "recall";

    # Consolidated observations rather than raw facts: denser per token and
    # not redundant.
    recall_types = "observation";

    auto_recall = true;
    auto_retain = true;
    retain_async = true;
    retain_every_n_turns = cfg.memory.hindsight.retainEveryNTurns;
    memory_mode = cfg.memory.hindsight.memoryMode;

    # Past this the recall is skipped rather than awaited. It is the same
    # bound as HERMES_TIMEOUT_RECALL, declared on the client that performs the
    # call as well as in the environment, because whichever of the two the
    # runtime honours it must not fall back to a library default measured in
    # tens of seconds.
    recall_timeout = cfg.agent.timeouts.recall;
    recall_retries = cfg.agent.retries.memory;
  };
in
{
  config = lib.mkIf (builtins.elem "agent" cfg.rolesHosted) {
    users.users.hermes = {
      isSystemUser = true;
      group = "hermes";
      uid = cfg.agent.uid;
      home = cfg.agent.statePath;
      createHome = true;
    };

    users.groups.hermes.gid = cfg.agent.uid;

    environment.etc."hermes/hindsight.json".source = memoryClientConfig;

    systemd.tmpfiles.rules = [
      "d ${cfg.agent.statePath} 0750 hermes hermes -"
      "d ${cfg.agent.servicePath} 0750 hermes hermes -"

      # The trajectory files contain conversational content. Restricted
      # permissions, and no exporter towards a shared backend.
      "d ${cfg.observability.instrumentation.trajectoryPath} 0700 hermes hermes -"
      "d ${cfg.observability.instrumentation.eventsPath} 0750 hermes hermes -"

      # Their retention is declared, so it has to be applied by something. The
      # metric and log backends prune themselves; these are plain files on the
      # guest, and nothing else would ever remove them. A declared regime that
      # no process enforces is the same as no regime, except that it reads
      # like one.
      "e ${cfg.observability.instrumentation.trajectoryPath} 0700 hermes hermes ${cfg.observability.retention.trajectory}"
      "e ${cfg.observability.instrumentation.eventsPath} 0750 hermes hermes ${toString cfg.observability.retention.observability}d"
    ];

    # ---------------------------------------------------- interactive plane
    containers.hermes-core = {
      autoStart = true;
      privateNetwork = true;
      hostAddress = cfg.network.containerHostAddress;
      localAddress = cfg.network.containerInteractiveAddress;

      # The API server listens on the container network, which no other guest
      # can reach. This is what carries the proxy's request the last hop, from
      # the guest address the ingress connects to into the container. Without
      # it the firewall rule admitting the port and the proxy target both
      # point at an address on which nothing is listening.
      forwardPorts = [{
        containerPort = cfg.agent.api.port;
        hostPort = cfg.agent.api.port;
        protocol = "tcp";
      }];

      bindMounts = {
        "${runtime}" = { hostPath = runtime; isReadOnly = true; };
        "/var/lib/hermes" = { hostPath = cfg.agent.statePath; isReadOnly = false; };
        "/etc/hermes" = { hostPath = "/etc/hermes"; isReadOnly = true; };
      };

      config = { ... }: {
        system.stateVersion = cfg.nix.stateVersion;

        systemd.services.hermes-api = {
          description = "Hermes API server — interactive plane";
          wantedBy = [ "multi-user.target" ];

          environment = commonEnvironment // {
            HERMES_HOME = "/var/lib/hermes";

            HERMES_API_BIND = "${cfg.agent.api.bindAddress}:${toString cfg.agent.api.port}";
            HERMES_API_MAX_CONCURRENT = toString cfg.agent.api.maxConcurrent;
            HERMES_API_PROFILE_PREFIX = cfg.agent.api.profilePrefix;
            HERMES_API_KEYS_FILE = "${runtime}/profile-bearers.json";

            HERMES_MAX_ITERATIONS = toString cfg.agent.maxIterations;

            HINDSIGHT_MODE = "local_external";
            HINDSIGHT_API_URL = memoryUrl;
            HINDSIGHT_CONFIG = "/etc/hermes/hindsight.json";

            HERMES_SKILLS_TAP = lib.optionalString
              (cfg.agent.skillsTapRepository != null)
              cfg.agent.skillsTapRepository;

            HERMES_NEMO_RELAY_PLUGINS_TOML = "/etc/hermes/plugins-interactive.toml";
            OTEL_RESOURCE_ATTRIBUTES = "service.name=hermes-core,plane=interactive";
          };

          serviceConfig = hardening // {
            ExecStart = "${hermesEnv}/bin/hermes serve";

            # Secrets arrive from a file, never as literal values in the Nix
            # store, which is readable by every user of the system.
            EnvironmentFile = [ "${runtime}/hermes-core.env" ];

            User = "hermes";
            Group = "hermes";
            DynamicUser = false;
            Restart = "always";
            RestartSec = "5s";
            ReadWritePaths = [ "/var/lib/hermes" ];
          };
        };
      };
    };

    # -------------------------------------------------- programmatic plane
    # Built from the same flake, with service profiles, toolsets declared by
    # inclusion and persistent memory disabled by default. Nothing listens
    # here: the runtime is invoked by the timers, and no firewall rule exposes
    # this container.
    containers.hermes-svc = {
      autoStart = true;
      privateNetwork = true;
      hostAddress = cfg.network.containerHostAddress;
      localAddress = cfg.network.containerProgrammaticAddress;

      bindMounts = {
        "${runtime}" = { hostPath = runtime; isReadOnly = true; };
        "/var/lib/hermes-svc" = { hostPath = cfg.agent.servicePath; isReadOnly = false; };
        "/etc/hermes" = { hostPath = "/etc/hermes"; isReadOnly = true; };
      };

      config = { ... }: {
        system.stateVersion = cfg.nix.stateVersion;

        # Minimal surface: no service listens, and nothing beyond the runtime
        # itself is installed.
        environment.systemPackages = [ ];
      };
    };
  };
}
