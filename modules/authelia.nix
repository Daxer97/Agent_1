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

    telemetry.metrics = {
      enabled = true;
      address = "tcp://127.0.0.1:${toString cfg.identity.metricsPort}";
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
    authentication_backend = {
      refresh_interval = "5m";
      file = {
        path = "/etc/authelia/users.yml";
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
    environment.etc."authelia/users.yml".source = cfg.identity.usersFile;

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
  };
}
