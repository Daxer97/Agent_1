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

{ config, lib, ... }:

let
  cfg = config.hermes;
  eval = cfg.observability.evaluation;
  runtime = cfg.secretStore.runtimeSecretsPath;
in
{
  config = lib.mkIf (builtins.elem "observability" cfg.rolesHosted) {
    # Delivered as a digest-pinned image, like every other third-party service
    # on this platform — the store providing the vector index, the memory
    # backend and the chat interface are all carried the same way. It is not
    # in nixpkgs: there is no arize-phoenix attribute to build against, in
    # this release or any other, so the alternative would have been to package
    # a large dependency tree here and carry it.
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
      autoPrune.enable = true;
    };

    virtualisation.oci-containers.backend = "podman";

    # On the volume dedicated to observability data: separate from the root
    # filesystem of the guest and from the audit trail of the secret store.
    # Root-owned and unreadable by anyone else, as the chat interface's volume
    # is on the ingress guest: the container writes as the identity its image
    # declares, and the directory is not shared with a guest-side account.
    systemd.tmpfiles.rules = [
      "d ${eval.workingDirectory} 0700 root root -"
    ];

    virtualisation.oci-containers.containers.phoenix = {
      image = eval.image;
      autoStart = true;

      # Published on the address the platform declares, and on that address
      # only. The wildcard below is the container's own namespace, not the
      # guest's: what is reachable on the guest is this mapping, so the
      # binding is narrower than the unit it replaces rather than wider.
      ports = [
        "${eval.bindAddress}:${toString eval.port}:${toString eval.port}"
        "${eval.bindAddress}:${toString eval.grpcPort}:${toString eval.grpcPort}"
      ];

      volumes = [ "${eval.workingDirectory}:${eval.workingDirectory}" ];

      environment = {
        # Inside the container's network namespace. The guest-side address is
        # decided by the port mapping above.
        PHOENIX_HOST = "0.0.0.0";
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

      environmentFiles = [ "${runtime}/phoenix.env" ];
    };

    # The container reads secrets rendered by the store agent. Without the
    # ordering it starts, fails to find the environment file, and restarts
    # until it appears — which works, and hides a real ordering defect.
    #
    # The memory guardrails stay on the unit rather than moving to the
    # container runtime: the container's processes live in this unit's cgroup,
    # so the ceiling still applies to them, and it stays expressed in the same
    # place as the floor granted to the secret store below. They do not add
    # memory. They decide which process is reclaimed first when the guest runs
    # out of it.
    systemd.services.podman-phoenix = {
      after = [ "bao-agent-eval.service" ];
      requires = [ "bao-agent-eval.service" ];

      serviceConfig = {
        MemoryAccounting = true;
        MemoryHigh = eval.memoryHigh;
        MemoryMax = eval.memoryMax;
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
