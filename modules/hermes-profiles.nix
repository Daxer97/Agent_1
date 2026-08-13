# Profile provisioning.
#
# User profiles and service profiles are generated from one declaration, in an
# idempotent way. Running a workload inside a user profile is a high-impact
# risk, and the implementation countermeasure is that no profile is ever
# created by hand: a manually created profile works, and is still a defect.
#
# The same declaration produces the identity map the proxy resolves. Ingress
# and runtime therefore cannot drift apart, because there is only one place
# where the mapping is written.

{ config, lib, pkgs, hermesEnv, ... }:

let
  cfg = config.hermes;
  runtime = cfg.secretStore.runtimeSecretsPath;

  userProfiles = map (u: u.profile) cfg.identity.users;
  serviceProfiles = map (name: "${cfg.agent.profilePrefixService}-${name}")
    (builtins.attrNames cfg.programmatic.workloads);
  allProfiles = userProfiles ++ serviceProfiles;

  memoryApi = "http://${cfg.guests.memory.address}:${toString cfg.memory.hindsight.apiPort}";
  bankOf = profile: lib.replaceStrings [ "{profile}" ] [ profile ] cfg.memory.hindsight.bankTemplate;

  provisionScript = pkgs.writeShellScript "hermes-provision-profiles" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.openbao ]}:$PATH"
    export BAO_ADDR="https://${cfg.secretStore.address}:${toString cfg.secretStore.port}"

    ${lib.concatMapStringsSep "\n" (profile: ''
      echo "profile ${profile}"

      # 1. the profile itself, idempotently
      ${hermesEnv}/bin/hermes profile create "${profile}" 2>/dev/null || true

      # 2. its memory bank, derived from the template that is the tenancy
      #    boundary
      curl -sS -X PUT \
        -H "Authorization: Bearer $HINDSIGHT_API_KEY" \
        "${memoryApi}/v1/${cfg.memory.hindsight.tenant}/banks/${bankOf profile}" \
        >/dev/null

      # 3. the profile bearer and the broker token, created only if absent so
      #    that a re-run neither rotates nor invalidates a working credential
      if ! bao kv get "${cfg.secretStore.mount}/profiles/${profile}/bearer" >/dev/null 2>&1; then
        bao kv put "${cfg.secretStore.mount}/profiles/${profile}/bearer" \
          value="$(head -c 32 /dev/urandom | base64 -w0)"
      fi

      if ! bao kv get "${cfg.secretStore.mount}/broker/tokens/${profile}" >/dev/null 2>&1; then
        bao kv put "${cfg.secretStore.mount}/broker/tokens/${profile}" \
          value="$(head -c 32 /dev/urandom | base64 -w0)"
      fi
    '') allProfiles}

    # 4. the per-profile credential locks, which prevent two concurrent
    #    profiles from colliding. Verified after every provisioning run, not
    #    only after the first.
    ${hermesEnv}/bin/hermes profile verify-locks
  '';
in
{
  config = lib.mkMerge [
    # The identity map is derived from a compile-time declaration, so it is
    # generated identically wherever it is needed: the proxy resolves it at
    # the ingress, the runtime honours it in the application zone.
    {
      environment.etc.${lib.removePrefix "/etc/" cfg.ingress.identityMapPath}.text =
        lib.concatMapStringsSep "\n"
          (user: ''"${user.identity}" "${user.profile}";'')
          cfg.identity.users;
    }

    (lib.mkIf (builtins.elem "agent" cfg.rolesHosted) {
      systemd.services.hermes-provision-profiles = {
        description = "Idempotent provisioning of user and service profiles";
        wantedBy = [ "multi-user.target" ];
        after = [ "bao-agent-hermes.service" "network-online.target" ];
        requires = [ "bao-agent-hermes.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = provisionScript;
          EnvironmentFile = [ "${runtime}/hermes-core.env" ];
          User = "hermes";
          Group = "hermes";
        };
      };
    })
  ];
}
