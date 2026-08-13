# HERMES-AGENT — parameter schema
#
# Every configurable value of the platform is declared here, once, with a type,
# a description and a default. Modules read these options; they never contain a
# literal value of their own.
#
# The defaults are the proposed values of the deployment variable matrix. They
# are a coherent starting configuration — the sizing, the addressing, the
# thresholds and the model selection of the reference installation — and not a
# set of neutral fallbacks. Two consequences follow, and both matter.
#
#   * The configuration evaluates without any parameter being supplied.
#     parameters.nix therefore holds only what a given site changes, which is
#     what makes a deviation from the reference visible in a diff instead of
#     being buried among values that were never in question.
#
#   * A plausible default is not a checked one. Types cannot distinguish a
#     well-formed address from the right address, so hermes.parametersReviewed
#     has no default and the configuration refuses to evaluate until somebody
#     states that the values were verified against the node.
#
# Four values have no default because the matrix does not propose one: the
# three container image digests, which must be read from the registry, and the
# backup encryption recipient, which is a security decision. Their absence is
# reported by name at evaluation time.
#
# README.md maps each option to the matrix placeholder it corresponds to.

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
  # outside the deterministic build.
  modelSlug = types.strMatching "[a-z0-9._-]+/[a-zA-Z0-9._:-]+";

  # Container images are referenced by digest, never by tag. The type enforces
  # what the design requires: a tag is a moving reference and defeats the
  # reproducibility target. The matrix proposes no digest — a digest is read
  # from the registry, not chosen — so these three options have no default.
  imageRef = types.strMatching ".+@sha256:[0-9a-f]{64}";

  # ---------------------------------------------------------------------------
  # Builders
  #
  # Zones, guests and their interfaces are declared as named options rather
  # than as free-form attribute sets, so that each field carries its own
  # default. The distinction is not cosmetic: with a single default on the
  # whole collection, overriding one field of one guest would discard the
  # defaults of every other field and every other guest.
  # ---------------------------------------------------------------------------

  mkZone = defaults: mkOption {
    type = types.submodule {
      options = {
        vlanId = mkOption {
          type = types.ints.between 1 4094;
          default = defaults.vlanId;
          description = "802.1Q VLAN identifier carrying this zone.";
        };
        cidr = mkOption {
          type = cidr;
          default = defaults.cidr;
          description = "Address range assigned to this zone.";
        };
      };
    };
    default = { };
    description = defaults.description;
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

  mkGuest = defaults: mkOption {
    type = types.submodule {
      options = {
        hostName = mkOption {
          type = types.str;
          default = defaults.hostName;
          description = "Host name of the guest, and the name of its NixOS configuration.";
        };

        vmid = mkOption {
          type = types.ints.between 100 999999999;
          default = defaults.vmid;
          description = "Proxmox VMID. Must be free on the node before provisioning.";
        };

        cores = mkOption {
          type = types.ints.positive;
          default = defaults.cores;
          description = ''
            Virtual CPUs. Proxmox refuses to start a guest whose virtual CPU
            count exceeds the number of physical cores of the node.
          '';
        };

        memoryMb = mkOption {
          type = types.ints.positive;
          default = defaults.memoryMb;
          description = "Fixed memory assignment, in mebibytes. Ballooning is disabled.";
        };

        diskGb = mkOption {
          type = types.ints.positive;
          default = defaults.diskGb;
          description = "Size of the root volume, in gibibytes.";
        };

        storage = mkOption {
          type = types.str;
          default = defaults.storage;
          description = "Proxmox storage identifier backing the root volume.";
        };

        diskFormat = mkOption {
          type = types.enum [ "raw" "qcow2" ];
          default = defaults.diskFormat or "raw";
          description = ''
            Image format of the root volume. On a directory-backed pool the
            format must be qcow2: with raw the per-phase snapshots are not
            available and the installation procedure loses its rollback points.
          '';
        };

        extraDisks = mkOption {
          type = types.listOf extraDiskModule;
          default = defaults.extraDisks or [ ];
          description = "Additional volumes attached to the guest.";
        };

        zone = mkOption {
          type = types.enum [ "edge" "app" "data" ];
          default = defaults.zone;
          description = "Primary network zone of the guest.";
        };

        address = mkOption {
          type = ipv4;
          default = defaults.address;
          description = "Address of the primary interface.";
        };

        extraInterfaces = mkOption {
          type = types.listOf interfaceModule;
          default = defaults.extraInterfaces or [ ];
          description = ''
            Additional interfaces. Only the ingress guest is dual-homed: the
            flows towards the downstream services are admitted exclusively from
            its application-zone interface, never from the edge one.
          '';
        };

        bootOrder = mkOption {
          type = types.ints.between 1 5;
          default = defaults.bootOrder;
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
          default = defaults.cpuLimit or null;
          description = ''
            Fraction of node CPU the guest may consume, where 1.0 is a full
            core. Set on the agentic guest so that a delegation fan-out cannot
            saturate the node.
          '';
        };

        aliasOf = mkOption {
          type = types.nullOr types.str;
          default = defaults.aliasOf or null;
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
    };

    default = { };
    description = defaults.description;
  };
in
{
  options.hermes = {

    parametersReviewed = mkOption {
      type = types.bool;
      description = ''
        Acknowledgement that the parameters have been checked against the site
        they describe. It has no default on purpose. Every other option carries
        the proposed value of the variable matrix, which means the
        configuration evaluates into a complete and plausible installation
        before anybody has confirmed that it is the right one. Types catch a
        malformed address; nothing but this flag catches a well-formed address
        belonging to a different network.
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

    # ---------------------------------------------------------------- guests
    guests = {
      secrets = mkGuest {
        description = "Secret store guest. Blocking at boot, and therefore started first.";
        hostName = "hrm-sec";
        vmid = 204;
        cores = 2;
        memoryMb = 2048;
        diskGb = 24;
        storage = "local-lvm";
        zone = "data";
        address = "10.102.0.14";
        bootOrder = 1;

        # Second volume for the observability state, on a filesystem separate
        # from the root of this guest and from the audit trail. Declared
        # allocation: metrics up to 2 GiB, logs up to 8, evaluation platform up
        # to 16, and 6 in reserve. When it fills up what is lost is
        # observability; without it, what is lost is the vault.
        extraDisks = [{
          sizeGb = 32;
          storage = "local-lvm";
          mountPoint = "/var/lib/observability";
        }];
      };

      memory = mkGuest {
        description = "Memory guest: knowledge store and vector index, on a dedicated device.";
        hostName = "hrm-mem";
        vmid = 203;
        cores = 4;
        memoryMb = 4096;
        diskGb = 40;
        storage = "nvme-mem";

        # Mandatory on a directory-backed pool: with the raw format the
        # per-phase snapshots are unavailable and the installation procedure
        # loses its rollback points.
        diskFormat = "qcow2";

        zone = "data";
        address = "10.102.0.13";
        bootOrder = 2;
      };

      agent = mkGuest {
        description = ''
          Agentic guest: the only host on which model-generated code runs. It
          is never consolidated with another role.
        '';
        hostName = "hrm-app";
        vmid = 202;
        cores = 4;
        memoryMb = 4096;
        diskGb = 32;
        storage = "local-lvm";
        zone = "app";
        address = "10.101.0.12";
        bootOrder = 3;
        cpuLimit = 3.5;
      };

      ingress = mkGuest {
        description = "Ingress guest: the trust boundary, and the only dual-homed machine.";
        hostName = "hrm-edge";
        vmid = 201;
        cores = 2;
        memoryMb = 2048;
        diskGb = 20;
        storage = "local-lvm";
        zone = "edge";
        address = "10.100.0.11";
        bootOrder = 4;
        extraInterfaces = [{ zone = "app"; address = "10.101.0.11"; }];
      };

      observability = mkGuest {
        description = ''
          Observability guest. Aliased onto the secret store guest by default:
          the node cannot fund five machines, and the roles that can share one
          are these two. Removing the alias separates them without any other
          change. The constraint that survives either choice is that the secret
          store must not share an out-of-memory event with this stack, which is
          what the memory guardrails on both services enforce.
        '';
        aliasOf = "secrets";
        hostName = "hrm-sec";
        vmid = 204;
        cores = 2;
        memoryMb = 2048;
        diskGb = 24;
        storage = "local-lvm";
        zone = "data";
        address = "10.102.0.14";
        bootOrder = 5;
      };
    };

    # ------------------------------------------------------------------ site
    site = {
      storage = {
        default = mkOption {
          type = types.str;
          default = "local-lvm";
          description = "Storage pool used by the guests that have no dedicated device.";
        };

        memory = mkOption {
          type = types.str;
          default = "nvme-mem";
          description = ''
            Storage pool dedicated to the memory guest. It must be a physically
            separate device: a vector index on slow storage produces a
            retrieval failure that gets attributed to the memory backend rather
            than to the disk. Renaming this identifier is cheap before the
            first guest is created and expensive afterwards, when it becomes a
            change to every reference in the flake and in every management
            command.
          '';
        };

        fsyncMinimum = mkOption {
          type = types.ints.positive;
          default = 200;
          description = "Lowest acceptable fsync rate on the pool hosting the vector index, in operations per second.";
        };
      };

      backupTarget = mkOption {
        type = types.str;
        default = "Unraid";
        description = "Storage receiving guest-level backups.";
      };

      backupMountPoint = mkOption {
        type = types.path;
        default = "/mnt/pve/${cfg.site.backupTarget}";
        description = ''
          Path the backup storage is mounted on, on the node. Proxmox decides
          this by convention from the storage identifier, whatever the exported
          path happens to be.
        '';
      };

      numa = mkOption {
        type = types.bool;
        default = false;
        description = "Expose a NUMA topology to the guests. Enable only on a node with more than one NUMA node.";
      };
    };

    # --------------------------------------------------------------- network
    network = {
      timeZone = mkOption {
        type = types.str;
        default = "Europe/Rome";
        description = "Time zone of the guests.";
      };

      nameservers = mkOption {
        type = types.listOf ipv4;
        default = [ "192.168.1.1" ];
        description = "Resolvers configured on the guests.";
      };

      ntpServers = mkOption {
        type = types.listOf types.str;
        default = [ "192.168.1.1" ];
        description = "Time sources. Correlating telemetry across guests depends on them.";
      };

      bridge = mkOption {
        type = types.str;
        default = "vmbr0";
        description = "VLAN-aware Proxmox bridge the guest interfaces attach to.";
      };

      managementCidr = mkOption {
        type = cidr;
        default = "192.168.1.0/24";
        description = "The only range from which administrative access is accepted.";
      };

      zones = {
        edge = mkZone {
          description = "User-facing zone. It terminates TLS and nothing else.";
          vlanId = 100;
          cidr = "10.100.0.0/24";
        };

        app = mkZone {
          description = "Application zone. Hosts the agentic plane and the egress broker.";
          vlanId = 101;
          cidr = "10.101.0.0/24";
        };

        data = mkZone {
          description = "Data zone. Not routable from the user network.";
          vlanId = 102;
          cidr = "10.102.0.0/24";
        };
      };

      perimeterFirewall = mkOption {
        type = types.str;
        default = "none — 802.1Q router with SVI gateways only";
        description = ''
          Device applying the perimeter policy, and therefore the only place
          able to restrict outbound traffic to the inference gateway by name.
          The guest-level rules can distinguish the process but not the
          destination name. Where no such device exists, that restriction is
          not enforced anywhere and the residual risk is carried knowingly.
        '';
      };

      egressPolicy = mkOption {
        type = types.enum [ "direct" "proxy" ];
        default = "direct";
        description = ''
          Whether outbound traffic reaches the inference gateway directly or
          through a proxy. Changing it to proxy extends the broker and the
          build configuration, and is a departure from the declared assumption
          that must be recorded.
        '';
      };

      containerHostAddress = mkOption {
        type = ipv4;
        default = "10.111.0.1";
        description = "Host side of the private network shared with the agentic containers.";
      };

      containerInteractiveAddress = mkOption {
        type = ipv4;
        default = "10.111.0.2";
        description = "Address of the interactive-plane container.";
      };

      containerProgrammaticAddress = mkOption {
        type = ipv4;
        default = "10.111.0.3";
        description = "Address of the programmatic-plane container.";
      };
    };

    # ------------------------------------------------------------------- nix
    nix = {
      stateVersion = mkOption {
        type = types.str;
        default = "25.05";
        description = "NixOS state version of the guests. Never raised as a side effect of an unrelated change.";
      };

      substituters = mkOption {
        type = types.listOf types.str;
        default = [ "https://cache.nixos.org" ];
        description = "Binary caches consulted during a rebuild.";
      };

      buildHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Host performing the builds, reached over SSH. The agentic guest runs
          untrusted code and denies outbound traffic by default, so it has no
          working local build path: closures are built elsewhere and pushed.
          The matrix proposes the administration workstation on the management
          range, which is a decision to record rather than a value to derive,
          so this stays unset until it is made.
        '';
      };

      provisioningMethod = mkOption {
        type = types.enum [ "iso" "nixos-anywhere" "template-clone" ];
        default = "nixos-anywhere";
        description = "Method used for the first installation of a guest.";
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

    # ---------------------------------------------------------- secret store
    secretStore = {
      address = mkOption {
        type = ipv4;
        default = cfg.guests.secrets.address;
        description = "Address of the store as reached by the other guests.";
      };

      port = mkOption {
        type = types.port;
        default = 8200;
        description = "API port. Always TLS, including on the internal network.";
      };

      clusterPort = mkOption {
        type = types.port;
        default = 8201;
        description = "Cluster port.";
      };

      mount = mkOption {
        type = types.str;
        default = "hermes";
        description = "Mount point of the key-value engine holding the operational secrets.";
      };

      unsealMethod = mkOption {
        type = types.enum [ "shamir-manual" "auto-unseal" ];
        default = "shamir-manual";
        description = ''
          How the store is unsealed after a restart. With the manual method a
          reboot of this guest requires human intervention before any dependent
          service can start: a legitimate choice, and one worth knowing in
          advance rather than discovering during an incident.
        '';
      };

      keyShares = mkOption {
        type = types.ints.positive;
        default = 3;
        description = "Unseal key shares produced at initialisation. They must not be kept on this guest.";
      };

      keyThreshold = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Shares required to unseal.";
      };

      auditPath = mkOption {
        type = types.path;
        default = "/var/log/openbao";
        description = ''
          Directory holding the audit device. Every access, granted or denied,
          is recorded there: it is the documentary evidence that the separation
          of policies is enforced and not merely declared. The matrix states
          this as a file path; the option is the directory, because the file
          name is appended when the device is enabled.
        '';
      };

      tokenTtl = mkOption { type = duration; default = "1h"; description = "Lifetime of a token issued to a machine identity."; };
      tokenMaxTtl = mkOption { type = duration; default = "24h"; description = "Upper bound on token renewal."; };
      renderInterval = mkOption { type = duration; default = "5m"; description = "Interval at which the agent re-renders static secrets."; };
      cacheTtl = mkOption { type = duration; default = "30m"; description = "How long a guest survives a sealed store on its local cache."; };
      retries = mkOption { type = types.ints.positive; default = 3; description = "Connection attempts before the agent gives up on a render cycle."; };

      runtimeSecretsPath = mkOption {
        type = types.path;
        default = "/run/secrets";
        description = ''
          Directory the rendered environment files are written to. It is a
          tmpfs: decrypted values never reach the disk nor the Nix store.
        '';
      };
    };

    # ---------------------------------------------------------------- broker
    broker = {
      listenAddress = mkOption {
        type = ipv4;
        default = cfg.guests.agent.address;
        description = "Address the egress broker binds to.";
      };

      host = mkOption {
        type = ipv4;
        default = cfg.guests.agent.address;
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
        default = 992;
        description = ''
          System user identifier of the broker. The outbound rules distinguish
          processes by user rather than by host, because the broker and the
          agentic containers live on the same guest: a rule written against the
          guest address would admit both and turn the restriction into a
          convention.
        '';
      };

      maxConnections = mkOption {
        type = types.ints.positive;
        default = 32;
        description = "Upper bound on concurrent connections towards the gateway.";
      };

      reserveInteractive = mkOption {
        type = types.numbers.between 0.0 1.0;
        default = 0.7;
        description = ''
          Fraction of the connection budget reserved for the interactive plane.
          Together with the scheduler-level cap on batch workloads it is what
          keeps an unattended job from degrading interactive latency.
        '';
      };

      budgetSoft = mkOption {
        type = types.numbers.nonnegative;
        default = 20.0;
        description = "Spend threshold, per plane and profile, that raises an alert.";
      };

      budgetHard = mkOption {
        type = types.numbers.nonnegative;
        default = 50.0;
        description = ''
          Spend threshold, per plane and profile, that rejects further
          requests. Enforcement lags by one request: the excess is detected on
          the call after the one that caused it, because the real cost is read
          back from the gateway rather than estimated locally. Irrelevant on a
          daily budget, worth knowing on a very tight one.
        '';
      };

      budgetWindowSeconds = mkOption {
        type = types.ints.positive;
        default = 86400;
        description = "Length of the rolling window over which spend accumulates.";
      };

      timeout = mkOption { type = duration; default = "600s"; description = "Upper bound on a single request towards the gateway."; };

      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Local instances of the broker. A single instance is a single point of failure for both planes.";
      };
    };

    # ---------------------------------------------------------------- memory
    memory = {
      postgres = {
        image = mkOption {
          type = imageRef;
          description = ''
            Digest-pinned image of the store providing the vector extension.
            No default: a digest is read from the registry for the intended
            release line, not proposed. The type rejects a tag.
          '';
        };

        user = mkOption { type = types.str; default = "hindsight"; description = "Database role used by the memory backend."; };
        database = mkOption { type = types.str; default = "hindsight"; description = "Database holding the knowledge store."; };
        schema = mkOption { type = types.str; default = "hindsight"; description = "Schema holding the knowledge store. Never the default schema."; };
        dataPath = mkOption { type = types.path; default = "/var/lib/postgresql/data"; description = "Path of the persistent volume."; };
        uid = mkOption { type = types.ints.positive; default = 999; description = "Owner of the persistent volume."; };

        vectorExtension = mkOption {
          type = types.str;
          default = "pgvector";
          description = "Extension providing the vector index and the approximate nearest-neighbour search.";
        };
      };

      hindsight = {
        image = mkOption {
          type = imageRef;
          description = "Digest-pinned image of the memory backend. No default, for the reason given above.";
        };

        apiPort = mkOption { type = types.port; default = 8888; description = "Port serving retention, retrieval and synthesis."; };
        controlPlanePort = mkOption { type = types.port; default = 9999; description = "Port serving the memory inspection console."; };
        tenant = mkOption { type = types.str; default = "default"; description = "Tenant the banks belong to."; };

        workerId = mkOption {
          type = types.str;
          default = "${cfg.guests.memory.hostName}-w1";
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
            string, which triggers the static fallback — collapses several
            users onto one bank with no visible error.
          '';
        };

        recallBudget = mkOption { type = types.enum [ "low" "mid" "high" ]; default = "mid"; description = "Retrieval effort spent before each turn."; };
        recallMaxTokens = mkOption { type = types.ints.positive; default = 4096; description = "Upper bound on the context injected by a retrieval."; };
        retainEveryNTurns = mkOption { type = types.ints.positive; default = 1; description = "Turn interval between two retention operations."; };
        retainMaxConcurrent = mkOption { type = types.ints.positive; default = 2; description = "Concurrent extraction operations."; };
        llmMaxConcurrent = mkOption { type = types.ints.positive; default = 8; description = "Concurrent inference calls issued by the memory backend."; };
        llmRetries = mkOption { type = types.ints.positive; default = 3; description = "Retries on a failed extraction call."; };
        llmTimeout = mkOption { type = types.ints.positive; default = 120; description = "Timeout of an extraction call, in seconds."; };

        textLanguage = mkOption {
          type = types.str;
          default = "italian";
          description = ''
            Dictionary used by the full-text retrieval channel. It must match
            the language of the corpus, and it is validated together with the
            embedding model before the freeze.
          '';
        };

        strictSchema = mkOption { type = types.bool; default = false; description = "Reject facts that do not match the declared schema."; };

        reranker = mkOption {
          type = types.str;
          default = "rrf";
          description = ''
            Fusion strategy over the four retrieval channels. The rank-based
            strategy is algorithmic: it keeps a CPU-bound model off the
            retrieval path on guests without an accelerator, at no cost.
          '';
        };

        memoryMode = mkOption { type = types.enum [ "off" "hybrid" ]; default = "hybrid"; description = "Memory mode of the interactive profiles."; };
      };

      embedding = {
        provider = mkOption { type = types.enum [ "local" "remote" ]; default = "local"; description = "Where embeddings are computed. Local keeps the content inside the perimeter."; };

        model = mkOption {
          type = types.str;
          default = "intfloat/multilingual-e5-small";
          description = ''
            Embedding model. The default is the proposed candidate and is
            explicitly pending validation: the choice is irreversible after the
            first retention, because changing it later is not a decision but a
            migration with a full re-embedding. Validate it against the
            language of the corpus before anything is written.
          '';
        };

        dimensions = mkOption {
          type = types.ints.positive;
          default = 384;
          description = "Dimensionality of the vectors. Irreversible together with the model.";
        };

        candidates = mkOption {
          type = types.listOf types.str;
          default = [
            "intfloat/multilingual-e5-small"
            "BAAI/bge-m3"
            "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
            "BAAI/bge-small-en-v1.5"
          ];
          description = ''
            Models compared during the validation that precedes the freeze. The
            last one is the baseline of the design and is trained predominantly
            on English text, which is the reason the comparison exists.
          '';
        };
      };

      retention = {
        session = mkOption { type = duration; default = "30d"; description = "Retention of the session level of the memory model."; };
        semantic = mkOption { type = duration; default = "365d"; description = "Retention of the semantic level of the memory model."; };
      };

      tlsInternal = mkOption {
        type = types.bool;
        default = true;
        description = "Require TLS on the application-to-data path.";
      };
    };

    # ----------------------------------------------------------------- agent
    agent = {
      sourceRevision = mkOption {
        type = types.str;
        default = "470cf66b";
        description = ''
          Pinned revision of the agent runtime, taken from the fork this
          project versions. Never a moving reference: the reproducibility
          target is measured against the resolved lock file, and a moving
          reference makes that measurement meaningless.
        '';
      };

      uid = mkOption {
        type = types.ints.positive;
        default = 991;
        description = "System user identifier of the agent runtime, matched by the outbound rules.";
      };

      statePath = mkOption { type = types.path; default = "/var/lib/hermes"; description = "Persistent volume of the interactive plane."; };
      servicePath = mkOption { type = types.path; default = "/var/lib/hermes-svc"; description = "Persistent volume of the programmatic plane."; };

      api = {
        bindAddress = mkOption {
          type = ipv4;
          default = "127.0.0.1";
          description = "Address the API server binds to. Never the wildcard address: the proxy is the only admitted path.";
        };

        port = mkOption { type = types.port; default = 8000; description = "Port of the API server."; };

        profilePrefix = mkOption {
          type = types.str;
          default = "/p";
          description = "Path prefix under which a profile is served. Resolved at the ingress, never taken from the request body.";
        };

        maxConcurrent = mkOption { type = types.ints.positive; default = 4; description = "Concurrent runs admitted on the interactive plane."; };
      };

      profilePrefixUser = mkOption { type = types.str; default = "usr"; description = "Prefix of user profile names."; };
      profilePrefixService = mkOption { type = types.str; default = "svc"; description = "Prefix of service profile names."; };

      maxSpawnDepth = mkOption {
        type = types.ints.between 0 2;
        default = 2;
        description = ''
          Levels of delegation admitted below the root agent, counted as spawn
          levels rather than as nodes of the delegation tree.
        '';
      };

      maxConcurrentChildren = mkOption { type = types.ints.positive; default = 3; description = "Subordinates a single agent may run at once."; };
      maxIterations = mkOption { type = types.ints.positive; default = 25; description = "Iteration cap of an interactive run."; };

      skillsTapRepository = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Additional skill registry. Null is the proposed value and means there
          is no external tap: the catalogue is the one this repository carries.
          The value here is an absence, not a missing address.
        '';
      };

      timeouts = {
        inference = mkOption { type = duration; default = "300s"; description = "Upper bound on a call from the agent to the broker."; };
        recall = mkOption { type = duration; default = "2s"; description = "Upper bound on a retrieval. Exceeding it degrades the turn instead of failing it."; };
      };

      retries = {
        broker = mkOption { type = types.ints.unsigned; default = 2; description = "Retries on a failed call to the broker."; };
        memory = mkOption { type = types.ints.unsigned; default = 1; description = "Retries on a failed retrieval."; };
      };

      circuitBreaker = {
        brokerThreshold = mkOption { type = types.ints.positive; default = 5; description = "Consecutive failures that open the circuit towards the broker."; };
        brokerReset = mkOption { type = duration; default = "60s"; description = "Delay before the circuit towards the broker is probed again."; };
        memoryThreshold = mkOption { type = types.ints.positive; default = 3; description = "Consecutive failures that open the circuit towards the memory backend."; };
      };
    };

    # ---------------------------------------------------------------- models
    models = {
      main = mkOption { type = modelSlug; default = "anthropic/claude-sonnet-5"; description = "Model driving the agentic loop."; };

      deliberation = mkOption {
        type = modelSlug;
        default = "openrouter/fusion";
        description = ''
          Multi-model deliberation alias. Selectivity is left to the gateway's
          own gate: the outer model decides whether to invoke it, and no custom
          routing layer is introduced.
        '';
      };

      delegation = mkOption { type = modelSlug; default = "anthropic/claude-haiku-4.5"; description = "Model used by the delegation slot."; };
      auxiliaryDefault = mkOption { type = modelSlug; default = "anthropic/claude-haiku-4.5"; description = "Model backing the auxiliary slots: compression, titles, query rewriting."; };
      memoryRetain = mkOption { type = modelSlug; default = "anthropic/claude-haiku-4.5"; description = "Model extracting facts during retention. Structured output must be reliable."; };
      memoryReflect = mkOption { type = modelSlug; default = "anthropic/claude-haiku-4.5"; description = "Model performing cross-memory synthesis."; };
      memoryConsolidation = mkOption { type = modelSlug; default = "anthropic/claude-haiku-4.5"; description = "Model consolidating facts into observations."; };
      evaluation = mkOption { type = modelSlug; default = "anthropic/claude-sonnet-5"; description = "Model backing the evaluators."; };

      temperatureMain = mkOption { type = types.numbers.between 0.0 2.0; default = 0.2; description = "Sampling temperature of the main slot."; };

      reasoning = {
        main = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Reasoning on the main slot. Its tokens are billed as output and
            count towards the cost target, which is why the setting is explicit
            rather than left to the model default.
          '';
        };

        mainEffort = mkOption { type = types.enum [ "low" "medium" "high" "xhigh" "max" ]; default = "low"; description = "Reasoning effort of the main slot."; };
        delegation = mkOption { type = types.bool; default = false; description = "Reasoning on the delegation slot."; };
        auxiliary = mkOption { type = types.bool; default = false; description = "Reasoning on the auxiliary slots."; };
        memory = mkOption { type = types.bool; default = false; description = "Reasoning on the memory extraction slots."; };
      };

      gateway = {
        zeroDataRetention = mkOption { type = types.bool; default = true; description = "Request the gateway's zero-retention mode."; };
        referer = mkOption { type = types.str; default = "https://${cfg.ingress.publicFqdn}"; description = "Calling application address reported to the gateway."; };
        appTitle = mkOption { type = types.str; default = "HERMES-AGENT"; description = "Calling application name reported to the gateway."; };
        timeout = mkOption { type = duration; default = "600s"; description = "Upper bound on a gateway call."; };
        retries = mkOption { type = types.ints.unsigned; default = 3; description = "Retries on a failed gateway call."; };
      };
    };

    # -------------------------------------------------------------- identity
    identity = {
      users = mkOption {
        type = types.listOf (types.submodule {
          options = {
            identity = mkOption { type = types.str; description = "Authenticated identity, as issued by the identity provider."; };
            profile = mkOption { type = types.str; description = "Profile this identity resolves to."; };
          };
        });

        default = [
          { identity = "utente.a@proxlab"; profile = "${cfg.agent.profilePrefixUser}-alice"; }
          { identity = "utente.b@proxlab"; profile = "${cfg.agent.profilePrefixUser}-bruno"; }
        ];

        description = ''
          Explicit identity-to-profile map. An enumeration rather than a
          transformation of the identity string: an enumeration fails visibly
          on an unknown identity, whereas a normalisation can collapse two
          identities onto one profile — and therefore onto one memory bank —
          without producing any error at all. Two sample users are the proposed
          population, which is what the multi-user and isolation checks need.
        '';
      };

      operators = mkOption {
        type = types.listOf types.str;
        default = [ "operator@proxlab" ];
        description = "Identities allowed to reach the memory inspection console and the evaluation console.";
      };

      groups = {
        users = mkOption { type = types.str; default = "hermes-users"; description = "Group granting access to the chat interface."; };
        operators = mkOption { type = types.str; default = "hermes-operators"; description = "Group granting access to the operational consoles."; };
      };

      port = mkOption { type = types.port; default = 9091; description = "Port of the identity provider. Bound to loopback."; };
      metricsPort = mkOption { type = types.port; default = 9959; description = "Port exposing the identity provider metrics."; };
      subjectClaim = mkOption { type = types.enum [ "email" "username" ]; default = "email"; description = "Claim carrying the identity used for profile resolution."; };

      session = {
        expiration = mkOption { type = duration; default = "12h"; description = "Absolute lifetime of a session."; };
        inactivity = mkOption { type = duration; default = "1h"; description = "Idle time after which a session is closed."; };
        rememberMe = mkOption { type = duration; default = "0"; description = "Lifetime of a persistent session. Zero disables the feature."; };
      };

      regulation = {
        maxRetries = mkOption { type = types.ints.positive; default = 3; description = "Failed attempts before an identity is banned."; };
        findTime = mkOption { type = duration; default = "2m"; description = "Window over which failed attempts are counted."; };
        banTime = mkOption { type = duration; default = "15m"; description = "Duration of the ban."; };
      };

      logLevel = mkOption { type = types.enum [ "trace" "debug" "info" "warn" "error" ]; default = "info"; description = "Log level of the identity provider."; };

      usersFile = mkOption {
        type = types.path;
        default = ../config/authelia/users.example.yml;
        description = ''
          File backend holding the user population. The default is the template
          shipped with this repository, which carries placeholders rather than
          password hashes and is therefore rejected by the placeholder check
          until it is replaced. A directory backend is the expected choice in
          service, and substituting it does not touch the access rules.
        '';
      };
    };

    # --------------------------------------------------------------- ingress
    ingress = {
      publicFqdn = mkOption { type = types.str; default = "hermes.proxlab"; description = "Name under which the chat interface is published."; };
      controlPlaneFqdn = mkOption { type = types.str; default = "memory.proxlab"; description = "Name under which the memory inspection console is published."; };
      cookieDomain = mkOption { type = types.str; default = "proxlab"; description = "Parent domain the session cookie is issued for."; };

      tls = {
        source = mkOption { type = types.enum [ "acme" "internal-ca" "manual" ]; default = "internal-ca"; description = "Origin of the certificate material."; };
        certificate = mkOption { type = types.path; default = "/etc/ssl/hermes/fullchain.pem"; description = "Path of the certificate chain."; };
        key = mkOption { type = types.path; default = "/etc/ssl/hermes/privkey.pem"; description = "Path of the private key."; };
        minimumVersion = mkOption { type = types.enum [ "TLSv1.2" "TLSv1.3" ]; default = "TLSv1.3"; description = "Lowest protocol version accepted."; };
      };

      corsAllowedOrigins = mkOption {
        type = types.str;
        default = "https://${cfg.ingress.publicFqdn}";
        description = "Explicit origin allow-list. An assertion rejects a wildcard: a wildcard is not an allow-list.";
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
        image = mkOption {
          type = imageRef;
          description = "Digest-pinned image of the chat interface. No default: a digest is read from the registry.";
        };

        port = mkOption { type = types.port; default = 8080; description = "Loopback port of the chat interface. It is never published."; };
        dataPath = mkOption { type = types.path; default = "/var/lib/open-webui"; description = "Persistent volume of the chat interface."; };
      };

      identityMapPath = mkOption {
        type = types.path;
        default = "/etc/nginx/identity-map.conf";
        description = ''
          File holding the identity-to-profile map consumed by the proxy. It is
          generated from the same declaration that provisions the profiles, so
          the ingress and the runtime cannot drift apart.
        '';
      };
    };

    # ---------------------------------------------------------- programmatic
    programmatic = {
      workloads = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            schedule = mkOption { type = types.str; default = "*-*-* 02:00:00"; description = "Calendar expression triggering the workload."; };
            jitter = mkOption { type = duration; default = "5m"; description = "Randomised delay applied to the trigger."; };
            timeout = mkOption { type = duration; default = "30m"; description = "Upper bound on a single run."; };
            outputPath = mkOption { type = types.path; default = "${cfg.agent.servicePath}/out"; description = "Directory the produced artefact is written to."; };

            toolsets = mkOption {
              type = types.listOf types.str;
              default = [ "execute_code" "file_read" "file_write" ];
              description = ''
                Toolsets granted to the workload, declared by inclusion. A list
                of exclusions only protects against the capabilities somebody
                thought of excluding.
              '';
            };

            maxIterations = mkOption {
              type = types.ints.positive;
              default = 15;
              description = ''
                Iteration cap. In an unattended job this is a spending cap
                before it is a correctness cap, and it is declared explicitly
                for that reason.
              '';
            };

            memoryMode = mkOption {
              type = types.enum [ "off" "hybrid" ];
              default = "off";
              description = ''
                Persistent memory of the workload. Disabled by default; enabled
                only when state must survive between runs, and then on a
                service bank disjoint from every user bank.
              '';
            };
          };
        });

        default = { };
        description = ''
          Unattended workloads of the programmatic plane, keyed by name. The
          inventory is empty by default because a workload is a job somebody
          asked for, not a value to propose; every parameter of a workload does
          carry the proposed default, so declaring one needs no more than its
          name.
        '';
      };

      maxConcurrentWorkloads = mkOption { type = types.ints.positive; default = 1; description = "Workloads admitted to run at the same time."; };
      cpuWeight = mkOption { type = types.ints.positive; default = 50; description = "Relative CPU weight of the batch slice."; };
      memoryHigh = mkOption { type = types.str; default = "1G"; description = "Soft memory ceiling of the batch slice."; };
    };

    # --------------------------------------------------------- observability
    observability = {
      collectorGrpcPort = mkOption { type = types.port; default = 4317; description = "Port receiving telemetry over gRPC."; };
      collectorHttpPort = mkOption { type = types.port; default = 4318; description = "Port receiving telemetry over HTTP."; };
      collectorConfigPath = mkOption { type = types.path; default = "/etc/otel/collector.yaml"; description = "Path of the rendered collector configuration."; };

      metricsPort = mkOption { type = types.port; default = 9090; description = "Port of the metrics backend."; };
      logsPort = mkOption { type = types.port; default = 3100; description = "Port of the log backend."; };
      dashboardPort = mkOption { type = types.port; default = 3000; description = "Port of the dashboard interface."; };

      address = mkOption {
        type = ipv4;
        default = cfg.guests.observability.address;
        description = ''
          Address telemetry is sent to. It is a parameter of its own, derived
          from the guest inventory, so that consolidating or separating the
          role does not rewrite every producer.
        '';
      };

      dataPath = mkOption { type = types.path; default = "/var/lib/observability"; description = "Mount point of the volume holding observability state."; };

      scrapeInterval = mkOption { type = duration; default = "15s"; description = "Interval between two metric collections."; };

      logLevel = mkOption {
        type = types.enum [ "debug" "info" "warn" "error" ];
        default = "info";
        description = ''
          Log level of the platform services. A debug level left switched on is
          the most frequent cause of conversational content reaching a shared
          backend, and the least visible.
        '';
      };

      retention = {
        observability = mkOption { type = types.ints.positive; default = 7; description = "Retention of metrics and logs, in days."; };
        audit = mkOption { type = duration; default = "90d"; description = "Retention of the audit trail. Always longer than the observability retention."; };
        trajectory = mkOption { type = duration; default = "14d"; description = "Retention of the trajectory files."; };
      };

      instrumentation = {
        revision = mkOption {
          type = types.str;
          default = "0.3";
          description = ''
            Pinned revision of the instrumentation layer. The default is a
            verifiable starting pin, not a confirmed one: the revision in use
            must expose the declared trace semantics, and one predating them
            passes the deployment phase while dropping the delegation
            attributes — after which a turn that fanned out is
            indistinguishable from a simple one and the cost measurement is not
            approximate but invalid.
          '';
        };

        eventsPath = mkOption { type = types.path; default = "/var/log/hermes/atof"; description = "Directory holding the event stream. Metrics and identifiers only, never content."; };
        trajectoryPath = mkOption { type = types.path; default = "${cfg.agent.statePath}/atif"; description = "Directory holding the trajectory files. Contains content: restricted permissions, no shared-backend exporter."; };
        traceSemantics = mkOption { type = types.str; default = "openinference"; description = "Trace semantics declared by the instrumentation, and expected by the trace backend."; };
        hideInputs = mkOption { type = types.bool; default = false; description = "Suppress prompt attributes at the instrumentation. Suppressing them removes the evaluators' input."; };
        hideOutputs = mkOption { type = types.bool; default = false; description = "Suppress completion attributes at the instrumentation."; };
      };

      evaluation = {
        bindAddress = mkOption {
          type = ipv4;
          default = cfg.guests.observability.address;
          description = "Address the evaluation platform binds to. Neither the wildcard address nor loopback: it is reached through the proxy.";
        };

        port = mkOption { type = types.port; default = 6006; description = "Port serving the evaluation console and telemetry over HTTP."; };

        grpcPort = mkOption {
          type = types.port;
          default = 4417;
          description = ''
            Port receiving telemetry over gRPC. Deliberately not the
            conventional one: the collector already holds that port on the same
            host, and restoring the conventional value produces a bind failure
            rather than a tidier configuration. An assertion rejects the
            collision.
          '';
        };

        fqdn = mkOption { type = types.str; default = "phoenix.${cfg.ingress.cookieDomain}"; description = "Name under which the evaluation console is published."; };
        workingDirectory = mkOption { type = types.path; default = "${cfg.observability.dataPath}/phoenix"; description = "State directory. Restricted permissions: it holds conversational content."; };

        databaseUrl = mkOption {
          type = types.str;
          default = "sqlite:///${cfg.observability.evaluation.workingDirectory}/phoenix.db";
          description = ''
            Connection string of the evaluation platform store. An embedded
            engine is the proposed choice: a server engine is excluded by the
            memory available on the consolidated guest. The consequence falls
            on the backup, which must copy an open database through the
            engine's own mechanism rather than by copying the file.
          '';
        };

        projectName = mkOption { type = types.str; default = "hermes"; description = "Project the traces are filed under. The plane is carried as a span attribute, not as a separate project."; };

        retentionDays = mkOption {
          type = types.ints.positive;
          default = 14;
          description = ''
            Retention of the evaluation platform. Aligned with the trajectory
            retention rather than with the observability one: it is an artefact
            that contains content, and it inherits that regime.
          '';
        };

        enableNativeAuth = mkOption {
          type = types.bool;
          default = false;
          description = "Use the evaluation platform's own authentication. Disabled: the platform has a single identity provider.";
        };

        memoryHigh = mkOption { type = types.str; default = "448M"; description = "Soft memory ceiling. It does not add memory; it decides which process is reclaimed first when the guest runs out."; };
        memoryMax = mkOption { type = types.str; default = "512M"; description = "Hard memory ceiling of the evaluation platform."; };

        secretStoreMemoryMin = mkOption {
          type = types.str;
          default = "192M";
          description = ''
            Memory floor guaranteed to the secret store on the consolidated
            guest. The secret store is blocking at boot; losing it costs more
            than losing observability.
          '';
        };

        dataset = mkOption { type = types.str; default = "obj03-recall"; description = "Name of the versioned evaluation dataset backing the retrieval target."; };
        evaluators = mkOption { type = types.listOf types.str; default = [ "relevance" "faithfulness" ]; description = "Evaluators executed by an experiment."; };

        temperature = mkOption {
          type = types.numbers.between 0.0 2.0;
          default = 0.0;
          description = ''
            Sampling temperature of the evaluators. Zero is required: a
            non-deterministic evaluation does not detect drift in the knowledge
            graph, it imitates it, and produces a series that looks informative
            and is not.
          '';
        };

        concurrency = mkOption {
          type = types.ints.positive;
          default = 2;
          description = ''
            Concurrent evaluator calls. Two is the value for a window in which
            interactive traffic is present; a dedicated window tolerates more,
            bounded by the capacity the interactive plane does not reserve.
          '';
        };
      };

      alerts = {
        window = mkOption { type = duration; default = "5m"; description = "Evaluation window of the platform rules."; };
        memoryWindow = mkOption { type = duration; default = "15m"; description = "Evaluation window of the memory rules, longer because the signal is slower."; };
        latencyP95 = mkOption { type = duration; default = "12s"; description = "Interactive latency at the ninety-fifth percentile above which an alert is raised."; };
        recallP95 = mkOption { type = duration; default = "2s"; description = "Retrieval latency at the ninety-fifth percentile above which an alert is raised."; };

        recallCoverageMin = mkOption {
          type = types.numbers.between 0.0 1.0;
          default = 0.90;
          description = ''
            Lowest admitted share of turns served with memory context.
            Retrieval degradation is silent by construction: the turn proceeds
            without context and no error reaches the user, so this rule is the
            only place it becomes visible.
          '';
        };

        retainQueue = mkOption { type = types.ints.positive; default = 50; description = "Depth of the extraction queue above which an alert is raised."; };
        costDaily = mkOption { type = types.numbers.positive; default = 15.0; description = "Daily spend, across all attributable channels, above which an alert is raised."; };
        errorRate = mkOption { type = types.numbers.positive; default = 1.0; description = "Errors per minute above which an alert is raised."; };
        workloadDuration = mkOption { type = duration; default = "45m"; description = "Duration of an unattended run above which an alert is raised."; };
        workloadFailures = mkOption { type = types.numbers.positive; default = 2.0; description = "Failed unattended runs, over the alert window, above which an alert is raised."; };
        deliberationRatioMax = mkOption { type = types.numbers.between 0.0 1.0; default = 0.10; description = "Share of turns triggering deliberation above which an alert is raised."; };
      };
    };

    # ---------------------------------------------------------------- backup
    backup = {
      stagingPath = mkOption {
        type = types.path;
        default = "/var/backups/hermes";
        description = ''
          Path, local to the guest holding the data, that copies are written to
          before collection. The copy command runs in the guest that owns the
          data; collection towards the backup target is the node's
          responsibility. No data-zone guest mounts the backup storage: doing
          so would open a flow from the data zone to the management segment
          that the segmentation does not have.
        '';
      };

      ageRecipient = mkOption {
        type = types.str;
        description = ''
          Public key encrypting the copies at rest. No default: it is a
          security decision, not a proposal. It must be distinct from the key
          protecting the secret bootstrap and held outside the node — copies
          inherit the regime of the original, and a copy in the clear takes
          content out of that regime without violating the letter of any
          declaration.
        '';
      };

      encryption = mkOption {
        type = types.enum [ "none" "at-rest" "in-transit" "both" ];
        default = "at-rest";
        description = ''
          Protection applied to the copies. At rest covers the logical dumps
          through an encryption step in the pipeline; guest-level images are
          not covered, and that gap is accepted knowingly rather than
          overlooked.
        '';
      };

      schedules = {
        memory = mkOption { type = types.str; default = "0 1 * * *"; description = "Schedule of the knowledge store dump."; };
        sessions = mkOption { type = types.str; default = "15 1 * * *"; description = "Schedule of the session store dump."; };
        secretStore = mkOption { type = types.str; default = "30 1 * * *"; description = "Schedule of the secret store snapshot."; };
        identity = mkOption { type = types.str; default = "45 1 * * *"; description = "Schedule of the identity provider backup."; };
        evaluation = mkOption { type = types.str; default = "0 3 * * *"; description = "Schedule of the evaluation platform backup."; };
        guests = mkOption { type = types.str; default = "0 3 * * 0"; description = "Schedule of the guest-level images."; };
      };

      restoreTestFrequency = mkOption {
        type = duration;
        default = "30d";
        description = "Interval between two restore exercises. An unverified backup is not a backup.";
      };

      nfs = {
        server = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Appliance exporting the backup storage. No default: the matrix
            gives the expected range rather than an address, because this is a
            value to read from the node's storage configuration and not one to
            propose. If it falls outside the management range, the backup path
            crosses a routed zone and the choice of target must be re-examined.
          '';
        };

        exportPath = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Exported path mounted by the node. Read from the same configuration as the server address.";
        };

        mountOptions = mkOption {
          type = types.listOf types.str;
          default = [ "vers=4.2" "hard" "timeo=600" "retrans=2" "noatime" "nconnect=4" ];
          description = ''
            Mount options of the backup storage. The hard mount is the only
            non-negotiable entry: a soft mount turns a network timeout into a
            truncated backup that exits successfully, and that is discovered at
            restore time. The timeout and retransmission values are the
            protocol defaults, written down rather than inherited, because a
            default nobody wrote down is not a decision. The parallel
            connection count requires a recent protocol version and must be
            removed if the server negotiates an older one — in which case the
            transport carries neither encryption nor authentication beyond the
            address, and the confidentiality of the copies rests entirely on
            the encryption applied before they leave the guest.
          '';
        };
      };
    };

    # ------------------------------------------------------------ objectives
    objectives = {
      latencyP95 = mkOption { type = duration; default = "8s"; description = "Target interactive latency at the ninety-fifth percentile."; };
      latencyDeliberationP95 = mkOption { type = duration; default = "40s"; description = "Target latency at the ninety-fifth percentile for a turn that deliberates."; };
      turnsPerMinute = mkOption { type = types.ints.positive; default = 10; description = "Throughput the platform is expected to sustain."; };
      degradeMax = mkOption { type = types.numbers.between 0.0 1.0; default = 0.30; description = "Highest admitted degradation under load before the ceiling is considered reached."; };
      soakDuration = mkOption { type = duration; default = "4h"; description = "Duration of the endurance run."; };
      bankSize = mkOption { type = types.ints.positive; default = 5000; description = "Size of the memory bank used by the representative sample."; };
      sampleWindow = mkOption { type = duration; default = "24h"; description = "Window over which the acceptance measurements are read."; };

      crossPlaneDelta = mkOption {
        type = types.numbers.between 0.0 1.0;
        default = 0.10;
        description = ''
          Highest admitted increase of interactive latency while the
          programmatic plane is under load. The default is a proposal awaiting
          ratification, not a settled threshold. The four structural isolation
          checks can all pass while this one fails, and that case is a
          violation of the isolation objective in fact even though its formal
          checks are satisfied.
        '';
      };

      recoveryPointObjective = mkOption {
        type = duration;
        default = "24h";
        description = "Highest admitted data loss after a recovery. A proposal awaiting ratification.";
      };

      recoveryTimeObjective = mkOption {
        type = duration;
        default = "4h";
        description = "Highest admitted time to restore the service. A proposal awaiting ratification.";
      };

      meanTimeToRecovery = mkOption { type = duration; default = "4h"; description = "Target repair time for a platform component."; };

      meanTimeToRecoveryEvaluation = mkOption {
        type = duration;
        default = "8h";
        description = ''
          Target repair time for the evaluation platform. Twice the general
          figure because it sits off the hot path; its ceiling is the window
          over which the acceptance measurements are read.
        '';
      };

      rotationPeriod = mkOption { type = duration; default = "90d"; description = "Default rotation period of the operational secrets."; };

      # --- Measured, not configured ---------------------------------------
      # These two are the only results the acceptance run produces rather than
      # consumes. They are recorded here once measured, and a null value means
      # the measurement has not been taken.
      maxSessionsPerGuest = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          Concurrent interactive sessions the agentic guest sustains before
          memory saturation or unacceptable degradation. Measured, never
          estimated: a low measured ceiling is information, a high estimated
          one is not.
        '';
      };

      memoryFootprintPerInstance = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Steady-state memory footprint of a single agent instance, in mebibytes. Measured alongside the ceiling above.";
      };
    };
  };

  config = {
    hermes.rolesHosted =
      [ cfg.role ]
      ++ (lib.filter
        (role: cfg.guests.${role}.aliasOf == cfg.role)
        (builtins.attrNames cfg.guests));

    assertions = [
      {
        assertion = cfg.parametersReviewed;
        message = ''
          hermes.parametersReviewed is false.

          Every parameter carries the proposed value of the deployment variable
          matrix, so the configuration describes a complete installation — the
          reference one, not necessarily yours. Check parameters.nix against
          the node inventory and the variable tables in README.md, then set the
          flag to true.
        '';
      }
      {
        assertion = !(lib.any
          (role: cfg.guests.${role}.aliasOf == "agent")
          (builtins.attrNames cfg.guests));
        message = ''
          The agentic guest cannot host another role. It is the only host on
          which model-generated code runs, and its separation is the premise of
          the containment model: consolidating anything onto it removes the
          boundary that every other control assumes.
        '';
      }
      {
        assertion = cfg.guests.secrets.aliasOf == null;
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
    ];
  };
}
