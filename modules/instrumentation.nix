# Instrumentation of the agentic loop.
#
# A single document owns the lifecycle of the exporters. The separation
# between the event stream and the trajectory stream is not cosmetic: the
# trajectory carries conversational content and must never reach the log
# backend, whereas the event stream carries metrics and identifiers only.
#
# The trace semantics declared here is what the trace backend expects. The
# pinned revision of the instrumentation must expose it: a revision predating
# it passes the deployment phase and silently drops the delegation attributes,
# after which a turn that fanned out to nine workers is indistinguishable from
# a simple one. The cost measurement does not become approximate in that case,
# it becomes invalid.
#
# The destination is the collector, never the trace backend directly. The
# collector is where the split between the scrubbed and the unscrubbed branch
# is decided, and that decision must stay outside the perimeter in which
# model-generated code runs.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  tomlFormat = pkgs.formats.toml { };

  otlpEndpoint = "http://${cfg.observability.address}:${toString cfg.observability.collectorGrpcPort}";

  pluginsFor = plane: tomlFormat.generate "plugins-${plane}.toml" {
    version = 1;

    components = [{
      kind = "observability";
      enabled = true;

      config = {
        version = 1;

        # Events: metrics and identifiers, no content.
        atof = {
          enabled = true;
          output_directory = cfg.observability.instrumentation.eventsPath;
          filename = "events.jsonl";
          mode = "append";
        };

        # Trajectories: they contain content. Restricted permissions, and no
        # exporter towards a shared backend.
        atif = {
          enabled = true;
          output_directory = cfg.observability.instrumentation.trajectoryPath;
          filename_template = "trajectory-{session_id}.json";
          agent_name = "hermes-${plane}";
          agent_version = cfg.agent.sourceRevision;
          subagent_export_mode = "embedded";
        };

        opentelemetry = {
          enabled = true;
          endpoint = otlpEndpoint;
          type = cfg.observability.instrumentation.traceSemantics;
          transport = "grpc";
          service_name = "hermes-${plane}";
          hide_inputs = cfg.observability.instrumentation.hideInputs;
          hide_outputs = cfg.observability.instrumentation.hideOutputs;
        };
      };
    }];
  };
in
{
  config = lib.mkIf (builtins.elem "agent" cfg.rolesHosted) {
    # One document per plane. The agent name and the service name carry the
    # plane, and the two containers mount the same directory read-only, so a
    # single shared file would label one plane as the other.
    environment.etc = {
      "hermes/plugins-interactive.toml".source = pluginsFor "interactive";
      "hermes/plugins-programmatic.toml".source = pluginsFor "programmatic";
    };
  };
}
