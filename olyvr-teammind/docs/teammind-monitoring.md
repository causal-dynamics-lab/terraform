# Plan: monitoring and alerts for a TeamMind server

**Status:** Approved 2026-11-18; built on `feat/olyvr-teammind-monitoring`
**Related:** `../README.md` ("Monitoring"), `teammind-backup-recovery.md` ("Health and readiness"),
`teammind-terraform-setup.md`.

A TeamMind server is one VM: PostgreSQL, Olyvr headless, the memory API and its gate. Today nobody hears about
it going down until a reader does. This plan sends the VM's telemetry and logs to Grafana Cloud, checks the gate
from outside, and pages through PagerDuty.

## Decisions

| Question | Decision |
| --- | --- |
| Where telemetry goes | Grafana Cloud (Prometheus for metrics, Loki for logs) |
| Where alerts go | PagerDuty, one Events API v2 integration; `severity` label critical or warning |
| The VM's write token | In the cloud's secret store, read by name, like every other secret on the VM. The one secret (`grafana_secret`) holds the whole connection, URLs and IDs too: each extra variable costs user data, and AWS caps that at 16 KiB |
| Logs | Yes, to Loki |
| An outside check | Yes: Grafana Synthetic Monitoring calls the gate the way a reader does |

## Keys, made by hand

| Key | Made in | Scope | Goes to |
| --- | --- | --- | --- |
| Access policy token | Grafana Cloud portal → Access Policies | `metrics:write`, `logs:write` | `GRAFANA_TOKEN` in the `grafana_secret` secret, beside the stack's Prometheus and Loki URLs and IDs; `/etc/olyvr/grafana.env` on a hand-built VM |
| Service account token | the stack's Grafana → Administration → Service accounts | Editor | `grafana_auth` in `olyvr-teammind/monitoring/terraform.tfvars` |
| Synthetic Monitoring token | the stack's Grafana → Testing & synthetics → Config | (its own) | `sm_access_token` in the same tfvars |
| PagerDuty integration key | PagerDuty → the service → Integrations → Events API v2 | (its own) | `pagerduty_integration_key` in the same tfvars |

Tfvars files are git-ignored. Provider settings never reach the state file; the PagerDuty key does (it is an
attribute of the contact point), so the root's state goes to a private GCS bucket like the other roots'.

## On the VM: Grafana Alloy

`bootstrap.sh` gains a `monitoring` step, run when `grafana_secret` is set. It copies the secret to
`/etc/olyvr/grafana.env` and runs `teammind-monitoring install`, which takes the server's name, cloud, port and
domain from `bootstrap.env`. That script comes from the bundle like the backup tools (the user data has about 1 KiB
left under CI's 15 KiB limit). It also runs by hand on a VM that Terraform didn't make, such as dogfood, with
`/etc/olyvr/monitoring.env` in place of `bootstrap.env`.

`teammind-monitoring install`:

- Installs Alloy from its GitHub release, pinned and checked against the release's `SHA256SUMS`, as rclone is.
  It runs as its own `alloy` user, with read access granted by ACL to the logs it ships and nothing else.
- Writes `/etc/alloy/config.alloy`:
  - **VM telemetry** (`prometheus.exporter.unix`): CPU, load, memory, disk space and I/O, network, uptime.
  - **Units** (systemd collector): `olyvr`, `postgresql@16-main`, `alloy`.
  - **TeamMind** (textfile collector): `teammind-monitoring collect`, every minute from a systemd timer.
  - **Logs** to Loki: the journal of those units, the memory API's `server.log` and `install.log`, the
    bootstrap and backup logs.
  - Every series and stream carries `teammind_server` (the Terraform `name`, or the hostname) and `cloud`.

`teammind-monitoring collect` runs `teammind-check` (readiness when the backup tools are installed, health
otherwise) and writes:

| Metric | Meaning |
| --- | --- |
| `teammind_health` | 1 healthy, 0 unhealthy (`teammind-check --health`) |
| `teammind_ready` | 1 ready, 0 not (only where backups are set up, so dogfood never shows "not ready") |
| `teammind_backup_last_success_timestamp_seconds` | from `backup-status.json` |
| `teammind_restore_check_timestamp_seconds` | from `backup-status.json` |
| `teammind_gate_cert_expiry_timestamp_seconds` | the certificate the gate serves on 127.0.0.1 |
| `teammind_collect_timestamp_seconds` | when this ran, so a stuck timer shows |

## In Grafana: `olyvr-teammind/monitoring/`

A root of its own, like `backups/`, so it covers every server, Terraform-made or not. It makes a folder, the
PagerDuty contact point, the rule group, and one Synthetic Monitoring HTTP check per server. Rules route to the
contact point through their own notification settings, so the stack's notification policy tree is never touched.

| Alert | Fires when | Severity |
| --- | --- | --- |
| TeamMindHostDown | no metrics from a server for 5 minutes | critical |
| TeamMindUnhealthy | `teammind_health` 0 for 3 minutes | critical |
| OlyvrServiceDown | `olyvr.service` not active for 2 minutes | critical |
| PostgresDown | `postgresql@16-main.service` not active for 2 minutes | critical |
| TeamMindGateUnreachable | the outside check fails from most probes for 5 minutes | critical |
| TeamMindCollectStale | `teammind-monitoring collect` hasn't run for 5 minutes | warning |
| TeamMindNotReady | `teammind_ready` 0 for 1 hour (backup or restore check overdue) | warning |
| DiskLow | root filesystem under 15% free (warning), under 5% (critical) | both |
| MemoryLow | available memory under 10% for 10 minutes | warning |
| CPUHigh | CPU busy over 90% for 15 minutes | warning |
| TeamMindCertExpiring | the gate's certificate expires within 14 days | warning |
| OlyvrRestartLoop | systemd restarted `olyvr.service` more than 3 times in 15 minutes (`NRestarts`) | warning |
| OlyvrErrorBurst | more than 20 ERROR or Traceback lines in 5 minutes (Loki) | warning |

The outside check calls `https://<domain>:<port>/collections` every minute and expects 401 (no token). It catches
what the VM can't see of itself: the firewall, DNS, a lapsed certificate, the public address. The probes' addresses
must be inside `reader_cidrs`.

## Rollout

1. The test server (`atiqur-test-01`): rerun the bootstrap with the new variables; apply `monitoring/`; stop
   `olyvr` and see TeamMindUnhealthy and OlyvrServiceDown page; start it and see them resolve. The server needs a
   bundle staged from this branch: older bundles have no `teammind-monitoring.sh`.
2. Read what `server.log` and the `olyvr` journal hold before trusting Loki with them: search text there is the
   team's content. Drop such lines in Alloy if any.
3. dogfood (`olyvr-memory`, hand-built, no Secret Manager): copy `teammind-check.sh` and `teammind-monitoring.sh`
   to `/usr/local/bin`, write `/etc/olyvr/session-token` (from `OLYVR_SESSION_TOKEN` in `olyvr.env`),
   `/etc/olyvr/monitoring.env` and `/etc/olyvr/grafana.env` by hand, run `teammind-monitoring install`; check that
   its firewall lets the probes in. Its PostgreSQL runs in Docker, so PostgresDown never fires there;
   TeamMindUnhealthy covers it.

## Out of scope

- Grafana dashboards beyond what Grafana Cloud's Linux integration gives.
- The search-latency percentiles in `olyvr_search_log` (a PostgreSQL data source can chart them later).
- Alerting on the backup dead-man's switch: `backup_ping_url` already does that outside Grafana.
