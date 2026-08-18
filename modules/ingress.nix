# Ingress.
#
# This is the trust boundary of the platform. Everything downstream assumes
# that the identity header was written by the proxy and not by the client;
# this module is what makes that assumption true.
#
# The resolution chain is: authenticated identity, header rewritten by the
# proxy, profile resolved by explicit enumeration, bearer of that profile,
# path prefix, memory bank derived from the template. Every step is applied by
# a component the user does not control, and the request body never enters the
# chain.
#
# The fragile step is the profile resolution. Were it a string normalisation —
# lower-casing, address aliases, non-ASCII folding — two distinct identities
# could collapse onto the same profile, and therefore onto the same memory
# bank, with no visible error. The map is an enumeration for that reason, and
# an empty profile or an empty bearer returns a refusal: a loud failure is
# preferable to a silent sharing.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  runtime = cfg.secretStore.runtimeSecretsPath;

  agentApi = "http://${cfg.guests.agent.address}:${toString cfg.agent.api.port}";
  prefix = cfg.agent.api.profilePrefix;

  ingressAppAddress =
    let matches = lib.filter (i: i.zone == "app") cfg.guests.ingress.extraInterfaces;
    in (lib.head matches).address;

  securityHeaders = ''
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
  '';

  verifyLocation = ''
    auth_request /authelia-verify;
    auth_request_set $authelia_user  $upstream_http_remote_user;
    auth_request_set $authelia_email $upstream_http_remote_email;
    auth_request_set $authelia_group $upstream_http_remote_groups;
    error_page 401 =302 https://${cfg.ingress.publicFqdn}/authelia?rd=$scheme://$http_host$request_uri;
  '';

  # Operator consoles reached through the proxy. The traffic leaves from the
  # application interface, never from the edge one: a rule bound to the edge
  # address would defeat the segmentation without producing any error.
  operatorConsole = upstream: ''
    ${verifyLocation}
    proxy_bind ${ingressAppAddress};
    proxy_pass ${upstream};
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout ${cfg.ingress.timeouts.proxyRead};
  '';
