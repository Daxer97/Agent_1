# Observability.
#
# Without instrumentation three of the declared objectives are not measurable,
# which is why this is part of the platform rather than an addition made
# afterwards.
#
# The rule that governs the collector configuration is the separation of the
# scrub by signal. The scrubbing processor stays on the log pipeline in full,
# and is not applied to the trace pipeline, whose only destination is the
# evaluation platform. Until the trace backend was replaced both pipelines
# ended in shared backends and both were scrubbed; now the trace pipeline has
# a single, declared destination, so scrubbing it would protect nothing and
# would prevent the evaluation entirely.
#
# The constraint that follows is not negotiable: the trace pipeline admits no
# exporter other than the evaluation platform. An additional trace backend —
# a corporate monitoring system, a restoration of the previous one — requires
# a separate pipeline with the scrub enabled. Adding it here would create a
# fourth artefact holding conversational content without declaring it, and
# would produce no error.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  obs = cfg.observability;

  yamlFormat = pkgs.formats.yaml { };

  ingressAppAddress =
    let matches = lib.filter (i: i.zone == "app") cfg.guests.ingress.extraInterfaces;
    in (lib.head matches).address;

  scrapeTarget = name: address: {
    job_name = name;
    scrape_interval = obs.scrapeInterval;
    static_configs = [{ targets = [ address ]; }];
  };

  collectorConfig = yamlFormat.generate "collector.yaml" {
    receivers = {
      otlp.protocols = {
        grpc.endpoint = "0.0.0.0:${toString obs.collectorGrpcPort}";
        http.endpoint = "0.0.0.0:${toString obs.collectorHttpPort}";
      };

      prometheus.config.scrape_configs = [
        (scrapeTarget "egress-broker" "${cfg.guests.agent.address}:${toString cfg.broker.port}")
        (scrapeTarget "hindsight" "${cfg.guests.memory.address}:${toString cfg.memory.hindsight.apiPort}")
        (scrapeTarget "authelia" "${ingressAppAddress}:${toString cfg.identity.metricsPort}")
        (scrapeTarget "phoenix" "${obs.evaluation.bindAddress}:${toString obs.evaluation.port}")
      ];
    };

    processors = {
      batch = { timeout = "5s"; send_batch_size = 1024; };

      memory_limiter = {
        check_interval = "2s";
        limit_percentage = 75;
        spike_limit_percentage = 15;
      };

      # Last line of defence for the shared backends: every attribute able to
      # carry conversational text is removed before export. The filter does
      # not replace the discipline applied at the application; it makes that
      # discipline resistant to a debug level left switched on.
      "attributes/scrub".actions = map (key: { inherit key; action = "delete"; }) [
        "prompt"
        "completion"
        "input"
        "output"
        "messages"
        "tool.arguments"
        "tool.result"
        "recall.text"
      ];

      "resource/env".attributes = [{
        key = "deployment.environment";
        value = "poc";
        action = "upsert";
      }];
    };

    exporters = {
      prometheusremotewrite = {
        endpoint = "http://127.0.0.1:${toString obs.metricsPort}/api/v1/write";
        resource_to_telemetry_conversion.enabled = true;
      };

      "otlp/evaluation" = {
        endpoint = "${obs.evaluation.bindAddress}:${toString obs.evaluation.grpcPort}";
        tls.insecure = true;
      };

      loki = {
        endpoint = "http://127.0.0.1:${toString obs.logsPort}/loki/api/v1/push";
        default_labels_enabled = { exporter = false; job = true; };
      };
    };

    service = {
      telemetry.logs.level = obs.logLevel;

      pipelines = {
        # Declared branch: content is admitted here, and only here.
        traces = {
          receivers = [ "otlp" ];
          processors = [ "memory_limiter" "resource/env" "batch" ];
          exporters = [ "otlp/evaluation" ];
        };

        metrics = {
          receivers = [ "otlp" "prometheus" ];
          processors = [ "memory_limiter" "resource/env" "batch" ];
          exporters = [ "prometheusremotewrite" ];
        };

        # Shared branch: scrubbing is mandatory.
        logs = {
          receivers = [ "otlp" ];
          processors = [ "memory_limiter" "attributes/scrub" "resource/env" "batch" ];
          exporters = [ "loki" ];
        };
      };
    };
  };

  alertRules = {
    groups = [
      {
        name = "hermes-objectives";
        interval = obs.alerts.window;

        rules = [
          # Cost per task across every attributable spending channel.
          {
            record = "hermes:cost_per_task:sum";
            expr = "sum by (plane) (rate(hermes_inference_cost_usd_total{purpose!=\"eval\"}[${obs.alerts.window}]))";
          }
          {
            alert = "DailyCostAboveThreshold";
            expr = "sum(increase(hermes_inference_cost_usd_total{purpose!=\"eval\"}[24h])) > ${toString obs.alerts.costDaily}";
            for = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "Daily spend above ${toString obs.alerts.costDaily} USD";
              description = ''
                Includes the memory extraction channel, which is the quantity
                the cost objective requires — not the conversational channel
                alone. The evaluation channel is excluded, because it is an
                instrument of measurement rather than inference attributable
                to a user task.
              '';
            };
          }
          {
            alert = "BudgetHardCapReached";
            expr = "hermes_broker_budget_used_ratio >= 1";
            for = "1m";
            labels.severity = "critical";
            annotations.summary = "Hard cap reached for {{ $labels.plane }}/{{ $labels.profile }}";
          }
          {
            alert = "UnattributedCost";
            expr = "increase(hermes_broker_cost_unattributed_total[${obs.alerts.window}]) > 0";
            for = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "The broker cannot attribute cost";
              description = "The cap keeps working but becomes blind: check the gateway accounting endpoint.";
            };
          }

          # Share of turns that trigger deliberation.
          {
            record = "hermes:deliberation_ratio";
            expr = ''
              sum(rate(hermes_llm_completions_total{fusion="true"}[${obs.alerts.window}]))
              /
              sum(rate(hermes_llm_completions_total[${obs.alerts.window}]))
            '';
          }
          {
            alert = "DeliberationRatioAboveThreshold";
            expr = "hermes:deliberation_ratio > ${toString obs.alerts.deliberationRatioMax}";
            for = "15m";
            labels.severity = "warning";
          }

          # Recall coverage and latency.
          {
            alert = "RecallCoverageDegraded";
            expr = ''
              sum(rate(hermes_memory_recall_total{result="hit"}[${obs.alerts.memoryWindow}]))
              / sum(rate(hermes_memory_recall_total[${obs.alerts.memoryWindow}]))
              < ${toString obs.alerts.recallCoverageMin}
            '';
            for = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "Share of turns served with memory context below threshold";
              description = ''
                Recall degradation is silent by construction: the turn
                proceeds without context and no error reaches the user. This
                rule is the only place it becomes visible.
              '';
            };
          }
          {
            alert = "RecallLatencyHigh";
            expr = ''
              histogram_quantile(0.95,
                sum by (le) (rate(hermes_memory_recall_duration_seconds_bucket[${obs.alerts.memoryWindow}])))
              > ${lib.removeSuffix "s" obs.alerts.recallP95}
            '';
            for = "10m";
            labels.severity = "warning";
          }
          {
            alert = "RetainQueueGrowing";
            expr = "hermes_memory_retain_queue_depth > ${toString obs.alerts.retainQueue}";
            for = "10m";
            labels.severity = "warning";
          }
        ];
      }

      {
        name = "hermes-availability";
        interval = obs.alerts.window;

        rules = [
          {
            alert = "BrokerUnavailable";
            expr = ''up{job="egress-broker"} == 0'';
            for = "1m";
            labels.severity = "critical";
            annotations = {
              summary = "Egress broker unreachable — both planes lose inference";
              description = "Single point of failure accepted with local redundancy only.";
            };
          }
          {
            alert = "MemoryUnavailable";
            expr = ''up{job="hindsight"} == 0'';
            for = "2m";
            labels.severity = "warning";
            annotations.summary = "Memory backend unreachable — turns proceed without context";
          }
          {
            alert = "InteractiveLatencyHigh";
            expr = ''
              histogram_quantile(0.95,
                sum by (le) (rate(hermes_turn_duration_seconds_bucket{plane="interactive"}[${obs.alerts.window}])))
              > ${lib.removeSuffix "s" obs.alerts.latencyP95}
            '';
            for = "10m";
            labels.severity = "warning";
          }
          {
            alert = "ProgrammaticWorkloadFailed";
            expr = ''increase(hermes_svc_runs_total{status="failed"}[${obs.alerts.window}]) > ${toString obs.alerts.workloadFailures}'';
            for = "5m";
            labels.severity = "warning";
          }
          {
            alert = "TraceBackendUnreachable";
            expr = ''up{job="phoenix"} == 0'';
            for = obs.alerts.window;
            labels.severity = "warning";
            annotations = {
              summary = "Trace backend unreachable";
              description = ''
                The agentic loop is not affected and no start-up is prevented:
                traces are simply not collected. It is not critical because
                the service does not degrade, but the retrieval measurement
                cannot be produced while it lasts.
              '';
            };
          }
          {
            alert = "DelegationAttributeMissing";
            expr = ''
              sum(rate(hermes_delegation_spans_total[${obs.alerts.window}]))
                - sum(rate(hermes_delegation_spans_total{spawn_depth!=""}[${obs.alerts.window}]))
              > 0
            '';
            for = "10m";
            labels.severity = "critical";
            annotations = {
              summary = "Delegation spans without a depth attribute";
              description = ''
                The change of trace semantics has dropped the custom
                attributes. Cost per delegation level is no longer
                decomposable and a turn that fanned out is indistinguishable
                from a simple one. Correct this before any cost measurement:
                the measurement does not become approximate, it becomes
                invalid.
              '';
            };
          }
          {
            alert = "UndeclaredContentArtifact";
            expr = "telemetry_content_hits_total > 0";
            for = "1m";
            labels.severity = "critical";
            annotations = {
              summary = "Conversational content in an undeclared backend";
              description = ''
                Distinct from the rules watching the known backends: this one
                watches for the appearance of a fourth artefact holding
                content. The most probable cause is an exporter added to the
                trace pipeline.
              '';
            };
          }
        ];
      }
    ];
  };

  dashboardDatasources = {
    apiVersion = 1;

    datasources = [
      {
        name = "Prometheus";
        type = "prometheus";
        access = "proxy";
        url = "http://127.0.0.1:${toString obs.metricsPort}";
        isDefault = true;
        jsonData.timeInterval = obs.scrapeInterval;
      }
      {
        name = "Loki";
        type = "loki";
        access = "proxy";
        url = "http://127.0.0.1:${toString obs.logsPort}";

        # Correlation from a log line to its trace, on a single identifier.
        # The trace backend has no native datasource here, so the jump is an
        # external link rather than an internal navigation. The link format is
        # not a stable contract and must be confirmed against the version in
        # use.
        jsonData.derivedFields = [{
          name = "trace_id";
          matcherRegex = ''"trace_id":"(\w+)"'';
          url = "https://${obs.evaluation.fqdn}/projects/${obs.evaluation.projectName}/traces/\${__value.raw}";
          targetBlank = true;
        }];
      }
    ];
  };
