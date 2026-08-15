# HERMES-AGENT — parameter schema
#
# Every configurable value of the platform is declared here, once, with a type
# and a description. Modules read these options; they never contain a literal
# site value. The distinction that governs the presence of a default is the
# following:
#
#   * A parameter that encodes an architectural decision carries a default.
#     Changing it is a design change, and the default records what was decided.
#
#   * A parameter that encodes a fact about a specific installation — an
#     address, a storage identifier, a public key, a fully qualified domain
#     name — carries no default. An undefined one is reported by name at
#     evaluation time, which is preferable to a plausible value that is wrong.
#
# The mapping between these options and the placeholders of the deployment
# variable matrix is given in README.md.

{ config, lib, ... }:

let
  inherit (lib) mkOption types;

  cfg = config.hermes;

  ipv4 = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
  cidr = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])";

  # systemd-style duration, and the bare "0" that disables a window.
  duration = types.strMatching "[0-9]+(ms|s|m|h|d)?";

  # Gateway model identifier. Explicit slugs only: gateway presets are not
  # declarable in the NixOS module and would move part of the configuration
  # outside the deterministic build (HLD DEC-04).
  modelSlug = types.strMatching "[a-z0-9._-]+/[a-zA-Z0-9._:-]+";

  # Container images are referenced by digest, never by tag. The type enforces
  # what the design requires: a tag is a moving reference and defeats the
  # reproducibility target.
  imageRef = types.strMatching ".+@sha256:[0-9a-f]{64}";

  zoneModule = types.submodule {
    options = {
      vlanId = mkOption {
        type = types.ints.between 1 4094;
        description = "802.1Q VLAN identifier carrying this zone.";
      };
      cidr = mkOption {
        type = cidr;
        description = "Address range assigned to this zone.";
      };
      gateway = mkOption {
        type = ipv4;
        description = ''
          Router interface serving this zone. Routing between zones is
          performed by the device upstream, so this address is the only way
          out of the zone: without it a guest has a route to its own range and
          to nothing else — not to the secret store, not to the resolver, and
          not back to the management range it is administered from.
        '';
      };
    };
  };

  interfaceModule = types.submodule {
    options = {
      zone = mkOption {
        type = types.enum [ "edge" "app" "data" ];
        description = "Network zone this interface is attached to.";
      };
      address = mkOption {
        type = ipv4;
        description = "Address of this interface, inside the zone range.";
      };
    };
  };

  extraDiskModule = types.submodule {
    options = {
      sizeGb = mkOption {
        type = types.ints.positive;
        description = "Size of the additional volume, in gibibytes.";
      };
      storage = mkOption {
        type = types.str;
        description = "Proxmox storage identifier backing the volume.";
      };
      mountPoint = mkOption {
        type = types.path;
        description = ''
          Absolute path the volume is mounted on inside the guest. Keeping
          observability data on a filesystem of its own is what prevents a
          full disk from taking down the secret store, which is blocking at
          boot.
        '';
      };
    };
  };

  guestModule = types.submodule ({ name, ... }: {
    options = {
      hostName = mkOption {
        type = types.str;
        description = "Host name of the guest, and the name of its NixOS configuration.";
      };

      vmid = mkOption {
        type = types.ints.between 100 999999999;
        description = "Proxmox VMID. Must be free on the node before provisioning.";
      };

      cores = mkOption {
        type = types.ints.positive;
        description = ''
          Virtual CPUs. Proxmox refuses to start a guest whose virtual CPU
          count exceeds the number of physical cores of the node.
        '';
      };

      memoryMb = mkOption {
        type = types.ints.positive;
        description = "Fixed memory assignment, in mebibytes. Ballooning is disabled.";
      };

      diskGb = mkOption {
        type = types.ints.positive;
        description = "Size of the root volume, in gibibytes.";
      };

      storage = mkOption {
        type = types.str;
        description = "Proxmox storage identifier backing the root volume.";
      };

      diskFormat = mkOption {
        type = types.enum [ "raw" "qcow2" ];
        default = "raw";
        description = ''
          Image format of the root volume. On a directory-backed pool the
          format must be qcow2: with raw the per-phase snapshots are not
          available and the installation procedure loses its rollback points.
        '';
      };

      extraDisks = mkOption {
        type = types.listOf extraDiskModule;
        default = [ ];
        description = "Additional volumes attached to the guest.";
      };

      zone = mkOption {
        type = types.enum [ "edge" "app" "data" ];
        description = "Primary network zone of the guest.";
      };

      address = mkOption {
        type = ipv4;
        description = "Address of the primary interface.";
      };

      extraInterfaces = mkOption {
        type = types.listOf interfaceModule;
        default = [ ];
        description = ''
          Additional interfaces. Only the ingress guest is dual-homed: the
          flows towards the downstream services are admitted exclusively from
          its application-zone interface, never from the edge one.
        '';
      };

      bootOrder = mkOption {
        type = types.ints.between 1 5;
        description = ''
          Start order on the node. The order is binding rather than
          conventional: a service started before the secret store does not
          find its credentials and fails in a way that is not always evident.
        '';
      };

      bootDelay = mkOption {
        type = types.ints.positive;
        default = 30;
        description = "Delay in seconds before the next guest in the start order is released.";
      };

      cpuLimit = mkOption {
        type = types.nullOr types.float;
        default = null;
        description = ''
          Fraction of node CPU the guest may consume, where 1.0 is a full
          core. Set on the agentic guest so that a delegation fan-out cannot
          saturate the node.
        '';
      };

      aliasOf = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Role hosting this one. A guest with an alias is not created: its
          components are deployed on the guest it points at, while the role
          stays addressable in the configuration that already references it.
          The agentic guest is never a valid alias target — it is the only
          host running model-generated code, and its separation is the
          premise of the whole containment model.
        '';
      };
    };

    config.hostName = lib.mkDefault name;
  });
