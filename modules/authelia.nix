# Identity provider.
#
# Authentication happens in one place, and that place is also where the
# profile is resolved. The configuration is declarative and generated from the
# platform parameters, so it stays inside the flake rather than in an
# administrative interface — which is the reason a declaratively configured
# provider was chosen over one administered through a graphical console.
#
# No sensitive value appears here: the secrets are read from files rendered by
# the secret store agent.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  runtime = cfg.secretStore.runtimeSecretsPath;

  yamlFormat = pkgs.formats.yaml { };

  ingressAppAddress =
    let matches = lib.filter (i: i.zone == "app") cfg.guests.ingress.extraInterfaces;
    in (lib.head matches).address;

  usersFilePath = "/etc/authelia/users.yml";

  settings = {
    theme = "light";

    server = {
      address = "tcp://127.0.0.1:${toString cfg.identity.port}";
      buffers = { read = 8192; write = 8192; };
    };

    log = {
      level = cfg.identity.logLevel;
      format = "json";
    };

    # Bound to the application interface, not to loopback: the collector runs
    # on another guest and pulls this endpoint. On loopback the target can
    # never be scraped, and the platform reports the identity provider as down
    # while it is serving. Never the edge interface — the user network has no
    # business reaching a metrics endpoint — and the firewall admits it from
    # the observability guest alone.
    telemetry.metrics = {
      enabled = true;
      address = "tcp://${ingressAppAddress}:${toString cfg.identity.metricsPort}";
    };

    totp = {
      issuer = cfg.ingress.publicFqdn;
      algorithm = "sha1";
      digits = 6;
      period = 30;
      skew = 1;
    };

    webauthn = {
      disable = false;
      display_name = "HERMES-AGENT";
      attestation_conveyance_preference = "indirect";
      user_verification = "preferred";
    };

    # File backend for the sample population. A directory backend is the
    # expected choice in service, and substituting it does not touch the
    # access rules below.
    #
    # The file holds argon2id digests, so it is not a versioned plaintext
    # artefact and not a Nix store path either — the store is readable by
    # every user of the system. It travels encrypted with the bootstrap
    # credentials and is decrypted at activation, owned by the identity
    # provider and readable by nobody else.
    authentication_backend = {
      refresh_interval = "5m";
      file = {
        path = usersFilePath;
        watch = true;
        password = {
          algorithm = "argon2";
          argon2 = {
            variant = "argon2id";
            iterations = 3;
            memory = 65536;
            parallelism = 4;
          };
        };
      };
    };

    access_control = {
      default_policy = "deny";
      rules = [
        {
          domain = cfg.ingress.publicFqdn;
          policy = "two_factor";
          subject = [ "group:${cfg.identity.groups.users}" ];
        }
        {
          domain = cfg.ingress.controlPlaneFqdn;
          policy = "two_factor";
          subject = [ "group:${cfg.identity.groups.operators}" ];
        }
        {
          domain = cfg.observability.evaluation.fqdn;
          policy = "two_factor";
          subject = [ "group:${cfg.identity.groups.operators}" ];
        }
      ];
    };

    session = {
      name = "authelia_session";
      same_site = "lax";
      expiration = cfg.identity.session.expiration;
      inactivity = cfg.identity.session.inactivity;
      remember_me = cfg.identity.session.rememberMe;
      cookies = [{
        domain = cfg.ingress.cookieDomain;
        authelia_url = "https://${cfg.ingress.publicFqdn}/authelia";
        default_redirection_url = "https://${cfg.ingress.publicFqdn}/";
      }];
    };

    # Brute-force containment, in addition to the rate limit applied by the
    # proxy on the authentication routes.
    regulation = {
      max_retries = cfg.identity.regulation.maxRetries;
      find_time = cfg.identity.regulation.findTime;
      ban_time = cfg.identity.regulation.banTime;
    };

    storage.local.path = "/var/lib/authelia-main/db.sqlite3";

    notifier = {
      disable_startup_check = false;
      filesystem.filename = "/var/lib/authelia-main/notification.txt";
    };
  };
in
{
  config = lib.mkIf (builtins.elem "ingress" cfg.rolesHosted) {
    # The population travels in the same encrypted file as this guest's
    # bootstrap credential and is decrypted at activation. The shape of the
    # value is documented in config/authelia/users.example.yml; the digests
    # are produced on the workstation and never exist in the working tree.
    sops.secrets."authelia/users_file" = {
      path = usersFilePath;
      mode = "0400";
      owner = config.services.authelia.instances.main.user;
      group = config.services.authelia.instances.main.group;
    };

    services.authelia.instances.main = {
      enable = true;
      settingsFiles = [ (yamlFormat.generate "authelia-configuration.yml" settings) ];

      secrets = {
        jwtSecretFile = "${runtime}/authelia/jwt";
        sessionSecretFile = "${runtime}/authelia/session";
        storageEncryptionKeyFile = "${runtime}/authelia/storage";
      };
    };

    systemd.services.authelia-main = {
      after = [ "bao-agent-ingress.service" ];
      requires = [ "bao-agent-ingress.service" ];
    };

    # The access rules above are generated from hermes.identity, and the
    # population the identity provider authenticates is not. Nothing else in
    # the platform can notice the two drifting apart: an operator listed here
    # and absent from the file simply never logs in, and one present in the
    # file and absent here keeps whatever the file's groups grant. Stated at
    # build time so that the divergence is at least visible.
    warnings = lib.optional (cfg.identity.operators == [ ]) ''
      hermes.identity.operators is empty: no identity is recorded as entitled
      to the memory and evaluation consoles, while access to both is granted
      by membership of ${cfg.identity.groups.operators} in the user file.
    '';
  };
}
