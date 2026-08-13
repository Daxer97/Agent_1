# HERMES-AGENT — site parameters (template)
#
#   cp parameters.example.nix parameters.nix
#
# Then fill it in and version it alongside the flake. This file is the only
# place where a value describing a specific installation is written: the
# modules read the options declared in modules/options.nix and never contain a
# literal value of their own.
#
# The values below are well formed but not real. Addresses use the ranges
# reserved for documentation, digests are zero-filled, and every free-form
# string carries a PLACEHOLDER_ marker that `nix flake check` refuses to build.
# What the type system cannot catch — a plausible address that is not the
# right one — is caught by hermes.parametersReviewed, which stays false until
# somebody states that they checked.
#
# Each entry is documented in README.md, together with the placeholder of the
# deployment variable matrix it corresponds to.

{
  hermes = {
    # Set to true once every value below has been reviewed against the node
    # inventory and the variable matrix. Until then the configuration refuses
    # to evaluate.
    parametersReviewed = false;

    # ======================================================================
    # Node and storage
    # ======================================================================
    site = {
      storage = {
        default = "PLACEHOLDER_PVE_STORAGE_ID";

        # A physically separate device. The vector index and the relational
        # pool live here, and putting them on the same spindle as everything
        # else produces a retrieval failure that gets blamed on the memory
        # backend.
        memory = "PLACEHOLDER_PVE_STORAGE_ID_MEM";

        fsyncMinimum = 200;
      };

      backupTarget = "PLACEHOLDER_BACKUP_TARGET";
      backupMountPoint = "/mnt/pve/PLACEHOLDER_BACKUP_TARGET";

      # Enable only on a node with more than one NUMA node.
      numa = false;
    };

    # ======================================================================
    # Network
    # ======================================================================
    network = {
      timeZone = "PLACEHOLDER_TIMEZONE";
      nameservers = [ "198.18.0.1" ];
      ntpServers = [ "198.18.0.1" ];

      bridge = "PLACEHOLDER_PVE_BRIDGE";
      managementCidr = "198.18.0.0/24";

      zones = {
        edge = { vlanId = 100; cidr = "192.0.2.0/24"; };
        app = { vlanId = 101; cidr = "198.51.100.0/24"; };
        data = { vlanId = 102; cidr = "203.0.113.0/24"; };
      };

      # The perimeter device applying the outbound policy. Restricting the
      # destination to the inference gateway by name happens there: the
      # guest-level rules can only distinguish the process, not the name.
      perimeterFirewall = "PLACEHOLDER_PERIMETER_FW";
      egressPolicy = "direct";

      # Private network shared with the two agentic containers. Local to the
      # agentic guest; no other guest sees it.
      containerHostAddress = "10.111.0.1";
      containerInteractiveAddress = "10.111.0.2";
      containerProgrammaticAddress = "10.111.0.3";
    };

    # ======================================================================
    # Guests
    #
    # The start order is binding: secrets, memory, agentic plane, ingress. A
    # service started before the secret store does not find its credentials.
    # ======================================================================
    guests = {
      secrets = {
        hostName = "PLACEHOLDER_VM04_NAME";
        vmid = 104;
        cores = 2;
        memoryMb = 2048;
        diskGb = 24;
        storage = "PLACEHOLDER_PVE_STORAGE_ID";
        zone = "data";
        address = "203.0.113.14";
        bootOrder = 1;

        # Second volume holding the observability state, on a filesystem
        # separate from the root of this guest and from the audit trail. When
        # it fills up what is lost is observability; without it, what is lost
        # is the vault, which is blocking at boot.
        extraDisks = [{
          sizeGb = 32;
          storage = "PLACEHOLDER_PVE_STORAGE_ID";
          mountPoint = "/var/lib/observability";
        }];
      };

      memory = {
        hostName = "PLACEHOLDER_VM03_NAME";
        vmid = 103;
        cores = 4;
        memoryMb = 4096;
        diskGb = 40;
        storage = "PLACEHOLDER_PVE_STORAGE_ID_MEM";

        # Mandatory on a directory-backed pool: with the raw format the
        # per-phase snapshots are unavailable and the installation procedure
        # loses its rollback points.
        diskFormat = "qcow2";

        zone = "data";
        address = "203.0.113.13";
        bootOrder = 2;
      };

      agent = {
        hostName = "PLACEHOLDER_VM02_NAME";
        vmid = 102;
        cores = 4;
        memoryMb = 4096;
        diskGb = 32;
        storage = "PLACEHOLDER_PVE_STORAGE_ID";
        zone = "app";
        address = "198.51.100.12";
        bootOrder = 3;

        # Keeps a delegation fan-out from saturating the node.
        cpuLimit = 3.5;
      };

      ingress = {
        hostName = "PLACEHOLDER_VM01_NAME";
        vmid = 101;
        cores = 2;
        memoryMb = 2048;
        diskGb = 20;
        storage = "PLACEHOLDER_PVE_STORAGE_ID";
        zone = "edge";
        address = "192.0.2.11";
        bootOrder = 4;

        # The only dual-homed guest. Every flow towards a downstream service
        # is admitted from this interface alone.
        extraInterfaces = [{ zone = "app"; address = "198.51.100.11"; }];
      };

      # Observability is consolidated onto the secret store guest. Remove the
      # alias and give this entry its own sizing to separate them; the
      # configuration does not otherwise change. The one constraint that must
      # survive either choice is that the secret store never shares an
      # out-of-memory event with the observability stack.
      observability = {
        aliasOf = "secrets";
        hostName = "PLACEHOLDER_VM04_NAME";
        vmid = 104;
        cores = 2;
        memoryMb = 2048;
        diskGb = 24;
        storage = "PLACEHOLDER_PVE_STORAGE_ID";
        zone = "data";
        address = "203.0.113.14";
        bootOrder = 5;
      };
    };

    # ======================================================================
    # Build and provisioning
    # ======================================================================
    nix = {
      stateVersion = "25.05";
      substituters = [ "https://cache.nixos.org" ];

      # The agentic guest runs untrusted code and denies outbound traffic by
      # default, so it has no working build path of its own. Closures are
      # built here and pushed.
      buildHost = "PLACEHOLDER_NIX_BUILD_HOST";

      provisioningMethod = "nixos-anywhere";
      sopsAgeKeyPath = "/etc/ssh/ssh_host_ed25519_key";
    };

    # ======================================================================
    # Secret store
    # ======================================================================
    secretStore = {
      address = "203.0.113.14";
      port = 8200;
      clusterPort = 8201;
      mount = "PLACEHOLDER_BAO_MOUNT";

      # With manual unsealing a reboot of the secret store guest requires an
      # operator before any dependent service can start.
      unsealMethod = "shamir-manual";
      keyShares = 3;
      keyThreshold = 2;

      auditPath = "/var/log/openbao";

      tokenTtl = "1h";
      tokenMaxTtl = "24h";
      renderInterval = "5m";
      cacheTtl = "30m";
      retries = 3;
    };

    # ======================================================================
    # Egress broker
    # ======================================================================
    broker = {
      listenAddress = "198.51.100.12";
      host = "198.51.100.12";
      port = 8081;
      uid = 992;

      maxConnections = 32;

      # Share of the connection budget the interactive plane keeps for
      # itself, whatever the batch plane is doing.
      reserveInteractive = 0.7;

      budgetSoft = 20.0;
      budgetHard = 50.0;
      budgetWindowSeconds = 86400;

      # A single instance is a single point of failure for both planes.
      replicas = 1;
    };

    # ======================================================================
    # Memory platform
    # ======================================================================
    memory = {
      postgres = {
        image = "PLACEHOLDER_PG_IMAGE@sha256:0000000000000000000000000000000000000000000000000000000000000000";
        user = "PLACEHOLDER_PG_USER";
        database = "PLACEHOLDER_PG_DATABASE";

        # Never the default schema.
        schema = "PLACEHOLDER_PG_SCHEMA";

        dataPath = "/var/lib/postgresql/data";
        uid = 999;
        vectorExtension = "PLACEHOLDER_PG_VECTOR_EXTENSION";
      };

      hindsight = {
        image = "PLACEHOLDER_HINDSIGHT_IMAGE@sha256:0000000000000000000000000000000000000000000000000000000000000000";
        apiPort = 8888;
        controlPlanePort = 9999;
        tenant = "PLACEHOLDER_HINDSIGHT_TENANT";

        # Stable across restarts. Without it an operation in flight stays
        # parked under a worker identifier nobody claims again.
        workerId = "PLACEHOLDER_HINDSIGHT_WORKER_ID";

        bankTemplate = "hermes-{profile}";

        recallBudget = "mid";
        recallMaxTokens = 4096;
        retainEveryNTurns = 1;
        retainMaxConcurrent = 2;
        llmMaxConcurrent = 8;
        llmRetries = 3;
        llmTimeout = 120;

        textLanguage = "PLACEHOLDER_HS_TEXT_LANGUAGE";
        strictSchema = false;
        reranker = "rrf";
        memoryMode = "hybrid";
      };

      embedding = {
        provider = "local";

        # Irreversible after the first retain. Validate it against the
        # language of the corpus before anything is written: afterwards it is
        # not a decision but a migration with a full re-embedding.
        model = "PLACEHOLDER_EMBEDDING_MODEL";
        dimensions = 384;

        candidates = [
          "PLACEHOLDER_EMBEDDING_CANDIDATE_A"
          "PLACEHOLDER_EMBEDDING_CANDIDATE_B"
        ];
      };

      retention = {
        session = "30d";
        semantic = "365d";
      };

      tlsInternal = true;
    };

    # ======================================================================
    # Agent runtime
    # ======================================================================
    agent = {
      # Pinned revision of the fork this project versions. Never a moving
      # reference.
      sourceRevision = "PLACEHOLDER_HERMES_REV";

      uid = 991;
      statePath = "/var/lib/hermes";
      servicePath = "/var/lib/hermes-svc";

      api = {
        # Never the wildcard address: the proxy is the only admitted path.
        bindAddress = "127.0.0.1";
        port = 8000;
        profilePrefix = "/p";
        maxConcurrent = 4;
      };

      profilePrefixUser = "usr";
      profilePrefixService = "svc";

      maxSpawnDepth = 2;
      maxConcurrentChildren = 3;
      maxIterations = 25;

      # Null means no additional registry: the catalogue is limited to the
      # sources built into the runtime.
      skillsTapRepository = null;

      timeouts = { inference = "300s"; recall = "2s"; };
      retries = { broker = 2; memory = 1; };
      circuitBreaker = {
        brokerThreshold = 5;
        brokerReset = "60s";
        memoryThreshold = 3;
      };
    };

    # ======================================================================
    # Models
    #
    # Explicit slugs. Gateway presets are not declarable here and would move
    # part of the configuration outside the deterministic build.
    # ======================================================================
    models = {
      main = "PLACEHOLDER_VENDOR/PLACEHOLDER_MODEL_MAIN";
      deliberation = "openrouter/fusion";
      delegation = "PLACEHOLDER_VENDOR/PLACEHOLDER_MODEL_DELEGATION";
      auxiliaryDefault = "PLACEHOLDER_VENDOR/PLACEHOLDER_MODEL_AUX";
      memoryRetain = "PLACEHOLDER_VENDOR/PLACEHOLDER_MODEL_RETAIN";
      memoryReflect = "PLACEHOLDER_VENDOR/PLACEHOLDER_MODEL_REFLECT";
      memoryConsolidation = "PLACEHOLDER_VENDOR/PLACEHOLDER_MODEL_CONSOLIDATION";
      evaluation = "PLACEHOLDER_VENDOR/PLACEHOLDER_MODEL_EVAL";

      temperatureMain = 0.2;

      # Reasoning tokens are billed as output and count towards the cost
      # target. They are enabled on the main slot only.
      reasoning = {
        main = true;
        mainEffort = "low";
        delegation = false;
        auxiliary = false;
        memory = false;
      };

      gateway = {
        zeroDataRetention = true;
        referer = "https://PLACEHOLDER_PUBLIC_FQDN";
        appTitle = "PLACEHOLDER_APP_TITLE";
        timeout = "600s";
        retries = 3;
      };
    };

    # ======================================================================
    # Identity
    #
    # An explicit enumeration, never a transformation of the identity string.
    # An enumeration fails visibly on an unknown identity; a normalisation can
    # collapse two identities onto one profile — and therefore onto one memory
    # bank — without producing any error.
    # ======================================================================
    identity = {
      users = [
        { identity = "PLACEHOLDER_IDENTITY_USER_A"; profile = "usr-a"; }
        { identity = "PLACEHOLDER_IDENTITY_USER_B"; profile = "usr-b"; }
      ];

      operators = [ "PLACEHOLDER_IDENTITY_OPERATOR" ];

      groups = {
        users = "PLACEHOLDER_AUTHELIA_GROUP_USERS";
        operators = "PLACEHOLDER_AUTHELIA_GROUP_OPERATORS";
      };

      port = 9091;
      metricsPort = 9959;
      subjectClaim = "email";

      session = {
        expiration = "12h";
        inactivity = "1h";
        rememberMe = "0";
      };

      regulation = { maxRetries = 3; findTime = "2m"; banTime = "15m"; };
      logLevel = "info";

      usersFile = ./config/authelia/users.example.yml;
    };

    # ======================================================================
    # Ingress
    # ======================================================================
    ingress = {
      publicFqdn = "PLACEHOLDER_PUBLIC_FQDN";
      controlPlaneFqdn = "PLACEHOLDER_CP_FQDN";
      cookieDomain = "PLACEHOLDER_COOKIE_DOMAIN";

      tls = {
        source = "internal-ca";
        certificate = "/etc/ssl/hermes/fullchain.pem";
        key = "/etc/ssl/hermes/privkey.pem";
        minimumVersion = "TLSv1.3";
      };

      # An explicit allow-list. A wildcard is not an allow-list.
      corsAllowedOrigins = "https://PLACEHOLDER_PUBLIC_FQDN";

      rateLimit = { auth = "10r/m"; burst = 5; };

      timeouts = {
        clientConnect = "10s";
        clientRead = "600s";
        proxyConnect = "10s";
        proxyRead = "600s";
      };

      webui = {
        image = "PLACEHOLDER_OPENWEBUI_IMAGE@sha256:0000000000000000000000000000000000000000000000000000000000000000";
        port = 8080;
        dataPath = "/var/lib/open-webui";
      };
    };

    # ======================================================================
    # Programmatic plane
    # ======================================================================
    programmatic = {
      workloads = {
        PLACEHOLDER_WORKLOAD_NAME = {
          schedule = "*-*-* 02:00:00";
          jitter = "5m";
          timeout = "30m";
          outputPath = "/var/lib/hermes-svc/out";

          # Declared by inclusion. A list of exclusions only protects against
          # the capabilities somebody thought of excluding.
          toolsets = [ "execute_code" "file_read" "file_write" ];

          # In an unattended job this is a spending cap before it is a
          # correctness cap.
          maxIterations = 15;

          memoryMode = "off";
        };
      };

      maxConcurrentWorkloads = 1;
      cpuWeight = 50;
      memoryHigh = "1G";
    };

    # ======================================================================
    # Observability
    # ======================================================================
    observability = {
      collectorGrpcPort = 4317;
      collectorHttpPort = 4318;
      collectorConfigPath = "/etc/otel/collector.yaml";

      metricsPort = 9090;
      logsPort = 3100;
      dashboardPort = 3000;

      address = "203.0.113.14";
      dataPath = "/var/lib/observability";

      scrapeInterval = "15s";

      # A debug level left switched on is the most frequent cause of content
      # reaching a shared backend, and the least visible.
      logLevel = "info";

      retention = {
        observability = 7;
        audit = "90d";
        trajectory = "14d";
      };

      instrumentation = {
        # Must expose the declared trace semantics. A revision predating them
        # passes the deployment phase and drops the delegation attributes,
        # after which the cost measurement is not approximate but invalid.
        revision = "PLACEHOLDER_NEMO_RELAY_VER";

        eventsPath = "/var/log/hermes/atof";
        trajectoryPath = "/var/lib/hermes/atif";
        traceSemantics = "openinference";

        # Suppressing these removes the evaluators' input.
        hideInputs = false;
        hideOutputs = false;
      };

      evaluation = {
        # Neither the wildcard address nor loopback: reached through the proxy.
        bindAddress = "203.0.113.14";
        port = 6006;

        # Deliberately not the conventional receiving port: the collector
        # already holds that one on the same host.
        grpcPort = 4417;

        fqdn = "PLACEHOLDER_PHOENIX_FQDN";
        workingDirectory = "/var/lib/observability/phoenix";
        databaseUrl = "sqlite:////var/lib/observability/phoenix/phoenix.db";
        projectName = "PLACEHOLDER_PHOENIX_PROJECT_NAME";

        # Aligned with the trajectory retention, not with the observability
        # one: it is an artefact that contains content.
        retentionDays = 14;

        enableNativeAuth = false;

        memoryHigh = "448M";
        memoryMax = "512M";
        secretStoreMemoryMin = "192M";

        dataset = "PLACEHOLDER_EVAL_DATASET";
        evaluators = [ "relevance" "faithfulness" ];
        temperature = 0.0;
        concurrency = 2;
      };

      alerts = {
        window = "5m";
        memoryWindow = "15m";
        latencyP95 = "12s";
        recallP95 = "2s";
        recallCoverageMin = 0.90;
        retainQueue = 50;
        costDaily = 15.0;
        errorRate = 1.0;
        workloadDuration = "45m";
        workloadFailures = 2.0;
        deliberationRatioMax = 0.10;
      };
    };

    # ======================================================================
    # Backup
    # ======================================================================
    backup = {
      # Local to the guest that owns the data. Collection towards the backup
      # target is the node's responsibility: no data-zone guest mounts the
      # backup storage, because that would open a flow the segmentation does
      # not have.
      stagingPath = "/var/backups/hermes";

      # Distinct from the key protecting the secret bootstrap, and held
      # outside the node.
      ageRecipient = "PLACEHOLDER_BACKUP_AGE_RECIPIENT";

      encryption = "at-rest";

      schedules = {
        memory = "0 1 * * *";
        sessions = "15 1 * * *";
        secretStore = "30 1 * * *";
        identity = "45 1 * * *";
        evaluation = "0 3 * * *";
        guests = "0 3 * * 0";
      };

      restoreTestFrequency = "30d";

      nfs = {
        server = "PLACEHOLDER_NFS_SERVER_ADDR";
        exportPath = "PLACEHOLDER_NFS_EXPORT_PATH";

        # A soft mount turns a network timeout into a truncated backup that
        # exits successfully, and that is discovered at restore time.
        mountOptions = [
          "vers=4.2"
          "hard"
          "timeo=600"
          "retrans=2"
          "noatime"
          "nconnect=4"
        ];
      };
    };

    # ======================================================================
    # Objectives and thresholds
    # ======================================================================
    objectives = {
      latencyP95 = "8s";
      latencyDeliberationP95 = "40s";
      turnsPerMinute = 10;
      degradeMax = 0.30;
      soakDuration = "4h";
      bankSize = 5000;
      sampleWindow = "24h";

      # Requires ratification: the four structural isolation checks can all
      # pass while this one fails, and that case violates the isolation
      # objective in fact.
      crossPlaneDelta = 0.10;

      recoveryPointObjective = "24h";
      recoveryTimeObjective = "4h";
      meanTimeToRecovery = "4h";
      meanTimeToRecoveryEvaluation = "8h";
      rotationPeriod = "90d";
    };
  };
}
