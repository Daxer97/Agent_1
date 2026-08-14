# Trace backend and evaluation platform.
#
# This component receives the spans of the agentic execution, keeps them
# queryable, hosts the versioned evaluation datasets and runs the experiments
# that measure semantic recall. It holds conversational content by
# construction, and therefore inherits the regime of the trajectory files:
# data zone, restricted permissions, retention of its own, access mediated by
# the identity provider, and no export towards a shared backend.
#
# Three properties are expressed in the unit rather than in prose, because
# prose does not survive an out-of-memory event:
#
#   * memory guardrails, because the secret store lives on the same guest and
#     is blocking at boot — losing observability costs less than losing the
#     vault;
#   * native authentication disabled, because the platform has one identity
#     provider;
#   * restricted permissions on the state directory, because of what it holds.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  eval = cfg.observability.evaluation;
  runtime = cfg.secretStore.runtimeSecretsPath;
in
{
  config = lib.mkIf (builtins.elem "observability" cfg.rolesHosted) {
    users.users.phoenix = {
      isSystemUser = true;
      group = "phoenix";
      home = eval.workingDirectory;
    };

    users.groups.phoenix = { };

    # On the volume dedicated to observability data: separate from the root
    # filesystem of the guest and from the audit trail of the secret store.
    systemd.tmpfiles.rules = [
      "d ${eval.workingDirectory} 0700 phoenix phoenix -"
    ];

    systemd.services.phoenix = {
      description = "Trace backend and evaluation platform";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "bao-agent-eval.service" ];
      requires = [ "bao-agent-eval.service" ];
      wants = [ "network-online.target" ];

      environment = {
        PHOENIX_HOST = eval.bindAddress;
        PHOENIX_PORT = toString eval.port;

        # Deliberately not the conventional receiving port: the collector
        # already holds it on this host.
        PHOENIX_GRPC_PORT = toString eval.grpcPort;

        PHOENIX_WORKING_DIR = eval.workingDirectory;
        PHOENIX_SQL_DATABASE_URL = eval.databaseUrl;
        PHOENIX_ENABLE_AUTH = lib.boolToString eval.enableNativeAuth;
        PHOENIX_DEFAULT_RETENTION_POLICY_DAYS = toString eval.retentionDays;
        PHOENIX_PROJECT_NAME = eval.projectName;
        PHOENIX_LOGGING_LEVEL = cfg.observability.logLevel;

        # The experiment side of the platform. Without these the judge runs on
        # whatever the platform defaults to, at whatever temperature, over
        # whatever set happens to be loaded — and a judge weaker than the
        # model being judged measures the judge, while a non-deterministic one
        # does not detect drift but imitates it.
        #
        # The evaluators reach the gateway through the broker, never directly:
        # the base address below is the broker's, and the credential is the
        # evaluation token rendered into phoenix.env, which carries no access
        # to the inference paths.
        HERMES_EVAL_MODEL = cfg.models.evaluation;
        HERMES_EVAL_TEMPERATURE = toString eval.temperature;
        HERMES_EVAL_CONCURRENCY = toString eval.concurrency;
        HERMES_EVAL_DATASET = eval.dataset;
        HERMES_EVAL_EVALUATORS = lib.concatStringsSep "," eval.evaluators;
        OPENAI_BASE_URL = "http://${cfg.broker.host}:${toString cfg.broker.port}/v1";
      };

      serviceConfig = {
        User = "phoenix";
        Group = "phoenix";
        WorkingDirectory = eval.workingDirectory;
        EnvironmentFile = "${runtime}/phoenix.env";
        ExecStart = "${pkgs.arize-phoenix}/bin/phoenix serve";
        Restart = "on-failure";
        RestartSec = "10s";

        # These do not add memory. They decide which process is reclaimed
        # first when the guest runs out of it.
        MemoryAccounting = true;
        MemoryHigh = eval.memoryHigh;
        MemoryMax = eval.memoryMax;

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ eval.workingDirectory ];
      };
    };

    # The symmetric guardrail on the service that is blocking at boot. Without
    # it the memory ceiling above protects the wrong process.
    systemd.services.openbao.serviceConfig = lib.mkIf
      (builtins.elem "secrets" cfg.rolesHosted)
      {
        MemoryAccounting = true;
        MemoryMin = eval.secretStoreMemoryMin;
      };
  };
}
