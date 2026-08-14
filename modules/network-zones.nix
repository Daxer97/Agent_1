# Network segmentation.
#
# Three zones, and a default-deny policy in both directions: anything not
# listed below is denied. The inbound rules are written against the source
# range rather than against the interface, because the routing between zones
# is performed by the device upstream — traffic between two zones leaves the
# bridge and comes back to it, and a rule written per interface does not
# intercept it.
#
# The outbound rules on the agentic guest distinguish processes by user, not
# by host. The broker and the agentic containers live on the same guest, so a
# rule written against the guest address would admit both and turn the
# restriction into a convention: an agent could reach the gateway directly
# with a credential obtained elsewhere without violating any firewall rule.

{ config, lib, ... }:

let
  cfg = config.hermes;
  hosts = cfg.rolesHosted;
  hostsRole = role: builtins.elem role hosts;

  zone = name: cfg.network.zones.${name}.cidr;

  addressOf = role: cfg.guests.${role}.address;

  # The ingress guest is dual-homed. Every flow towards a downstream service
  # is admitted from its application-zone interface only: a rule written
  # against the edge address would defeat the segmentation without producing
  # any error.
  ingressAppAddress =
    let
      matches = lib.filter (i: i.zone == "app") cfg.guests.ingress.extraInterfaces;
    in
    if matches == [ ]
    then throw "The ingress guest must declare an interface in the application zone."
    else (lib.head matches).address;

  commonInbound = [
    "iifname lo accept"
    "ct state established,related accept"
    "ip saddr ${cfg.network.managementCidr} tcp dport 22 accept comment \"administration from the management range only\""
  ];

  inboundByRole = {
    ingress = [
      "tcp dport 443 accept comment \"only flow admitted from the user network\""

      # The collector pulls this one: without the rule the identity provider
      # is permanently down as far as the platform is concerned, and the
      # availability alert fires against a healthy service.
      "ip saddr ${addressOf "observability"} tcp dport ${toString cfg.identity.metricsPort} accept comment \"identity provider metrics scrape\""
    ];

    agent = [
      "ip saddr ${ingressAppAddress} tcp dport ${toString cfg.agent.api.port} accept comment \"API server, from the ingress application interface only\""
      "ip saddr ${addressOf "memory"} tcp dport ${toString cfg.broker.port} accept comment \"memory extraction calls towards the broker\""

      # Two flows, one rule, both from the observability guest and both
      # towards the broker: the metric scrape, and the evaluator calls, which
      # go through the broker like every other call — the containment of the
      # inference credential admits no exception for evaluators.
      "ip saddr ${addressOf "observability"} tcp dport ${toString cfg.broker.port} accept comment \"broker metrics scrape and evaluator calls\""
    ];

    memory = [
      "ip saddr ${addressOf "agent"} tcp dport ${toString cfg.memory.hindsight.apiPort} accept comment \"recall and retain, from the agentic guest only\""
      "ip saddr ${ingressAppAddress} tcp dport ${toString cfg.memory.hindsight.controlPlanePort} accept comment \"inspection console, through the proxy only\""
      "ip saddr ${addressOf "observability"} tcp dport ${toString cfg.memory.hindsight.apiPort} accept comment \"memory backend metrics scrape\""
    ];

    secrets = [
      "ip saddr { ${zone "app"}, ${zone "data"} } tcp dport ${toString cfg.secretStore.port} accept comment \"secret retrieval from the application and data zones, never from the edge\""
    ];

    observability = [
      "ip saddr { ${zone "app"}, ${zone "data"} } tcp dport { ${toString cfg.observability.collectorGrpcPort}, ${toString cfg.observability.collectorHttpPort} } accept comment \"telemetry ingestion\""
      "ip saddr ${cfg.network.managementCidr} tcp dport ${toString cfg.observability.dashboardPort} accept comment \"dashboards from the management range only\""
      "ip saddr ${ingressAppAddress} tcp dport ${toString cfg.observability.evaluation.port} accept comment \"evaluation console, through the proxy only\""
    ];
  };

  inboundRules = commonInbound
    ++ lib.concatMap (role: inboundByRole.${role} or [ ]) hosts;

  agenticOutbound = ''
    # Only the broker reaches the inference gateway. Restricting the
    # destination to the gateway by name is applied by the perimeter device
    # ${cfg.network.perimeterFirewall}, which is the only place able to
    # express it.
    meta skuid ${toString cfg.broker.uid} tcp dport 443 accept comment "broker egress"

    # Skill acquisition is user-operated and originates from the agent
    # runtime alone.
    meta skuid ${toString cfg.agent.uid} tcp dport 443 accept comment "skill registries"
  '';

  nonAgenticOutbound = ''
    # The remaining guests reach the binary cache and the image registries
    # during a rebuild, and nothing else.
    tcp dport 443 accept
  '';
in
{
  config = {
    networking.nftables.enable = true;

    networking.firewall = {
      enable = true;
      allowPing = false;

      # Dropped rather than rejected: a rejection confirms that the host
      # exists, which is exactly what the reachability test from the user
      # network is meant to disprove.
      rejectPackets = false;

      allowedTCPPorts = [ ];
      extraInputRules = lib.concatStringsSep "\n" inboundRules;
    };

    networking.nftables.tables.hermes-egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority 0; policy drop;

          oifname lo accept
          ct state established,related accept

          # Infrastructure services and the internal zones.
          udp dport { 53, 123 } accept
          tcp dport 53 accept
          ip daddr { ${zone "app"}, ${zone "data"} } accept

          ${if hostsRole "agent" then agenticOutbound else nonAgenticOutbound}
        }
      '';
    };
  };
}
