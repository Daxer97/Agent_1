# Memory platform.
#
# The relational store with its vector extension, and the memory backend in
# external mode. This module replaces the compose file the design originally
# described: same variables, same behaviour, one source of truth.
#
# The phase this module belongs to carries the most expensive decision of the
# project to revisit. The embedding model and its dimensionality are frozen
# after the first retain: changing them later is not a decision, it is a
# migration with a full re-embedding.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  runtime = cfg.secretStore.runtimeSecretsPath;

  brokerUrl = "http://${cfg.broker.host}:${toString cfg.broker.port}/v1";
  address = cfg.guests.memory.address;

  network = "hermes-mem";

  # The project name and the SQL extension name are not the same string. The
  # parameter carries the project, because that is what the memory backend
  # expects in HINDSIGHT_API_VECTOR_EXTENSION; `CREATE EXTENSION` wants the
  # name the project installs its control file under. Interpolating one where
  # the other belongs fails at the first container start, inside the
  # entrypoint, with a message about a missing control file that reads as a
  # broken image rather than as a wrong parameter.
  sqlExtensionOf = {
    pgvector = "vector";
    pgvectorscale = "vectorscale";
  };

  sqlExtension = sqlExtensionOf.${cfg.memory.postgres.vectorExtension}
    or cfg.memory.postgres.vectorExtension;
