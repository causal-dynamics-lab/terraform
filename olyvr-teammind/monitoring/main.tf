# Alerts for TeamMind servers in Grafana Cloud: a folder, the PagerDuty contact point, one rule group over the
# metrics and logs Alloy sends from each server (bootstrap/teammind-monitoring.sh), and one Synthetic Monitoring
# check per server that calls its gate from outside. A root of its own, like backups/, so it covers every server,
# Terraform-made or hand-built. docs/teammind-monitoring.md has the plan; README.md ("Monitoring") the keys.
#
# Rules route to the contact point through their own notification settings, so the stack's notification policy tree,
# which other teams may use, is never touched.

terraform {
  required_version = ">= 1.9"
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }
}

provider "grafana" {
  url             = var.grafana_url
  auth            = var.grafana_auth
  sm_url          = var.sm_url
  sm_access_token = var.sm_access_token
}

data "grafana_data_source" "prometheus" {
  name = var.prometheus_data_source
}

data "grafana_data_source" "loki" {
  name = var.loki_data_source
}

data "grafana_synthetic_monitoring_probes" "all" {}

resource "grafana_folder" "this" {
  title = var.folder
}

resource "grafana_contact_point" "pagerduty" {
  name = "${var.folder} PagerDuty"
  pagerduty {
    integration_key = var.pagerduty_integration_key
    # PagerDuty's severities include critical and warning, the two the rules use.
    severity  = "{{ if .CommonLabels.severity }}{{ .CommonLabels.severity }}{{ else }}critical{{ end }}"
    class     = "teammind"
    component = "{{ .CommonLabels.teammind_server }}"
    summary   = "{{ .CommonLabels.alertname }} on {{ if .CommonLabels.teammind_server }}{{ .CommonLabels.teammind_server }}{{ else }}{{ .CommonLabels.instance }}{{ end }}"
  }
}

