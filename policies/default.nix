# Secret store policies.
#
# The separation of these policies is the control, not a convention of
# ordering. One policy — and one only — grants access to the inference
# credentials. The agentic identity has no rule for that path at all, and the
# absence of the rule is what produces the refusal: the store denies by
# default.
#
# Adding a rule for the inference path to the agentic policy would annul the
# whole arrangement with a two-line change that looks, to a distracted review,
# like a correction. That is the reason the negative test which proves the
# refusal runs before any application is deployed: verifying it afterwards
# means verifying it at the moment when dismantling it is expensive.
#
# The documents are rendered from the platform parameters so that the mount
# point has a single declaration. A rename cannot leave one of them behind.

{ lib, linkFarm, writeText, mount }:

let
  policies = {
    # The only policy with access to the inference credentials.
    broker = ''
      path "${mount}/data/inference/*" {
        capabilities = ["read"]
      }

      path "${mount}/metadata/inference/*" {
        capabilities = ["read", "list"]
      }

      # The broker issues the internal tokens as well as reading them: it is
      # the component that rotates them.
      path "${mount}/data/broker/tokens" {
        capabilities = ["read", "create", "update"]
      }

      path "${mount}/data/broker/tokens/*" {
        capabilities = ["read", "create", "update"]
      }

      path "auth/token/lookup-self" { capabilities = ["read"] }
      path "auth/token/renew-self"  { capabilities = ["update"] }
      path "sys/leases/renew"       { capabilities = ["update"] }
    '';

    # The agentic guest must not be able to read the inference credentials.
    hermes = ''
      # Its own internal token towards the broker, and nothing more.
      path "${mount}/data/broker/tokens" {
        capabilities = ["read"]
      }

      path "${mount}/data/broker/tokens/*" {
        capabilities = ["read"]
      }

      # Application key of the memory backend. Authentication, not
      # authorisation: whoever holds it reaches every bank, and the separation
      # between profiles rests on the bank identifier and on the network
      # segmentation instead.
      path "${mount}/data/memory/tenant_key" {
        capabilities = ["read"]
      }

      # Profile bearers served by this guest: the API server needs them to
      # validate the requests the proxy routes to it.
      path "${mount}/data/profiles/+/bearer" {
        capabilities = ["read"]
      }

      # Registry token used for rate limits only. It carries no privilege.
      path "${mount}/data/skills/github_token" {
        capabilities = ["read"]
      }

      path "auth/token/renew-self" { capabilities = ["update"] }

      # There is deliberately NO rule for ${mount}/data/inference/*.
      # Adding one here annuls the containment of the inference credential.
    '';

    memory = ''
      path "${mount}/data/db/hindsight" {
        capabilities = ["read"]
      }

      path "${mount}/data/memory/tenant_key" {
        capabilities = ["read"]
      }

      path "${mount}/data/memory/cp_key" {
        capabilities = ["read"]
      }

      # Token for the extraction channel towards the broker — not the gateway
      # credential. The extraction channel is the higher-volume one, and it
      # goes through the broker for exactly that reason.
      path "${mount}/data/broker/tokens" {
        capabilities = ["read"]
      }

      path "auth/token/renew-self" { capabilities = ["update"] }
    '';

    ingress = ''
      path "${mount}/data/authelia/*" {
        capabilities = ["read"]
      }

      # Identity to profile to bearer, resolved by the proxy.
      path "${mount}/data/profiles/+/bearer" {
        capabilities = ["read"]
      }

      path "${mount}/data/ui/webui_secret" {
        capabilities = ["read"]
      }

      path "auth/token/renew-self" { capabilities = ["update"] }
    '';

    # Identity of the evaluation platform. It reads its own secret and its own
    # internal token towards the broker. It does not read the inference
    # credentials: the invariant admits no exception for evaluators either.
    eval = ''
      path "${mount}/data/observability/phoenix_secret" {
        capabilities = ["read"]
      }

      path "${mount}/data/eval/token" {
        capabilities = ["read"]
      }

      path "auth/token/renew-self" { capabilities = ["update"] }
    '';
  };

  # The registry of paths the platform expects to exist. Completeness is
  # verified by difference against this list rather than by testing each path
  # in turn. The distinction is not academic: a path declared and never
  # populated does not produce a configuration error, it produces the failure
  # of whichever step reads it — and when that step is the negative test which
  # proves the central invariant, the failure reads as evidence that the
  # invariant holds.
  expectedPaths = [
    "authelia/jwt_secret"
    "authelia/session_secret"
    "authelia/storage_key"
    "broker/tokens"
    "db/hindsight"
    "eval/token"
    "inference/extraction"
    "inference/interactive"
    "inference/programmatic"
    "memory/cp_key"
    "memory/tenant_key"
    "observability/phoenix_secret"
    "skills/github_token"
    "ui/webui_secret"
  ];
in
linkFarm "hermes-bao-policies" (
  (lib.mapAttrsToList
    (name: body: {
      name = "${name}.hcl";
      path = writeText "${name}.hcl" body;
    })
    policies)
  ++ [{
    name = "expected-paths.txt";
    path = writeText "expected-paths.txt"
      (lib.concatStringsSep "\n" expectedPaths + "\n");
  }]
)
