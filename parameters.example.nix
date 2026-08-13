# HERMES-AGENT — site parameters (template)
#
#   cp parameters.example.nix parameters.nix
#
# Then fill it in and version it alongside the flake.
#
# This file is short by design. Every option already defaults to the proposed
# value of the deployment variable matrix — the sizing, the addressing, the
# thresholds and the model selection of the reference installation — so what
# belongs here is only:
#
#   1. the four values the matrix does not propose;
#   2. whatever this site changes;
#   3. the acknowledgement that the rest were checked.
#
# Keeping it to that is the point. A deviation from the reference is then
# visible in a diff, instead of being buried among two hundred values that
# were never in question.
#
# Every option, its type, its description and its default is listed in
# README.md. To see what the configuration resolves to for a given guest:
#
#   nix eval .#nixosConfigurations.<host>.config.hermes --json | jq

{
  hermes = {
    # ======================================================================
    # 1. Review acknowledgement
    #
    # The only option with no default and no proposal. The configuration
    # refuses to evaluate until it is true, because the defaults describe a
    # complete and plausible installation — the reference one, not
    # necessarily this one. Types catch a malformed address; nothing but this
    # flag catches a well-formed address belonging to another network.
    #
    # Set it once the tables in README.md have been read against the node
    # inventory.
    # ======================================================================
    parametersReviewed = false;

    # ======================================================================
    # 2. Values the matrix does not propose
    #
    # Three container digests, which are read from a registry rather than
    # chosen, and one encryption recipient, which is a security decision.
    # Leaving any of them out is reported by name at evaluation time.
    # ======================================================================

    # Digest of the store image providing the vector extension, for the
    # intended release line:
    #   skopeo inspect docker://<repository>:<tag> | jq -r .Digest
    memory.postgres.image =
      "pgvector/pgvector@sha256:PLACEHOLDER_PG_IMAGE_DIGEST";

    # Digest of the memory backend image.
    memory.hindsight.image =
      "ghcr.io/vectorize-io/hindsight@sha256:PLACEHOLDER_HINDSIGHT_IMAGE_DIGEST";

    # Digest of the chat interface image.
    ingress.webui.image =
      "ghcr.io/open-webui/open-webui@sha256:PLACEHOLDER_OPENWEBUI_IMAGE_DIGEST";

    # Public key encrypting the backup copies at rest. It must be distinct
    # from the key protecting the bootstrap credentials and held outside the
    # node: copies inherit the regime of the original, and a copy in the clear
    # takes content out of that regime without violating the letter of any
    # declaration.
    backup.ageRecipient = "PLACEHOLDER_BACKUP_AGE_RECIPIENT";

    # ======================================================================
    # 3. Site overrides
    #
    # Everything below is commented out and shows the default it would
    # replace. Uncomment only what differs on this node. The comments are the
    # short version of the reasoning; the full version is in README.md.
    # ======================================================================

    # --- Node and storage -------------------------------------------------
    #
    # The storage identifiers are the values most likely to differ, and the
    # memory pool is the one that matters: it must be a physically separate
    # device. Rename an identifier before the first guest is created — after
    # that the cost goes from one configuration line to every reference in the
    # flake and in every management command.
    #
    # site.storage.default = "local-lvm";
    # site.storage.memory = "nvme-mem";
    # site.backupTarget = "Unraid";
    #
    # Enable only on a node with more than one NUMA node.
    # site.numa = false;

    # --- Network ----------------------------------------------------------
    #
    # network.bridge = "vmbr0";
    # network.managementCidr = "192.168.1.0/24";
    # network.nameservers = [ "192.168.1.1" ];
    # network.ntpServers = [ "192.168.1.1" ];
    # network.timeZone = "Europe/Rome";
    #
    # network.zones.edge = { vlanId = 100; cidr = "10.100.0.0/24"; };
    # network.zones.app  = { vlanId = 101; cidr = "10.101.0.0/24"; };
    # network.zones.data = { vlanId = 102; cidr = "10.102.0.0/24"; };
    #
    # The device applying the perimeter policy. It is the only place able to
    # restrict outbound traffic to the inference gateway by name; where none
    # exists, that restriction is enforced nowhere and the residual risk is
    # carried knowingly.
    # network.perimeterFirewall = "none — 802.1Q router with SVI gateways only";

    # --- Guests -----------------------------------------------------------
    #
    # Each guest is a set of independent options, so overriding one field
    # keeps the defaults of every other. The start order is binding: secrets,
    # memory, agentic plane, ingress.
    #
    # guests.secrets.vmid = 204;
    # guests.secrets.address = "10.102.0.14";
    # guests.memory.vmid = 203;
    # guests.memory.address = "10.102.0.13";
    # guests.agent.vmid = 202;
    # guests.agent.address = "10.101.0.12";
    # guests.ingress.vmid = 201;
    # guests.ingress.address = "10.100.0.11";
    # guests.ingress.extraInterfaces = [{ zone = "app"; address = "10.101.0.11"; }];
    #
    # Observability is consolidated onto the secret store guest. Removing the
    # alias separates them and needs nothing else; the constraint that
    # survives either choice is that the secret store must not share an
    # out-of-memory event with the observability stack.
    # guests.observability.aliasOf = null;
    # guests.observability.vmid = 205;

    # --- Build ------------------------------------------------------------
    #
    # The agentic guest denies outbound traffic and has no working local build
    # path, so closures are built elsewhere and pushed. Set this once the
    # build host is decided.
    # nix.buildHost = "PLACEHOLDER_NIX_BUILD_HOST";

    # --- Identity and published names -------------------------------------
    #
    # ingress.publicFqdn = "hermes.proxlab";
    # ingress.controlPlaneFqdn = "memory.proxlab";
    # ingress.cookieDomain = "proxlab";
    #
    # The identity map is an enumeration, never a transformation of the
    # identity string: an enumeration fails visibly on an unknown identity,
    # while a normalisation can collapse two identities onto one profile — and
    # therefore onto one memory bank — with no error at all.
    # identity.users = [
    #   { identity = "utente.a@proxlab"; profile = "usr-alice"; }
    #   { identity = "utente.b@proxlab"; profile = "usr-bruno"; }
    # ];
    # identity.operators = [ "operator@proxlab" ];
    #
    # The default points at the template in this repository, which carries
    # placeholders instead of password hashes and is rejected by the
    # placeholder check. Point it at the real file.
    # identity.usersFile = ./config/authelia/users.yml;

    # --- Memory -----------------------------------------------------------
    #
    # The embedding model and its dimensionality are frozen after the first
    # retention: changing them later is not a decision but a migration with a
    # full re-embedding. Validate the default against the language of the
    # corpus before anything is written.
    # memory.embedding.model = "intfloat/multilingual-e5-small";
    # memory.embedding.dimensions = 384;
    # memory.hindsight.textLanguage = "italian";

    # --- Models -----------------------------------------------------------
    #
    # Explicit slugs. Gateway presets are not declarable here and would move
    # part of the configuration outside the deterministic build.
    # models.main = "anthropic/claude-sonnet-5";
    # models.delegation = "anthropic/claude-haiku-4.5";
    # models.auxiliaryDefault = "anthropic/claude-haiku-4.5";
    # models.evaluation = "anthropic/claude-sonnet-5";

    # --- Spending ---------------------------------------------------------
    #
    # The hard cap rejects, the soft one only warns. Enforcement lags by one
    # request, because the real cost is read back from the gateway rather than
    # estimated locally.
    # broker.budgetSoft = 20.0;
    # broker.budgetHard = 50.0;
    # broker.reserveInteractive = 0.7;

    # --- Programmatic workloads -------------------------------------------
    #
    # Empty by default: a workload is a job somebody asked for, not a value to
    # propose. Every parameter of one does carry its proposed default, so a
    # declaration needs no more than a name.
    #
    # programmatic.workloads.daily-digest = { };
    #
    # Or, overriding what the proposal sets:
    # programmatic.workloads.daily-digest = {
    #   schedule = "*-*-* 02:00:00";
    #   toolsets = [ "file_read" "file_write" ];
    #   maxIterations = 15;
    # };

    # --- Thresholds awaiting ratification ---------------------------------
    #
    # These three are proposals, not settled figures. The cross-plane delta is
    # the one to watch: the four structural isolation checks can all pass
    # while it fails, and that case violates the isolation objective in fact.
    # objectives.crossPlaneDelta = 0.10;
    # objectives.recoveryPointObjective = "24h";
    # objectives.recoveryTimeObjective = "4h";

    # --- Measured, not configured -----------------------------------------
    #
    # The only two results the acceptance run produces rather than consumes.
    # Record them once measured; a low measured ceiling is information, a high
    # estimated one is not.
    # objectives.maxSessionsPerGuest = null;
    # objectives.memoryFootprintPerInstance = null;
  };
}