in
{
  config = lib.mkIf (builtins.elem "observability" cfg.rolesHosted) {
    environment.etc.${lib.removePrefix "/etc/" obs.collectorConfigPath}.source =
      collectorConfig;

    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      configFile = collectorConfig;
    };

    services.prometheus = {
      enable = true;
      port = obs.metricsPort;
      retentionTime = "${toString obs.retention.observability}d";

      # On the volume declared for observability data. Left at its default the
      # metric store grows on the root volume of this guest, which also holds
      # the secret store — and the point of the second volume is that when it
      # fills up what is lost is observability. The option is relative to
      # /var/lib by construction, hence the assertion below.
      stateDir = lib.removePrefix "/var/lib/" "${obs.dataPath}/prometheus";

      # The collector writes the samples in; nothing is scraped from here
      # directly, so that the scrape configuration has a single home.
      extraFlags = [ "--web.enable-remote-write-receiver" ];

      ruleFiles = [ (yamlFormat.generate "hermes-rules.yml" alertRules) ];
    };

    services.loki = {
      enable = true;
      configuration = {
        auth_enabled = false;
        server.http_listen_port = obs.logsPort;
        common = {
          ring.kvstore.store = "inmemory";
          replication_factor = 1;
          path_prefix = "${obs.dataPath}/loki";
        };
        storage_config.filesystem.directory = "${obs.dataPath}/loki/chunks";
        compactor = {
          working_directory = "${obs.dataPath}/loki/compactor";
          retention_enabled = true;
          delete_request_store = "filesystem";
        };
        schema_config.configs = [{
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = { prefix = "index_"; period = "24h"; };
        }];
        limits_config.retention_period = "${toString obs.retention.observability}d";
      };
    };

    services.grafana = {
      enable = true;

      settings.server = {
        http_addr = "0.0.0.0";
        http_port = obs.dashboardPort;
        root_url = "https://${obs.evaluation.fqdn}/";
      };

      provision = {
        enable = true;
        datasources.path = yamlFormat.generate "datasources.yml" dashboardDatasources;
      };
    };

    assertions = [{
      assertion = lib.hasPrefix "/var/lib/" obs.dataPath;
      message = ''
        hermes.observability.dataPath must be under /var/lib: the metric
        store is placed on it through an option that is relative to that
        directory, and outside it the metrics would silently stay on the root
        volume of the guest that also runs the secret store.
      '';
    }];

    systemd.tmpfiles.rules = [
      "d ${obs.dataPath} 0755 root root -"
      "d ${obs.dataPath}/loki 0750 loki loki -"
      "d ${cfg.backup.stagingPath} 0700 root root -"
    ];
  };
}
