# Secret store agent.
#
# The chain has three links, and each solves a problem the previous one
# cannot. The encrypted-file layer distributes the bootstrap credential — a
# vault cannot hold the key that opens it. The secret store holds every
# operational secret, with a policy per identity and an audit device. The
# runtime directory is a tmpfs, so decrypted values never touch the disk nor
# the Nix store.
#
# This module turns a policy into an environment file: the agent authenticates
# with the bootstrap credential, renews its own token, re-renders the files on
# every rotation and reloads the consuming service. Rotating a gateway
# credential therefore requires no rebuild, which is the direct operational
# benefit of keeping that credential outside the agentic perimeter.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  hosts = cfg.rolesHosted;
  mount = cfg.secretStore.mount;
  runtime = cfg.secretStore.runtimeSecretsPath;

  userProfiles = map (u: u.profile) cfg.identity.users;
  serviceProfiles = map (name: "${cfg.agent.profilePrefixService}-${name}")
    (builtins.attrNames cfg.programmatic.workloads);
  allProfiles = userProfiles ++ serviceProfiles;

  planeOf = profile:
    if builtins.elem profile serviceProfiles then "programmatic" else "interactive";

  credentialOf = profile:
    if builtins.elem profile serviceProfiles then "programmatic" else "interactive";

  # ---------------------------------------------------------------- templates
  brokerTokenEntry = profile: ''
    {{- with secret "${mount}/data/broker/tokens/${profile}" }}
      "{{ .Data.data.value }}": {
        "plane": "${planeOf profile}",
        "profile": "${profile}",
        "purpose": "conversational",
        "credential": "${credentialOf profile}"
      }
    {{- end }}
  '';

  sharedTokenEntry = { key, plane, profile, purpose, credential }: ''
    {{- with secret "${mount}/data/broker/tokens" }}
      "{{ .Data.data.${key} }}": {
        "plane": "${plane}",
        "profile": "${profile}",
        "purpose": "${purpose}",
        "credential": "${credential}"
      }
    {{- end }}
  '';

  brokerTokensTemplate = ''
    {
    ${lib.concatStringsSep ",\n" (
      (map brokerTokenEntry allProfiles)
      ++ [
        (sharedTokenEntry {
          key = "extraction";
          plane = "interactive";
          profile = "shared";
          purpose = "memory_extraction";
          credential = "extraction";
        })
        (sharedTokenEntry {
          key = "eval";
          plane = "interactive";
          profile = "shared";
          purpose = "eval";
          credential = "interactive";
        })
      ]
    )}
    }
  '';

  brokerCredentialsTemplate = ''
    {
    {{- with secret "${mount}/data/inference/interactive" }}
      "interactive": "{{ .Data.data.key }}",
    {{- end }}
    {{- with secret "${mount}/data/inference/programmatic" }}
      "programmatic": "{{ .Data.data.key }}",
    {{- end }}
    {{- with secret "${mount}/data/inference/extraction" }}
      "extraction": "{{ .Data.data.key }}"
    {{- end }}
    }
  '';

  # The variable carrying the inference credential is named after the
  # OpenAI-compatible convention the runtime expects, but it does not hold a
  # gateway key: it holds the internal broker token. The name suggests the
  # opposite, and an operator acting in good faith may be tempted to "repair"
  # it by putting the real key back. The policy attached to this identity is
  # what protects the invariant over time — it makes the real key unreadable
  # from this guest even to somebody who wants to place it here.
  hermesCoreTemplate = ''
    {{- /* Rendered by the agent. Values exist only in tmpfs. */ -}}
    {{- with secret "${mount}/data/broker/tokens" }}
    OPENAI_API_KEY={{ .Data.data.interactive }}
    {{- end }}
    {{- with secret "${mount}/data/memory/tenant_key" }}
    HINDSIGHT_API_KEY={{ .Data.data.key }}
    {{- end }}
    {{- with secret "${mount}/data/skills/github_token" }}
    GITHUB_TOKEN={{ .Data.data.token }}
    {{- end }}
  '';

  hermesServiceTemplate = ''
    {{- with secret "${mount}/data/broker/tokens" }}
    OPENAI_API_KEY={{ .Data.data.programmatic }}
    {{- end }}
    {{- with secret "${mount}/data/memory/tenant_key" }}
    HINDSIGHT_API_KEY={{ .Data.data.key }}
    {{- end }}
  '';

  # Consumed by the API server to validate the requests the proxy routes to
  # it. Rendered as a document rather than as one variable per profile so that
  # adding a profile does not change the shape of the environment.
  profileBearersJsonTemplate = ''
    {
    ${lib.concatStringsSep ",\n" (map
      (profile: ''
        {{- with secret "${mount}/data/profiles/${profile}/bearer" }}
          "${profile}": "{{ .Data.data.value }}"
        {{- end }}
      '')
      allProfiles)}
    }
  '';

  # Consumed by the proxy as a map include: profile to bearer, one line each.
  profileBearersTemplate = lib.concatMapStringsSep "\n"
    (profile: ''
      {{- with secret "${mount}/data/profiles/${profile}/bearer" }}
      "${profile}" "{{ .Data.data.value }}";
      {{- end }}
    '')
    allProfiles;

  postgresTemplate = ''
    {{- with secret "${mount}/data/db/hindsight" }}
    POSTGRES_PASSWORD={{ .Data.data.password }}
    {{- end }}
  '';

  hindsightTemplate = ''
    {{- with secret "${mount}/data/memory/tenant_key" }}
    HINDSIGHT_API_TENANT_API_KEY={{ .Data.data.key }}
    {{- end }}
    {{- with secret "${mount}/data/memory/cp_key" }}
    HINDSIGHT_CP_ACCESS_KEY={{ .Data.data.key }}
    {{- end }}
    {{- with secret "${mount}/data/broker/tokens" }}
    HINDSIGHT_API_LLM_API_KEY={{ .Data.data.extraction }}
    {{- end }}
  '';

  webuiTemplate = ''
    {{- with secret "${mount}/data/ui/webui_secret" }}
    WEBUI_SECRET_KEY={{ .Data.data.value }}
    {{- end }}
  '';

  evaluationTemplate = ''
    {{- with secret "${mount}/data/observability/phoenix_secret" }}
    PHOENIX_SECRET={{ .Data.data.value }}
    {{- end }}
    {{- with secret "${mount}/data/eval/token" }}
    EVAL_TOKEN={{ .Data.data.value }}
    {{- end }}
  '';

  singleValueTemplate = path: ''
    {{- with secret "${mount}/data/${path}" }}{{ .Data.data.value }}{{ end }}
  '';

  # ------------------------------------------------------------------ agents
  # One agent per machine identity, each carrying the single policy it is due.
  # A role that reads a secret it does not need is a policy defect even when
  # nothing goes wrong.
  agentsByRole = {
    agent = {
      hermes = {
        owner = "hermes";
        templates = [
          { name = "hermes-core.env"; content = hermesCoreTemplate; mode = "0400"; reload = "hermes-api.service"; }
          { name = "hermes-svc.env"; content = hermesServiceTemplate; mode = "0400"; reload = null; }
          { name = "profile-bearers.json"; content = profileBearersJsonTemplate; mode = "0400"; reload = "hermes-api.service"; }
        ];
      };

      broker = {
        owner = "hermes-broker";
        templates = [
          { name = "broker-tokens.json"; content = brokerTokensTemplate; mode = "0400"; reload = "egress-broker.service"; }
          { name = "broker-credentials.json"; content = brokerCredentialsTemplate; mode = "0400"; reload = "egress-broker.service"; }
        ];
      };
    };

    memory = {
      memory = {
        owner = "root";
        templates = [
          { name = "pg.env"; content = postgresTemplate; mode = "0400"; reload = null; }
          { name = "hindsight.env"; content = hindsightTemplate; mode = "0400"; reload = null; }
        ];
      };
    };

    ingress = {
      ingress = {
        owner = "nginx";
        templates = [
          { name = "authelia/jwt"; content = singleValueTemplate "authelia/jwt_secret"; mode = "0400"; reload = null; }
          { name = "authelia/session"; content = singleValueTemplate "authelia/session_secret"; mode = "0400"; reload = null; }
          { name = "authelia/storage"; content = singleValueTemplate "authelia/storage_key"; mode = "0400"; reload = null; }
          { name = "open-webui.env"; content = webuiTemplate; mode = "0400"; reload = null; }
          { name = "profile-bearers.conf"; content = profileBearersTemplate; mode = "0400"; reload = "nginx.service"; }
        ];
      };
    };

    observability = {
      eval = {
        owner = "phoenix";
        templates = [
          { name = "phoenix.env"; content = evaluationTemplate; mode = "0400"; reload = "phoenix.service"; }
        ];
      };
    };
  };

  activeAgents = lib.foldl'
    (acc: role: acc // (agentsByRole.${role} or { }))
    { }
    hosts;

  templateStanza = agentName: template: ''
    template {
      source      = "/etc/bao/templates/${agentName}/${baseNameOf template.name}.tpl"
      destination = "${runtime}/${template.name}"
      perms       = "${template.mode}"
      ${lib.optionalString (template.reload != null)
        ''command     = "systemctl reload-or-restart ${template.reload}"''}
    }
  '';

  agentConfig = agentName: agent: pkgs.writeText "bao-agent-${agentName}.hcl" ''
    # Agent configuration for the ${agentName} identity. Generated from the
    # platform parameters: the mount point and the addresses have a single
    # declaration, so a rename cannot leave a stale reference behind.
    pid_file = "/run/bao-agent-${agentName}.pid"

    vault {
      address = "https://${cfg.secretStore.address}:${toString cfg.secretStore.port}"
      retry { num_retries = ${toString cfg.secretStore.retries} }
    }

    auto_auth {
      method "approle" {
        mount_path = "auth/approle"
        config = {
          role_id_file_path   = "${runtime}/openbao/${agentName}/role_id"
          secret_id_file_path = "${runtime}/openbao/${agentName}/secret_id"
          remove_secret_id_file_after_reading = false
        }
      }

      sink "file" {
        config = {
          path = "/run/bao/${agentName}.token"
          mode = 0400
        }
      }
    }

    # Local cache: the guest survives a temporarily sealed store for the
    # declared interval instead of failing on the first render cycle.
    cache {
      use_auto_auth_token = true
    }

    ${lib.concatMapStringsSep "\n" (templateStanza agentName) agent.templates}

    template_config {
      exit_on_retry_failure         = false
      static_secret_render_interval = "${cfg.secretStore.renderInterval}"
    }
  '';

  templateFiles = lib.foldl' (acc: entry: acc // entry) { } (lib.flatten (lib.mapAttrsToList
    (agentName: agent: map
      (template: {
        "bao/templates/${agentName}/${baseNameOf template.name}.tpl".text = template.content;
      })
      agent.templates)
    activeAgents));

  mkAgentService = agentName: agent: lib.nameValuePair "bao-agent-${agentName}" {
    description = "Secret store agent for the ${agentName} identity";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.openbao}/bin/bao agent -config=${agentConfig agentName agent}";
      Restart = "always";
      RestartSec = "5s";
      RuntimeDirectory = "bao";
      RuntimeDirectoryMode = "0710";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      LimitCORE = 0;
    };
  };
in
{
  config = lib.mkIf (activeAgents != { }) {
    # One bootstrap credential per machine identity hosted here. A guest that
    # can decrypt another guest's file would defeat the separation of policies
    # before the policies are ever consulted.
    sops.secrets = lib.foldl' (acc: entry: acc // entry) { } (lib.flatten (lib.mapAttrsToList
      (agentName: agent: [
        { "openbao/${agentName}/role_id" = { mode = "0400"; }; }
        { "openbao/${agentName}/secret_id" = { mode = "0400"; }; }
      ])
      activeAgents));

    environment.etc = templateFiles;

    systemd.services = lib.listToAttrs
      (lib.mapAttrsToList mkAgentService activeAgents);
  };
}