in
{
  config = lib.mkIf (builtins.elem "ingress" cfg.rolesHosted) {
    # ------------------------------------------------------------ chat UI
    virtualisation.oci-containers.backend = "podman";
    virtualisation.podman.enable = true;

    virtualisation.oci-containers.containers.open-webui = {
      image = cfg.ingress.webui.image;
      autoStart = true;

      # Bound to loopback: reachable only through the proxy.
      ports = [ "127.0.0.1:${toString cfg.ingress.webui.port}:8080" ];

      environment = {
        WEBUI_AUTH_TRUSTED_EMAIL_HEADER = "Remote-Email";
        WEBUI_AUTH_TRUSTED_NAME_HEADER = "Remote-User";
        OPENAI_API_BASE_URL = "${agentApi}${prefix}";
        ENABLE_SIGNUP = "false";

        # The identity provider is the only way in.
        ENABLE_LOGIN_FORM = "false";
      };

      environmentFiles = [ "${runtime}/open-webui.env" ];
      volumes = [ "${cfg.ingress.webui.dataPath}:/app/backend/data" ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.ingress.webui.dataPath} 0750 root root -"
    ];

    # ------------------------------------------------------------- proxy
    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedGzipSettings = true;

      # The identity headers are set here, explicitly, and not by a
      # convenience preset whose contents may change.
      recommendedProxySettings = false;

      sslProtocols = if cfg.ingress.tls.minimumVersion == "TLSv1.3"
        then "TLSv1.3"
        else "TLSv1.2 TLSv1.3";

      appendHttpConfig = ''
        # Rate limit on the authentication routes only: contains brute force
        # and account enumeration.
        limit_req_zone $binary_remote_addr zone=authzone:10m rate=${cfg.ingress.rateLimit.auth};

        # 1) authenticated identity to profile. An explicit map, generated
        #    from the same declaration that provisions the profiles.
        map $authelia_email $hermes_profile {
          default "";
          include ${cfg.ingress.identityMapPath};
        }

        # 2) profile to bearer. Rendered by the secret store agent in tmpfs.
        map $hermes_profile $profile_bearer {
          default "";
          include ${runtime}/profile-bearers.conf;
        }

        proxy_read_timeout    ${cfg.ingress.timeouts.proxyRead};
        proxy_connect_timeout ${cfg.ingress.timeouts.proxyConnect};
      '';

      virtualHosts = {
        "${cfg.ingress.publicFqdn}" = {
          forceSSL = true;
          sslCertificate = cfg.ingress.tls.certificate;
          sslCertificateKey = cfg.ingress.tls.key;
          extraConfig = securityHeaders;

          locations = {
            # Internal verification endpoint of the forward-auth exchange.
            "/authelia-verify".extraConfig = ''
              internal;
              proxy_pass http://127.0.0.1:${toString cfg.identity.port}/api/authz/auth-request;
              proxy_pass_request_body off;
              proxy_set_header Content-Length "";
              proxy_set_header X-Original-Method $request_method;
              proxy_set_header X-Original-URL    $scheme://$http_host$request_uri;
            '';

            "/authelia".extraConfig = ''
              limit_req zone=authzone burst=${toString cfg.ingress.rateLimit.burst} nodelay;
              proxy_pass http://127.0.0.1:${toString cfg.identity.port};
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host  $http_host;
            '';

            "/".extraConfig = ''
              ${verifyLocation}

              # The most important lines of this file: they overwrite,
              # unconditionally, any header of the same name sent by the
              # client. Without them anybody could impersonate anybody by
              # sending a header.
              proxy_set_header Remote-User   $authelia_user;
              proxy_set_header Remote-Email  $authelia_email;
              proxy_set_header Remote-Groups $authelia_group;

              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_pass http://127.0.0.1:${toString cfg.ingress.webui.port};
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";

              # Streamed answers must not be buffered.
              proxy_buffering off;
              proxy_read_timeout ${cfg.ingress.timeouts.clientRead};
            '';

            "${prefix}/".extraConfig = ''
              auth_request /authelia-verify;
              auth_request_set $authelia_email $upstream_http_remote_email;

              # An unknown identity resolves to an empty profile and is
              # refused visibly. An automatic transformation of the identity
              # string would fail silently instead, collapsing two identities
              # onto one profile.
              if ($hermes_profile = "") { return 403; }
              if ($profile_bearer = "") { return 403; }

              proxy_set_header Authorization "Bearer $profile_bearer";
              proxy_set_header Remote-Email  $authelia_email;

              # add_header does not add to what the server block set: it
              # replaces it. This is the only location that declares a header
              # of its own, so without repeating them here it is the only
              # route that answers without the security headers — and it is
              # the API route, the one carrying the bearer.
              ${securityHeaders}
              add_header Access-Control-Allow-Origin "${cfg.ingress.corsAllowedOrigins}" always;
              add_header Access-Control-Allow-Credentials "true" always;

              proxy_bind ${ingressAppAddress};
              proxy_pass ${agentApi}${prefix}/$hermes_profile/;
              proxy_http_version 1.1;
              proxy_buffering off;
              proxy_read_timeout ${cfg.ingress.timeouts.clientRead};
            '';
          };
        };

        # Memory inspection console — operators only.
        "${cfg.ingress.controlPlaneFqdn}" = {
          forceSSL = true;
          sslCertificate = cfg.ingress.tls.certificate;
          sslCertificateKey = cfg.ingress.tls.key;
          extraConfig = securityHeaders;
          locations."/".extraConfig = operatorConsole
            "http://${cfg.guests.memory.address}:${toString cfg.memory.hindsight.controlPlanePort}";
        };

        # Evaluation console — operators only. The evaluation platform has an
        # authentication mechanism of its own; it is not used, because the
        # platform has a single identity provider.
        "${cfg.observability.evaluation.fqdn}" = {
          forceSSL = true;
          sslCertificate = cfg.ingress.tls.certificate;
          sslCertificateKey = cfg.ingress.tls.key;
          extraConfig = securityHeaders;
          locations."/".extraConfig = operatorConsole
            "http://${cfg.observability.evaluation.bindAddress}:${toString cfg.observability.evaluation.port}";
        };
      };
    };

    systemd.services.nginx = {
      after = [ "bao-agent-ingress.service" ];
      requires = [ "bao-agent-ingress.service" ];
    };

    systemd.services.podman-open-webui = {
      after = [ "bao-agent-ingress.service" ];
      requires = [ "bao-agent-ingress.service" ];
    };
  };
}