in
{
  config = lib.mkIf (builtins.elem "memory" cfg.rolesHosted) {
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
      autoPrune.enable = true;
    };

    virtualisation.oci-containers.backend = "podman";

    # ------------------------------------------------------------- store
    virtualisation.oci-containers.containers.hermes-pg = {
      image = cfg.memory.postgres.image;
      autoStart = true;

      environment = {
        POSTGRES_USER = cfg.memory.postgres.user;
        POSTGRES_DB = cfg.memory.postgres.database;
        PGDATA = "${cfg.memory.postgres.dataPath}/pgdata";
      };

      environmentFiles = [ "${runtime}/pg.env" ];

      volumes = [
        "${cfg.memory.postgres.dataPath}:/var/lib/postgresql/data"
        "/etc/hermes/pg-init:/docker-entrypoint-initdb.d:ro"
      ];

      # No published port: the memory backend reaches the store over the
      # internal network, so that flow never becomes a rule in the firewall
      # matrix.
      extraOptions = [
        "--network=${network}"
        "--health-cmd=pg_isready -U ${cfg.memory.postgres.user}"
      ];
    };

    # ------------------------------------------------------------ backend
    virtualisation.oci-containers.containers.hindsight = {
      image = cfg.memory.hindsight.image;
      autoStart = true;
      dependsOn = [ "hermes-pg" ];

      ports = [
        "${address}:${toString cfg.memory.hindsight.apiPort}:8888"
        "${address}:${toString cfg.memory.hindsight.controlPlanePort}:9999"
      ];

      environment = {
        # Persistence on the external store, not on the embedded one.
        HINDSIGHT_API_DATABASE_URL =
          "postgresql://${cfg.memory.postgres.user}@hermes-pg:5432/${cfg.memory.postgres.database}";
        HINDSIGHT_API_DATABASE_SCHEMA = cfg.memory.postgres.schema;
        HINDSIGHT_API_VECTOR_EXTENSION = cfg.memory.postgres.vectorExtension;

        # A stable worker identity is mandatory. Without it the worker adopts
        # the container host name, which changes at every restart: an
        # operation in flight stays parked under the previous identifier and
        # nothing claims it again.
        HINDSIGHT_API_WORKER_ID = cfg.memory.hindsight.workerId;

        # Application authentication. It authenticates and does not
        # authorise: whoever holds the key reaches every bank, so separation
        # per profile rests on the bank identifier and on the segmentation,
        # not on the credential.
        HINDSIGHT_API_TENANT_EXTENSION =
          "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension";

        # The extraction model is routed through the broker, never directly.
        # This is the higher-volume channel of the two, and routing it here is
        # what makes the second cost channel visible at all.
        HINDSIGHT_API_LLM_PROVIDER = "openai";
        HINDSIGHT_API_LLM_BASE_URL = brokerUrl;
        HINDSIGHT_API_RETAIN_LLM_MODEL = cfg.models.memoryRetain;
        HINDSIGHT_API_REFLECT_LLM_MODEL = cfg.models.memoryReflect;
        HINDSIGHT_API_CONSOLIDATION_LLM_MODEL = cfg.models.memoryConsolidation;
        HINDSIGHT_API_RETAIN_LLM_MAX_CONCURRENT = toString cfg.memory.hindsight.retainMaxConcurrent;
        HINDSIGHT_API_LLM_MAX_CONCURRENT = toString cfg.memory.hindsight.llmMaxConcurrent;
        HINDSIGHT_API_LLM_MAX_RETRIES = toString cfg.memory.hindsight.llmRetries;
        HINDSIGHT_API_LLM_TIMEOUT = toString cfg.memory.hindsight.llmTimeout;

        # Extraction and consolidation produce structured output, not
        # deliberation. Declared rather than left unset: on the model family
        # in use reasoning is on by default when nothing says otherwise, and
        # its tokens are billed as output on the channel that runs at every
        # turn — the highest-volume one in the system.
        HINDSIGHT_API_LLM_REASONING = lib.boolToString cfg.models.reasoning.memory;

        # Embeddings stay local for data residency; the fusion strategy is
        # algorithmic, which keeps a CPU-bound model off the recall path.
        HINDSIGHT_API_EMBEDDINGS_PROVIDER = cfg.memory.embedding.provider;
        HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL = cfg.memory.embedding.model;
        HINDSIGHT_API_EMBEDDINGS_DIMENSIONS = toString cfg.memory.embedding.dimensions;
        HINDSIGHT_API_RERANKER_PROVIDER = cfg.memory.hindsight.reranker;
        HINDSIGHT_API_TEXT_SEARCH_EXTENSION = "native";
        HINDSIGHT_API_TEXT_SEARCH_EXTENSION_NATIVE_LANGUAGE = cfg.memory.hindsight.textLanguage;
        HINDSIGHT_API_STRICT_SCHEMA = lib.boolToString cfg.memory.hindsight.strictSchema;

        HINDSIGHT_CP_DATAPLANE_API_URL = "http://127.0.0.1:8888";
      };

      environmentFiles = [ "${runtime}/hindsight.env" ];
      extraOptions = [ "--network=${network}" ];
    };

    # Both containers read secrets rendered by the store agent. Without the
    # ordering they start, fail to find the environment file, and restart
    # until it appears — which works, and hides a real ordering defect.
    systemd.services.podman-hermes-pg = {
      after = [ "bao-agent-memory.service" ];
      requires = [ "bao-agent-memory.service" ];
    };

    systemd.services.podman-hindsight = {
      after = [ "bao-agent-memory.service" ];
      requires = [ "bao-agent-memory.service" ];
    };

    systemd.services."podman-network-${network}" = {
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-hermes-pg.service" "podman-hindsight.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        ${pkgs.podman}/bin/podman network exists ${network} \
          || ${pkgs.podman}/bin/podman network create ${network}
      '';
    };

    # The vector extension is created in the dedicated schema at first start.
    environment.etc."hermes/pg-init/00-extension.sql".text = ''
      CREATE SCHEMA IF NOT EXISTS ${cfg.memory.postgres.schema};
      CREATE EXTENSION IF NOT EXISTS ${sqlExtension};
    '';

    # The application-to-data path is declared as requiring TLS, and it is not
    # encrypted: the backend is reached over plain HTTP on the addresses above,
    # and the relational connection carries no sslmode. The parameter records a
    # control that is not in force, which is worse than recording its absence —
    # a reviewer reads the parameter, not the module. Stated at build time
    # until the internal certificate material exists.
    warnings = lib.optional cfg.memory.tlsInternal ''
      hermes.memory.tlsInternal is true, but the application-to-data path is
      served over plain HTTP: recall, retain and the tenant key cross the data
      zone in clear text. Either issue internal certificates for the memory
      backend and the relational store, or set the parameter to false so that
      the configuration stops asserting a control it does not apply.
    '';

    systemd.tmpfiles.rules = [
      "d ${cfg.memory.postgres.dataPath} 0700 ${toString cfg.memory.postgres.uid} ${toString cfg.memory.postgres.uid} -"
      "d ${cfg.backup.stagingPath} 0700 root root -"
    ];
  };
}