locals {
  # Each rule: a PromQL (or LogQL) instant query A, fired when A <op> threshold holds for `for`. Every query
  # aggregates by teammind_server, the label Alloy puts on every series, so one rule covers every server.
  rules = {
    TeamMindHostDown = {
      # The newest node sample in a day, so a server that went silent keeps its label (an absent series has none).
      # Silent for over a day: no data, which this rule also treats as firing.
      expr    = "time() - max by (teammind_server) (max_over_time(timestamp(node_boot_time_seconds{job=\"teammind/node\"})[1d:1m]))"
      op      = "gt", threshold = 300, for = "0s", severity = "critical", no_data = "Alerting"
      summary = "No metrics from {{ $labels.teammind_server }} for {{ humanizeDuration $values.A.Value }}: the VM or Alloy is down."
      runbook = "Is the VM running? Then: systemctl status alloy; journalctl -u alloy."
    }
    TeamMindUnhealthy = {
      expr    = "max by (teammind_server) (1 - teammind_health)"
      op      = "gt", threshold = 0, for = "3m", severity = "critical", no_data = "OK"
      summary = "teammind-check --health fails on {{ $labels.teammind_server }}."
      runbook = "sudo teammind-check --health (or cat /run/teammind-check.last); journalctl -u olyvr."
    }
    OlyvrServiceDown = {
      expr    = "max by (teammind_server) (1 - node_systemd_unit_state{name=\"olyvr.service\", state=\"active\"})"
      op      = "gt", threshold = 0, for = "2m", severity = "critical", no_data = "OK"
      summary = "olyvr.service isn't active on {{ $labels.teammind_server }}."
      runbook = "systemctl status olyvr; journalctl -u olyvr -n 200."
    }
    PostgresDown = {
      # Only servers whose PostgreSQL is the host's own (the Terraform-made ones) have this unit.
      expr    = "max by (teammind_server) (1 - node_systemd_unit_state{name=\"postgresql@16-main.service\", state=\"active\"})"
      op      = "gt", threshold = 0, for = "2m", severity = "critical", no_data = "OK"
      summary = "PostgreSQL isn't active on {{ $labels.teammind_server }}."
      runbook = "systemctl status postgresql@16-main; journalctl -u postgresql@16-main."
    }
    OlyvrRestartLoop = {
      expr    = "max by (teammind_server) (increase(node_systemd_service_restart_total{name=\"olyvr.service\"}[15m]))"
      op      = "gt", threshold = 3, for = "0s", severity = "warning", no_data = "OK"
      summary = "olyvr.service restarted {{ $values.A.Value }} times in 15 minutes on {{ $labels.teammind_server }}."
      runbook = "journalctl -u olyvr -n 300: what it dies of."
    }
    TeamMindCollectStale = {
      expr    = "time() - max by (teammind_server) (teammind_collect_timestamp_seconds)"
      op      = "gt", threshold = 300, for = "0s", severity = "warning", no_data = "OK"
      summary = "teammind-monitoring collect hasn't run for {{ humanizeDuration $values.A.Value }} on {{ $labels.teammind_server }}: the health metrics are stale."
      runbook = "systemctl status teammind-collect.timer teammind-collect.service."
    }
    TeamMindNotReady = {
      expr    = "max by (teammind_server) (1 - teammind_ready)"
      op      = "gt", threshold = 0, for = "1h", severity = "warning", no_data = "OK"
      summary = "{{ $labels.teammind_server }} is healthy but not ready: a backup or a restore check is overdue, or secrets need rotating."
      runbook = "sudo teammind-check lists the reasons; /var/log/teammind-backup.log."
    }
    DiskLow = {
      expr    = "min by (teammind_server) (node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100"
      op      = "lt", threshold = 15, for = "10m", severity = "warning", no_data = "OK"
      summary = "{{ $labels.teammind_server }}'s root disk has {{ printf \"%.1f\" $values.A.Value }}% free."
      runbook = "du -xh / | sort -h | tail; /var/backups/teammind keeps a week of sets."
    }
    DiskCritical = {
      expr    = "min by (teammind_server) (node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100"
      op      = "lt", threshold = 5, for = "5m", severity = "critical", no_data = "OK"
      summary = "{{ $labels.teammind_server }}'s root disk has {{ printf \"%.1f\" $values.A.Value }}% free: PostgreSQL stops writing when it fills."
      runbook = "Free space now, or grow the disk (disk_gb)."
    }
    MemoryLow = {
      expr    = "min by (teammind_server) (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100"
      op      = "lt", threshold = 10, for = "10m", severity = "warning", no_data = "OK"
      summary = "{{ $labels.teammind_server }} has {{ printf \"%.1f\" $values.A.Value }}% memory available."
      runbook = "ps aux --sort=-rss | head; a bigger machine_type."
    }
    CPUHigh = {
      expr    = "100 * (1 - avg by (teammind_server) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))"
      op      = "gt", threshold = 90, for = "15m", severity = "warning", no_data = "OK"
      summary = "{{ $labels.teammind_server }}'s CPU is {{ printf \"%.0f\" $values.A.Value }}% busy."
      runbook = "top; a burst of ingests or searches, or a runaway process."
    }
    TeamMindCertExpiring = {
      expr    = "min by (teammind_server) (teammind_gate_cert_expiry_timestamp_seconds - time()) / 86400"
      op      = "lt", threshold = 14, for = "1h", severity = "warning", no_data = "OK"
      summary = "The gate's certificate on {{ $labels.teammind_server }} expires in {{ printf \"%.0f\" $values.A.Value }} days."
      runbook = "letsencrypt: certbot renew --dry-run, port 80 open? provided: put a new pair in tls_secret and rerun the bootstrap."
    }
    TeamMindGateUnreachable = {
      # Synthetic Monitoring: the share of probes whose call to the gate got its 401 in the last 5 minutes.
      expr    = "avg by (instance) (avg_over_time(probe_success{job=\"${var.check_job}\"}[5m]))"
      op      = "lt", threshold = 0.5, for = "5m", severity = "critical", no_data = "OK"
      summary = "{{ $labels.instance }} doesn't answer from outside (under half of the probes get its 401)."
      runbook = "From a laptop: teammind-check <url> <token>. The firewall (reader_cidrs must let the probes in), DNS, the certificate."
    }
  }

  log_rules = {
    OlyvrErrorBurst = {
      expr    = "sum by (teammind_server) (count_over_time({job=~\"teammind/(journal|memory)\"} |~ \"ERROR|Traceback\" [5m]))"
      op      = "gt", threshold = 20, for = "0s", severity = "warning", no_data = "OK"
      summary = "{{ $values.A.Value }} ERROR or Traceback lines in 5 minutes on {{ $labels.teammind_server }}."
      runbook = "Explore, Loki: {teammind_server=\"…\", job=~\"teammind/.*\"} |~ \"ERROR|Traceback\"."
    }
  }

  all_rules = merge(
    { for k, r in local.rules : k => merge(r, { uid = data.grafana_data_source.prometheus.uid, model = { expr = r.expr, instant = true, range = false } }) },
    { for k, r in local.log_rules : k => merge(r, { uid = data.grafana_data_source.loki.uid, model = { expr = r.expr, queryType = "instant" } }) },
  )
}

resource "grafana_rule_group" "this" {
  name             = "teammind"
  folder_uid       = grafana_folder.this.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.all_rules
    content {
      name           = rule.key
      condition      = "C"
      for            = rule.value.for
      no_data_state  = rule.value.no_data
      exec_err_state = "Error"
      labels         = { severity = rule.value.severity }
      annotations = {
        summary = rule.value.summary
        runbook = rule.value.runbook
      }
      notification_settings {
        contact_point = grafana_contact_point.pagerduty.name
        group_by      = ["alertname", "teammind_server", "instance"]
      }

      data {
        ref_id         = "A"
        datasource_uid = rule.value.uid
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode(merge(rule.value.model, { refId = "A" }))
      }
      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "A"
          datasource = { type = "__expr__", uid = "__expr__" }
          conditions = [{ evaluator = { type = rule.value.op, params = [rule.value.threshold] } }]
        })
      }
    }
  }
}

# The outside check: a reader's call without a token, which a healthy gate answers 401.
resource "grafana_synthetic_monitoring_check" "gate" {
  for_each  = var.servers
  job       = var.check_job
  target    = each.value.url
  enabled   = true
  frequency = 60000
  timeout   = 10000
  probes    = [for p in var.probes : data.grafana_synthetic_monitoring_probes.all.probes[p]]
  labels    = { teammind_server = each.key }

  settings {
    http {
      method             = "GET"
      valid_status_codes = [401]
      fail_if_not_ssl    = true
      tls_config {
        # A self-signed gate is pinned by its readers; the probe can only skip the check. Its expiry is then
        # TeamMindCertExpiring's, from the VM.
        insecure_skip_verify = each.value.self_signed
      }
    }
  }
}