in
{
  options.hermes = {

    parametersReviewed = mkOption {
      type = types.bool;
      description = ''
        Acknowledgement that every parameter below has been reviewed against
        the site it describes. The template ships with this set to false and
        with values that are well formed but not real, so that a template
        copied and left unedited cannot reach a deployment: types alone cannot
        distinguish a plausible address from the right one, and this flag is
        the only place where somebody states that they checked.
      '';
    };

    # ------------------------------------------------------------------ role
    role = mkOption {
      type = types.enum [ "ingress" "agent" "memory" "secrets" "observability" ];
      description = "Role this guest plays in the topology. Set by the flake, not by hand.";
    };

    rolesHosted = mkOption {
      type = types.listOf types.str;
      internal = true;
      description = ''
        Roles whose components this guest actually hosts: its own role plus
        every role aliased onto it. Modules gate their configuration on this
        list so that consolidation stays a parameter rather than a fork of the
        configuration.
      '';
    };

    guests = mkOption {
      type = types.attrsOf guestModule;
      description = "Inventory of the guests, keyed by role.";
    };

    # --------------------------------------------------------------- site
    site = {
      storage = {
        default = mkOption {
          type = types.str;
          description = "Storage identifier used by guests with no dedicated pool.";
        };

        memory = mkOption {
          type = types.str;
          description = ''
            Storage identifier of the pool dedicated to the memory guest. It
            must be a physically separate device: a vector index on slow
            storage produces a retrieval failure that is attributed to the
            memory backend rather than to the disk.
          '';
        };

        fsyncMinimum = mkOption {
          type = types.ints.positive;
          default = 200;
          description = "Lowest acceptable fsync rate, in operations per second, on the pool hosting the vector index.";
        };
      };

      backupTarget = mkOption {
        type = types.str;
        description = "Storage identifier receiving guest-level backups.";
      };

      backupMountPoint = mkOption {
        type = types.path;
        description = "Path the backup storage is mounted on, on the node.";
      };

      numa = mkOption {
        type = types.bool;
        default = false;
        description = "Expose a NUMA topology to the guests. Enable only on a node with more than one NUMA node.";
      };
    };

    # ------------------------------------------------------------- network
    network = {
      timeZone = mkOption {
        type = types.str;
        description = "Time zone of the guests.";
      };

      nameservers = mkOption {
        type = types.listOf ipv4;
        description = "Resolvers configured on the guests.";
      };

      ntpServers = mkOption {
        type = types.listOf types.str;
        description = "Time sources. Correlated telemetry across guests depends on them.";
      };

      bridge = mkOption {
        type = types.str;
        description = "VLAN-aware Proxmox bridge the guest interfaces are attached to.";
      };

      managementCidr = mkOption {
        type = cidr;
        description = "Only range from which administrative access is accepted.";
      };

      zones = {
        edge = mkOption { type = zoneModule; description = "User-facing zone. Terminates TLS and nothing else."; };
        app = mkOption { type = zoneModule; description = "Application zone. Hosts the agentic plane and the egress broker."; };
        data = mkOption { type = zoneModule; description = "Data zone. Not routable from the user network."; };
      };

      perimeterFirewall = mkOption {
        type = types.str;
        description = ''
          Device applying the perimeter policy, and therefore the point where
          the outbound restriction to the inference gateway by name is
          enforced. Recorded because the guest-level rules cannot express it.
        '';
      };

      egressPolicy = mkOption {
        type = types.enum [ "direct" "proxy" ];
        default = "direct";
        description = "Whether outbound traffic reaches the inference gateway directly or through a proxy.";
      };

      containerHostAddress = mkOption {
        type = ipv4;
        description = "Host side of the private network shared with the agentic containers.";
      };

      containerInteractiveAddress = mkOption {
        type = ipv4;
        description = "Address of the interactive-plane container.";
      };

      containerProgrammaticAddress = mkOption {
        type = ipv4;
        description = "Address of the programmatic-plane container.";
      };
    };

    # ----------------------------------------------------------------- nix
    nix = {
      stateVersion = mkOption {
        type = types.str;
        description = "NixOS state version of the guests. Never raised as part of an unrelated change.";
      };

      substituters = mkOption {
        type = types.listOf types.str;
        description = "Binary caches consulted during a rebuild.";
      };

      buildHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Host performing the builds. The agentic guest runs untrusted code
          and has no need of a build toolchain: with outbound traffic denied
          by default, building elsewhere and pushing the closures is both the
          simpler and the more consistent option.
        '';
      };

      provisioningMethod = mkOption {
        type = types.enum [ "iso" "nixos-anywhere" "template-clone" ];
        default = "nixos-anywhere";
        description = "Method used to perform the first installation of a guest.";
      };

      rootDevice = mkOption {
        type = types.str;
        default = "/dev/sda";
        description = ''
          Block device carrying the root volume inside the guest. It is not a
          free choice: the provisioning script attaches the root volume as
          scsi0 on a virtio-scsi controller, which the guest enumerates as the
          first SCSI disk, and the additional volumes follow it as sdb, sdc
          and so on. Changing the attachment in pve-provision.nix without
          changing this leaves the installer partitioning the wrong disk.
        '';
      };

      sopsAgeKeyPath = mkOption {
        type = types.path;
        default = "/etc/ssh/ssh_host_ed25519_key";
        description = ''
          Private key from which the age identity of the guest is derived.
          Deriving it from the host key means there is no additional key to
          distribute.
        '';
      };
    };

    # -------------------------------------------------------------- secrets
    secretStore = {
      address = mkOption {
        type = ipv4;
        description = "Address of the secret store, as reached by the other guests.";
      };

      port = mkOption {
        type = types.port;
        default = 8200;
        description = "API port of the secret store. Always TLS, including on the internal network.";
      };

      clusterPort = mkOption {
        type = types.port;
        default = 8201;
        description = "Cluster port of the secret store.";
      };

      mount = mkOption {
        type = types.str;
        description = "Mount point of the key-value engine holding the operational secrets.";
      };

      unsealMethod = mkOption {
        type = types.enum [ "shamir-manual" "auto-unseal" ];
        default = "shamir-manual";
        description = ''
          How the store is unsealed after a restart. With the manual method a
          guest reboot requires human intervention: a legitimate choice, and
          one worth knowing in advance rather than discovering during an
          incident.
        '';
      };

      keyShares = mkOption {
        type = types.ints.positive;
        default = 3;
        description = "Number of unseal key shares produced at initialisation.";
      };

      keyThreshold = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Shares required to unseal.";
      };

      auditPath = mkOption {
        type = types.path;
        description = ''
          Directory holding the audit device. Every access, granted or
          denied, is recorded there: it is the documentary evidence that the
          separation of policies is enforced and not merely declared.
        '';
      };

      tokenTtl = mkOption { type = duration; default = "1h"; description = "Lifetime of a token issued to a machine identity."; };
      tokenMaxTtl = mkOption { type = duration; default = "24h"; description = "Upper bound on token renewal."; };
      renderInterval = mkOption { type = duration; default = "5m"; description = "Interval at which the agent re-renders static secrets."; };
      cacheTtl = mkOption { type = duration; default = "30m"; description = "How long a guest survives a sealed secret store using its local cache."; };
      retries = mkOption { type = types.ints.positive; default = 3; description = "Connection attempts made by the agent before giving up on a render cycle."; };

      runtimeSecretsPath = mkOption {
        type = types.path;
        default = "/run/secrets";
        description = ''
          Directory the rendered environment files are written to. It is a
          tmpfs: decrypted values never reach the disk nor the Nix store.
        '';
      };
    };

    # --------------------------------------------------------------- broker
    broker = {
      listenAddress = mkOption {
        type = ipv4;
        description = "Address the egress broker binds to.";
      };

      host = mkOption {
        type = ipv4;
        description = "Address of the broker as seen by its clients.";
      };

      port = mkOption {
        type = types.port;
        default = 8081;
        description = "Port of the broker.";
      };

      upstream = mkOption {
        type = types.str;
        default = "https://openrouter.ai/api/v1";
        description = "Base address of the inference gateway. The only component allowed to reach it.";
      };

      uid = mkOption {
        type = types.ints.positive;
        description = ''
          System user identifier of the broker. The outbound rules
          distinguish processes by user rather than by host, because the
          broker and the agentic containers live on the same guest: a rule
          written against the guest address would admit both and turn the
          restriction into a convention.
        '';
      };

      maxConnections = mkOption {
        type = types.ints.positive;
        default = 32;
        description = "Upper bound on concurrent connections towards the gateway.";
      };

      reserveInteractive = mkOption {
        type = types.numbers.between 0.0 1.0;
        description = ''
          Fraction of the connection budget reserved for the interactive
          plane. Together with the scheduler-level cap on batch workloads it
          is what keeps an unattended job from degrading interactive latency.
        '';
      };

      budgetSoft = mkOption {
        type = types.numbers.nonnegative;
        description = "Spend threshold, per plane and profile, that raises an alert.";
      };

      budgetHard = mkOption {
        type = types.numbers.nonnegative;
        description = ''
          Spend threshold, per plane and profile, that rejects further
          requests. Enforcement lags by one request: the excess is detected on
          the call after the one that caused it, because the real cost is read
          back from the gateway rather than estimated locally.
        '';
      };

      budgetWindowSeconds = mkOption {
        type = types.ints.positive;
        default = 86400;
        description = "Length of the rolling window over which spend is accumulated.";
      };

      timeout = mkOption { type = duration; default = "600s"; description = "Upper bound on a single request towards the gateway."; };
      replicas = mkOption { type = types.ints.positive; default = 1; description = "Local instances of the broker. A single instance is a single point of failure for both planes."; };
    };

    # --------------------------------------------------------------- memory
    memory = {
      postgres = {
        image = mkOption { type = imageRef; description = "Digest-pinned image of the store providing the vector extension."; };
        user = mkOption { type = types.str; description = "Database role used by the memory backend."; };
        database = mkOption { type = types.str; description = "Database holding the knowledge store."; };
        schema = mkOption { type = types.str; description = "Schema holding the knowledge store. Never the default schema."; };
        dataPath = mkOption { type = types.path; description = "Path of the persistent volume."; };
        uid = mkOption { type = types.ints.positive; description = "Owner of the persistent volume."; };
        vectorExtension = mkOption {
          type = types.str;
          description = "Extension providing the vector index and the approximate nearest-neighbour search.";
        };
      };

      hindsight = {
        image = mkOption { type = imageRef; description = "Digest-pinned image of the memory backend."; };
        apiPort = mkOption { type = types.port; default = 8888; description = "Port serving retain, recall and reflect."; };
        controlPlanePort = mkOption { type = types.port; default = 9999; description = "Port serving the memory inspection console."; };
        tenant = mkOption { type = types.str; description = "Tenant the banks belong to."; };
        workerId = mkOption {
          type = types.str;
          description = ''
            Stable identity of the worker. Without it the worker adopts the
            container host name, which changes at every restart: an operation
            in flight stays parked under the previous identifier and nothing
            claims it again.
          '';
        };

        bankTemplate = mkOption {
          type = types.str;
          default = "hermes-{profile}";
          description = ''
            Template deriving a memory bank from a profile. This template is
            the tenancy boundary. The backend key authenticates but does not
            authorise, so a mistake here — or a profile resolving to the empty
            string — collapses several users onto one bank with no visible
            error.
          '';
        };

        recallBudget = mkOption { type = types.enum [ "low" "mid" "high" ]; description = "Retrieval effort spent before each turn."; };
        recallMaxTokens = mkOption { type = types.ints.positive; description = "Upper bound on the context injected by a recall."; };
        retainEveryNTurns = mkOption { type = types.ints.positive; default = 1; description = "Turn interval between two retain operations."; };
        retainMaxConcurrent = mkOption { type = types.ints.positive; description = "Concurrent extraction operations."; };
        llmMaxConcurrent = mkOption { type = types.ints.positive; description = "Concurrent inference calls issued by the memory backend."; };
        llmRetries = mkOption { type = types.ints.positive; default = 3; description = "Retries on a failed extraction call."; };
        llmTimeout = mkOption { type = types.ints.positive; default = 120; description = "Timeout of an extraction call, in seconds."; };
        textLanguage = mkOption { type = types.str; description = "Dictionary used by the full-text retrieval channel."; };
        strictSchema = mkOption { type = types.bool; default = false; description = "Reject facts that do not match the declared schema."; };

        reranker = mkOption {
          type = types.str;
          default = "rrf";
          description = ''
            Fusion strategy over the four retrieval channels. The rank-based
            strategy is algorithmic: it keeps a CPU-bound model off the recall
            path on guests without an accelerator, at no cost in latency.
          '';
        };

        memoryMode = mkOption { type = types.enum [ "off" "hybrid" ]; default = "hybrid"; description = "Memory mode of the interactive profiles."; };
      };

      embedding = {
        provider = mkOption { type = types.enum [ "local" "remote" ]; default = "local"; description = "Where embeddings are computed. Local keeps the content inside the perimeter."; };

        model = mkOption {
          type = types.str;
          description = ''
            Embedding model. The choice is irreversible after the first
            retain: changing it later is not a decision but a migration with a
            full re-embedding. It must be validated against the language of
            the corpus before anything is written.
          '';
        };

        dimensions = mkOption {
          type = types.ints.positive;
          description = "Dimensionality of the vectors. Irreversible together with the model.";
        };

        candidates = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Models compared during the validation that precedes the freeze.";
        };
      };

      retention = {
        session = mkOption { type = duration; description = "Retention of the session level of the memory model."; };
        semantic = mkOption { type = duration; description = "Retention of the semantic level of the memory model."; };
      };

      tlsInternal = mkOption {
        type = types.bool;
        default = true;
        description = "Require TLS on the application-to-data path.";
      };
    };

    # ---------------------------------------------------------------- agent
    agent = {
      sourceRevision = mkOption {
        type = types.str;
        description = ''
          Pinned revision of the agent runtime, taken from the fork this
          project versions. Never a moving reference: the reproducibility
          target is measured against the resolved lock file, and a moving
          reference makes that measurement meaningless.
        '';
      };

      uid = mkOption {
        type = types.ints.positive;
        description = "System user identifier of the agent runtime, matched by the outbound rules.";
      };

      statePath = mkOption { type = types.path; description = "Persistent volume of the interactive plane."; };
      servicePath = mkOption { type = types.path; description = "Persistent volume of the programmatic plane."; };

      api = {
        bindAddress = mkOption {
          type = ipv4;
          description = ''
            Address the API server binds to, inside the interactive container.
            It is the container's own address on the guest-local network:
            never the wildcard, and never loopback either — loopback inside a
            container with a private network is reachable from nothing, and
            the proxy lives on another guest.
          '';
        };
        port = mkOption { type = types.port; default = 8000; description = "Port of the API server."; };
        profilePrefix = mkOption {
          type = types.str;
          description = "Path prefix under which a profile is served. Resolved at the ingress, never taken from the request body.";
        };
        maxConcurrent = mkOption { type = types.ints.positive; description = "Concurrent runs admitted on the interactive plane."; };
      };

      profilePrefixUser = mkOption { type = types.str; description = "Prefix of user profile names."; };
      profilePrefixService = mkOption { type = types.str; default = "svc"; description = "Prefix of service profile names."; };

      maxSpawnDepth = mkOption {
        type = types.ints.between 0 2;
        default = 2;
        description = ''
          Levels of delegation admitted below the root agent, counted as spawn
          levels rather than as nodes of the delegation tree. Two levels are
          the ratified value.
        '';
      };

      maxConcurrentChildren = mkOption { type = types.ints.positive; description = "Subordinates a single agent may run at once."; };
      maxIterations = mkOption { type = types.ints.positive; description = "Iteration cap of an interactive run."; };

      skillsTapRepository = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Additional skill registry. Null means the catalogue is limited to the sources built into the runtime.";
      };

      timeouts = {
        inference = mkOption { type = duration; default = "300s"; description = "Upper bound on a call from the agent to the broker."; };
        recall = mkOption { type = duration; default = "2s"; description = "Upper bound on a recall. Exceeding it degrades the turn instead of failing it."; };
      };

      retries = {
        broker = mkOption { type = types.ints.unsigned; default = 2; description = "Retries on a failed call to the broker."; };
        memory = mkOption { type = types.ints.unsigned; default = 1; description = "Retries on a failed recall."; };
      };

      circuitBreaker = {
        brokerThreshold = mkOption { type = types.ints.positive; default = 5; description = "Consecutive failures that open the circuit towards the broker."; };
        brokerReset = mkOption { type = duration; default = "60s"; description = "Delay before the circuit towards the broker is probed again."; };
        memoryThreshold = mkOption { type = types.ints.positive; default = 3; description = "Consecutive failures that open the circuit towards the memory backend."; };
      };
    };

    # --------------------------------------------------------------- models
    models = {
      main = mkOption { type = modelSlug; description = "Model driving the agentic loop."; };
      deliberation = mkOption {
        type = modelSlug;
        default = "openrouter/fusion";
        description = ''
          Multi-model deliberation alias. Selectivity is left to the gateway's
          own gate: the outer model decides whether to invoke it, and no
          custom routing layer is introduced.
        '';
      };
      delegation = mkOption { type = modelSlug; description = "Model used by the delegation slot."; };
      auxiliaryDefault = mkOption { type = modelSlug; description = "Model backing the auxiliary slots: compression, titles, query rewriting."; };
      memoryRetain = mkOption { type = modelSlug; description = "Model extracting facts during retain."; };
      memoryReflect = mkOption { type = modelSlug; description = "Model performing cross-memory synthesis."; };
      memoryConsolidation = mkOption { type = modelSlug; description = "Model consolidating facts into observations."; };
      evaluation = mkOption { type = modelSlug; description = "Model backing the evaluators."; };

      temperatureMain = mkOption { type = types.numbers.between 0.0 2.0; description = "Sampling temperature of the main slot."; };

      reasoning = {
        main = mkOption { type = types.bool; description = "Reasoning on the main slot. Its tokens are billed as output and count towards the cost target."; };
        mainEffort = mkOption { type = types.enum [ "low" "medium" "high" "xhigh" "max" ]; default = "low"; description = "Reasoning effort of the main slot."; };
        delegation = mkOption { type = types.bool; default = false; description = "Reasoning on the delegation slot."; };
        auxiliary = mkOption { type = types.bool; default = false; description = "Reasoning on the auxiliary slots."; };
        memory = mkOption { type = types.bool; default = false; description = "Reasoning on the memory extraction slots."; };
      };

      gateway = {
        zeroDataRetention = mkOption { type = types.bool; default = true; description = "Request the gateway's zero-retention mode."; };
        referer = mkOption { type = types.str; description = "Value reported to the gateway as the calling application address."; };
        appTitle = mkOption { type = types.str; description = "Value reported to the gateway as the calling application name."; };
        timeout = mkOption { type = duration; default = "600s"; description = "Upper bound on a gateway call."; };
        retries = mkOption { type = types.ints.unsigned; default = 3; description = "Retries on a failed gateway call."; };
      };
    };

    # ------------------------------------------------------------- identity
    identity = {
      users = mkOption {
        type = types.listOf (types.submodule {
          options = {
            identity = mkOption { type = types.str; description = "Authenticated identity, as issued by the identity provider."; };
            profile = mkOption { type = types.str; description = "Profile this identity resolves to."; };
          };
        });
        default = [ ];
        description = ''
          Explicit identity-to-profile map. An enumeration rather than a
          transformation of the identity string: an enumeration fails visibly
          on an unknown identity, whereas a normalisation can collapse two
          identities onto one profile — and therefore onto one memory bank —
          without producing any error at all.
        '';
      };

      operators = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Identities allowed to reach the memory inspection console and the evaluation console.";
      };

      groups = {
        users = mkOption { type = types.str; description = "Group granting access to the chat interface."; };
        operators = mkOption { type = types.str; description = "Group granting access to the operational consoles."; };
      };

      port = mkOption { type = types.port; default = 9091; description = "Port of the identity provider. Bound to loopback."; };
      metricsPort = mkOption { type = types.port; default = 9959; description = "Port exposing the identity provider metrics."; };
      subjectClaim = mkOption { type = types.enum [ "email" "username" ]; default = "email"; description = "Claim carrying the identity used for profile resolution."; };

      session = {
        expiration = mkOption { type = duration; description = "Absolute lifetime of a session."; };
        inactivity = mkOption { type = duration; description = "Idle time after which a session is closed."; };
        rememberMe = mkOption { type = duration; default = "0"; description = "Lifetime of a persistent session. Zero disables the feature."; };
      };

      regulation = {
        maxRetries = mkOption { type = types.ints.positive; default = 3; description = "Failed attempts before an identity is banned."; };
        findTime = mkOption { type = duration; default = "2m"; description = "Window over which failed attempts are counted."; };
        banTime = mkOption { type = duration; default = "15m"; description = "Duration of the ban."; };
      };

      logLevel = mkOption { type = types.enum [ "trace" "debug" "info" "warn" "error" ]; default = "info"; description = "Log level of the identity provider."; };
    };

    # -------------------------------------------------------------- ingress
    ingress = {
      publicFqdn = mkOption { type = types.str; description = "Name under which the chat interface is published."; };
      controlPlaneFqdn = mkOption { type = types.str; description = "Name under which the memory inspection console is published."; };
      cookieDomain = mkOption { type = types.str; description = "Parent domain the session cookie is issued for."; };

      tls = {
        source = mkOption { type = types.enum [ "acme" "internal-ca" "manual" ]; description = "Origin of the certificate material."; };
        certificate = mkOption { type = types.path; description = "Path of the certificate chain."; };
        key = mkOption { type = types.path; description = "Path of the private key."; };
        minimumVersion = mkOption { type = types.enum [ "TLSv1.2" "TLSv1.3" ]; default = "TLSv1.3"; description = "Lowest protocol version accepted."; };
      };

      corsAllowedOrigins = mkOption {
        type = types.str;
        description = "Explicit origin allow-list. A wildcard is never a valid value here.";
      };

      rateLimit = {
        auth = mkOption { type = types.str; default = "10r/m"; description = "Request rate admitted on the authentication routes."; };
        burst = mkOption { type = types.ints.positive; default = 5; description = "Burst tolerated above the authentication rate."; };
      };

      timeouts = {
        clientConnect = mkOption { type = duration; default = "10s"; description = "Upper bound on establishing a client connection."; };
        clientRead = mkOption { type = duration; default = "600s"; description = "Upper bound on a client read. Long enough to carry a streamed answer."; };
        proxyConnect = mkOption { type = duration; default = "10s"; description = "Upper bound on establishing an upstream connection."; };
        proxyRead = mkOption { type = duration; default = "600s"; description = "Upper bound on an upstream read."; };
      };

      webui = {
        image = mkOption { type = imageRef; description = "Digest-pinned image of the chat interface."; };
        port = mkOption { type = types.port; default = 8080; description = "Loopback port of the chat interface. It is never published."; };
        dataPath = mkOption { type = types.path; description = "Persistent volume of the chat interface."; };
      };

      identityMapPath = mkOption {
        type = types.path;
        default = "/etc/hermes/identity-map.conf";
        description = ''
          File holding the identity-to-profile map consumed by the proxy. It
          is generated from the same declaration that provisions the profiles,
          so the ingress and the runtime cannot drift apart.
        '';
      };
    };

    # --------------------------------------------------------- programmatic
    programmatic = {
      workloads = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            schedule = mkOption { type = types.str; description = "Calendar expression triggering the workload."; };
            jitter = mkOption { type = duration; default = "5m"; description = "Randomised delay applied to the trigger."; };
            timeout = mkOption { type = duration; description = "Upper bound on a single run."; };
            outputPath = mkOption { type = types.path; description = "Directory the produced artefact is written to."; };

            toolsets = mkOption {
              type = types.listOf types.str;
              description = ''
                Toolsets granted to the workload, declared by inclusion. A
                list of exclusions only protects against the capabilities
                somebody thought of excluding.
              '';
            };

            maxIterations = mkOption {
              type = types.ints.positive;
              description = ''
                Iteration cap. In an unattended job this is a spending cap
                before it is a correctness cap, and it is declared
                explicitly for that reason.
              '';
            };

            memoryMode = mkOption {
              type = types.enum [ "off" "hybrid" ];
              default = "off";
              description = ''
                Persistent memory of the workload. Disabled by default;
                enabled only when state must survive between runs, and then
                on a service bank disjoint from every user bank.
              '';
            };
          };
        });
        default = { };
        description = "Unattended workloads of the programmatic plane, keyed by name.";
      };

      maxConcurrentWorkloads = mkOption { type = types.ints.positive; default = 1; description = "Workloads admitted to run at the same time."; };
      cpuWeight = mkOption { type = types.ints.positive; default = 50; description = "Relative CPU weight of the batch slice."; };
      memoryHigh = mkOption { type = types.str; description = "Soft memory ceiling of the batch slice."; };
    };

    # -------------------------------------------------------- observability
    observability = {
      collectorGrpcPort = mkOption { type = types.port; default = 4317; description = "Port receiving telemetry over gRPC."; };
      collectorHttpPort = mkOption { type = types.port; default = 4318; description = "Port receiving telemetry over HTTP."; };
      collectorConfigPath = mkOption { type = types.path; default = "/etc/otel/collector.yaml"; description = "Path of the rendered collector configuration."; };

      metricsPort = mkOption { type = types.port; default = 9090; description = "Port of the metrics backend."; };
      logsPort = mkOption { type = types.port; default = 3100; description = "Port of the log backend."; };
      dashboardPort = mkOption { type = types.port; default = 3000; description = "Port of the dashboard interface."; };

      address = mkOption { type = ipv4; description = "Address telemetry is sent to. Kept as a parameter of its own so that consolidating the role does not rewrite every producer."; };
      dataPath = mkOption { type = types.path; description = "Mount point of the volume holding observability state."; };

      scrapeInterval = mkOption { type = duration; default = "15s"; description = "Interval between two metric collections."; };
      logLevel = mkOption { type = types.enum [ "debug" "info" "warn" "error" ]; default = "info"; description = "Log level of the platform services. A debug level left on is the most frequent cause of content reaching a shared backend."; };

      retention = {
        observability = mkOption { type = types.ints.positive; description = "Retention of metrics and logs, in days."; };
        audit = mkOption { type = duration; description = "Retention of the audit trail. Always longer than the observability retention."; };
        trajectory = mkOption { type = duration; description = "Retention of the trajectory files."; };
      };

      instrumentation = {
        revision = mkOption {
          type = types.str;
          description = ''
            Pinned revision of the instrumentation layer. It must expose the
            declared trace semantics: a revision predating them passes the
            deployment phase and invalidates the cost measurement, which is
            the failure mode hardest to notice.
          '';
        };
        eventsPath = mkOption { type = types.path; description = "Directory holding the event stream. Metrics and identifiers only, never content."; };
        trajectoryPath = mkOption { type = types.path; description = "Directory holding the trajectory files. Contains content: restricted permissions, no exporter towards a shared backend."; };
        traceSemantics = mkOption { type = types.str; default = "openinference"; description = "Trace semantics declared by the instrumentation, and expected by the trace backend."; };
        hideInputs = mkOption { type = types.bool; default = false; description = "Suppress prompt attributes at the instrumentation. Suppressing them removes the evaluators' input."; };
        hideOutputs = mkOption { type = types.bool; default = false; description = "Suppress completion attributes at the instrumentation."; };
      };

      evaluation = {
        image = mkOption {
          type = imageRef;
          description = ''
            Digest-pinned image of the evaluation platform. It is carried as
            an image because there is no package for it to be built from: the
            platform is absent from nixpkgs, so the choice is this or vendoring
            its dependency tree into this repository.

            Resolve the digest of the tag you intend to run before setting it,
            on the node:

                skopeo inspect docker://arizephoenix/phoenix:<tag> \
                  | jq -r .Digest
          '';
        };

        bindAddress = mkOption {
          type = ipv4;
          description = "Address the evaluation platform binds to. Neither the wildcard address nor loopback: it is reached through the proxy.";
        };
        port = mkOption { type = types.port; default = 6006; description = "Port serving the evaluation console and telemetry over HTTP."; };
        grpcPort = mkOption {
          type = types.port;
          description = ''
            Port receiving telemetry over gRPC. It is deliberately not the
            conventional one: the collector already holds that port on the
            same host, and restoring the conventional value produces a
            conflict rather than a tidier configuration.
          '';
        };
        fqdn = mkOption { type = types.str; description = "Name under which the evaluation console is published."; };
        workingDirectory = mkOption { type = types.path; description = "State directory. Restricted permissions: it holds conversational content."; };
        databaseUrl = mkOption { type = types.str; description = "Connection string of the evaluation platform store."; };
        projectName = mkOption { type = types.str; description = "Project the traces are filed under."; };
        retentionDays = mkOption {
          type = types.ints.positive;
          description = ''
            Retention of the evaluation platform. Aligned with the trajectory
            retention rather than with the observability one: it is an
            artefact that contains content, and it inherits that regime.
          '';
        };
        enableNativeAuth = mkOption {
          type = types.bool;
          default = false;
          description = "Use the evaluation platform's own authentication. Disabled: the platform has a single identity provider.";
        };
        memoryHigh = mkOption { type = types.str; description = "Soft memory ceiling. It does not add memory; it decides which process is reclaimed first when the guest runs out."; };
        memoryMax = mkOption { type = types.str; description = "Hard memory ceiling of the evaluation platform."; };
        secretStoreMemoryMin = mkOption {
          type = types.str;
          description = ''
            Memory floor guaranteed to the secret store on the consolidated
            guest. The secret store is blocking at boot; losing it costs more
            than losing observability.
          '';
        };
        dataset = mkOption { type = types.str; description = "Name of the versioned evaluation dataset backing the retrieval target."; };
        evaluators = mkOption { type = types.listOf types.str; description = "Evaluators executed by an experiment."; };
        temperature = mkOption {
          type = types.numbers.between 0.0 2.0;
          default = 0.0;
          description = ''
            Sampling temperature of the evaluators. Zero is required: a
            non-deterministic evaluation does not detect drift, it imitates
            it, and produces a series that looks informative and is not.
          '';
        };
        concurrency = mkOption { type = types.ints.positive; description = "Concurrent evaluator calls, bounded by the capacity the interactive plane does not reserve."; };
      };

      alerts = {
        window = mkOption { type = duration; default = "5m"; description = "Evaluation window of the platform rules."; };
        memoryWindow = mkOption { type = duration; default = "15m"; description = "Evaluation window of the memory rules, longer because the signal is slower."; };
        latencyP95 = mkOption { type = duration; description = "Interactive latency at the ninety-fifth percentile above which an alert is raised."; };
        recallP95 = mkOption { type = duration; description = "Recall latency at the ninety-fifth percentile above which an alert is raised."; };
        recallCoverageMin = mkOption {
          type = types.numbers.between 0.0 1.0;
          description = ''
            Lowest admitted share of turns served with memory context. Recall
            degradation is silent by construction: the turn proceeds without
            context and no error reaches the user.
          '';
        };
        retainQueue = mkOption { type = types.ints.positive; description = "Depth of the extraction queue above which an alert is raised."; };
        costDaily = mkOption { type = types.numbers.positive; description = "Daily spend, across all attributable channels, above which an alert is raised."; };
        errorRate = mkOption { type = types.numbers.positive; description = "Errors per minute above which an alert is raised."; };
        workloadDuration = mkOption { type = duration; description = "Duration of an unattended run above which an alert is raised."; };
        workloadFailures = mkOption { type = types.numbers.positive; description = "Failed unattended runs, over the alert window, above which an alert is raised."; };
        deliberationRatioMax = mkOption {
          type = types.numbers.between 0.0 1.0;
          default = 0.10;
          description = "Share of turns triggering deliberation above which an alert is raised.";
        };
      };
    };

    # --------------------------------------------------------------- backup
    backup = {
      stagingPath = mkOption {
        type = types.path;
        description = ''
          Path, local to the guest holding the data, that copies are written
          to before collection. The copy command runs in the guest that owns
          the data; collection towards the backup target is the node's
          responsibility. No data-zone guest mounts the backup storage: doing
          so would open a flow from the data zone to the management segment
          that the segmentation does not have.
        '';
      };

      ageRecipient = mkOption {
        type = types.str;
        description = ''
          Public key encrypting the copies at rest. Distinct from the key
          protecting the secret bootstrap, and held outside the node: copies
          inherit the regime of the original, and a copy in the clear takes
          content out of that regime without violating the letter of any
          declaration.
        '';
      };

      encryption = mkOption {
        type = types.enum [ "none" "at-rest" "in-transit" "both" ];
        default = "at-rest";
        description = "Protection applied to the copies.";
      };

      schedules = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Calendar expressions of the backup jobs, keyed by artefact.";
      };

      restoreTestFrequency = mkOption {
        type = duration;
        description = "Interval between two restore exercises. An unverified backup is not a backup.";
      };

      nfs = {
        server = mkOption { type = types.nullOr types.str; default = null; description = "Appliance exporting the backup storage."; };
        exportPath = mkOption { type = types.nullOr types.str; default = null; description = "Exported path mounted by the node."; };
        mountOptions = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Mount options of the backup storage. A soft mount turns a network
            timeout into a truncated backup that exits successfully, which is
            discovered only at restore time; a hard mount fails visibly
            instead.
          '';
        };
      };
    };

    # ------------------------------------------------------------ objectives
    objectives = {
      latencyP95 = mkOption { type = duration; description = "Target interactive latency at the ninety-fifth percentile."; };
      latencyDeliberationP95 = mkOption { type = duration; description = "Target latency at the ninety-fifth percentile for a turn that deliberates."; };
      turnsPerMinute = mkOption { type = types.ints.positive; description = "Throughput the platform is expected to sustain."; };
      degradeMax = mkOption { type = types.numbers.between 0.0 1.0; description = "Highest admitted degradation under load before the ceiling is considered reached."; };
      soakDuration = mkOption { type = duration; description = "Duration of the endurance run."; };
      bankSize = mkOption { type = types.ints.positive; description = "Size of the memory bank used by the representative sample."; };
      sampleWindow = mkOption { type = duration; description = "Window over which the acceptance measurements are read."; };

      crossPlaneDelta = mkOption {
        type = types.numbers.between 0.0 1.0;
        description = ''
          Highest admitted increase of interactive latency while the
          programmatic plane is under load. The four structural isolation
          checks can all pass while this one fails, and that case is a
          violation of the isolation objective in fact even though its formal
          checks are satisfied.
        '';
      };

      recoveryPointObjective = mkOption { type = duration; description = "Highest admitted data loss after a recovery."; };
      recoveryTimeObjective = mkOption { type = duration; description = "Highest admitted time to restore the service."; };
      meanTimeToRecovery = mkOption { type = duration; description = "Target repair time for a platform component."; };
      meanTimeToRecoveryEvaluation = mkOption {
        type = duration;
        description = "Target repair time for the evaluation platform, off the hot path and therefore longer.";
      };
      rotationPeriod = mkOption { type = duration; description = "Default rotation period of the operational secrets."; };
    };
  };

  config = {
    # The backup parameters are a declaration and not yet a mechanism: the
    # schedules, the encryption recipient, the mount options and the restore
    # interval are read by nothing, and only the staging path reaches a unit.
    # Said at build time because the failure is silent by construction — a
    # recovery point objective is not violated when the copies stop, it is
    # violated when somebody needs one, and the parameters read as though the
    # jobs existed.
    warnings = lib.optional (cfg.backup.schedules != { }) ''
      hermes.backup.schedules declares ${toString (lib.length (lib.attrNames cfg.backup.schedules))}
      jobs that no module turns into timers, and hermes.backup.encryption,
      ageRecipient, restoreTestFrequency and nfs.* are read by nothing. Until
      they are, hermes.objectives.recoveryPointObjective
      (${cfg.objectives.recoveryPointObjective}) rests on copies that are not
      being taken.
    '';

    hermes.rolesHosted =
      [ cfg.role ]
      ++ (lib.filter
        (role: (cfg.guests.${role}.aliasOf or null) == cfg.role)
        (builtins.attrNames cfg.guests));

    assertions = [
      {
        assertion = cfg.parametersReviewed;
        message = ''
          hermes.parametersReviewed is false. The parameters still carry
          template values. Review parameters.nix against the deployment
          variable tables in README.md, then set the flag to true.
        '';
      }
      {
        assertion = !(lib.any
          (role: (cfg.guests.${role}.aliasOf or null) == "agent")
          (builtins.attrNames cfg.guests));
        message = ''
          The agentic guest cannot host another role. It is the only host on
          which model-generated code runs, and its separation is the premise
          of the containment model: consolidating anything onto it removes the
          boundary that every other control assumes.
        '';
      }
      {
        assertion = (cfg.guests.secrets.aliasOf or null) == null;
        message = ''
          The secret store must own its guest. Aliasing it onto another role
          places a service that is blocking at boot in the same failure domain
          as services that are not.
        '';
      }
      {
        assertion = cfg.observability.evaluation.grpcPort != cfg.observability.collectorGrpcPort;
        message = ''
          The evaluation platform and the collector cannot share a receiving
          port on a consolidated guest. The conventional value belongs to the
          collector; restoring it on the evaluation platform produces a bind
          failure, not a tidier configuration.
        '';
      }
      {
        assertion = cfg.broker.budgetSoft <= cfg.broker.budgetHard;
        message = ''
          The alerting spend threshold must not exceed the blocking one,
          otherwise the hard cap is reached before anybody is warned and the
          first signal of an overrun is a rejected request.
        '';
      }
      {
        assertion = cfg.ingress.corsAllowedOrigins != "*";
        message = "The origin allow-list must enumerate the admitted origins. A wildcard is not an allow-list.";
      }
      {
        assertion = lib.hasInfix "." cfg.ingress.cookieDomain;
        message = ''
          hermes.ingress.cookieDomain is a single label. A cookie domain
          without a period is refused by the identity provider at startup and
          discarded by every browser, because an unknown single label is
          treated as a public suffix. The session would not be shared between
          the published name and the operator consoles, which is the whole
          reason the parameter exists.
        '';
      }
      {
        assertion = lib.all
          (name: name == cfg.ingress.cookieDomain
            || lib.hasSuffix ".${cfg.ingress.cookieDomain}" name)
          [
            cfg.ingress.publicFqdn
            cfg.ingress.controlPlaneFqdn
            cfg.observability.evaluation.fqdn
          ];
        message = ''
          Every published name must sit under hermes.ingress.cookieDomain.
          A name outside it is not sent the session cookie: the forward-auth
          exchange answers with a redirect that bounces off the portal, and
          the failure surfaces at the last phase — downstream of an ingress
          stack that has already been validated.
        '';
      }
      {
        assertion = cfg.agent.api.bindAddress == cfg.network.containerInteractiveAddress;
        message = ''
          hermes.agent.api.bindAddress must be the address of the interactive
          container. The API server runs inside a guest-local container with a
          private network: bound to loopback it is reachable from nothing, and
          bound to the wildcard it is reachable from more than the proxy. The
          guest forwards its own port to this address, and the firewall admits
          that port from the ingress application interface alone.
        '';
      }
    ];
  };
}
