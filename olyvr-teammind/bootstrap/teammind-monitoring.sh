#!/usr/bin/env bash
# Sends a TeamMind server's metrics and logs to Grafana Cloud through Grafana Alloy
# (olyvr-teammind/docs/teammind-monitoring.md). Installed as /usr/local/bin/teammind-monitoring by bootstrap.sh (step 10) when
# GRAFANA_SECRET is set, or copied to a hand-built VM and run there.
#
#   teammind-monitoring install   install or update Alloy, its config and the collect timer; idempotent
#   teammind-monitoring collect   run teammind-check and write the teammind_* metrics (the timer, every minute)
#
# Reads the Grafana Cloud connection from /etc/olyvr/grafana.env, mode 600: the value of the grafana_secret secret,
# which bootstrap.sh copies there (on a hand-built VM, write it yourself). Lines of KEY=value, parsed, never sourced:
#
#   GRAFANA_METRICS_URL=https://prometheus-….grafana.net/api/prom/push
#   GRAFANA_METRICS_USER=123456                 the Prometheus instance ID
#   GRAFANA_LOGS_URL=https://logs-….grafana.net/loki/api/v1/push
#   GRAFANA_LOGS_USER=654321                    the Loki user ID
#   GRAFANA_TOKEN=glc_…                         an access policy token with metrics:write and logs:write
#
# The rest comes from /etc/olyvr/bootstrap.env (NAME, CLOUD, GATE_PORT, DOMAIN), then /etc/olyvr/monitoring.env if it
# exists, which a hand-built VM uses instead (root-owned, sourced):
#
#   TEAMMIND_SERVER=dogfood   the teammind_server label on every series and stream (default: NAME, else the hostname)
#   CLOUD=gcp                 the cloud label
#   GATE_PORT=8013            the gate, for its certificate's expiry
#   DOMAIN=dogfood.olyvr.ai   the name the gate's certificate is for (empty: none)
set -euo pipefail

GRAFANA_ENV=/etc/olyvr/grafana.env
ALLOY_VERSION="${ALLOY_VERSION:-1.22.0}"
# alloy-linux-amd64.zip's line in the release's SHA256SUMS.
ALLOY_SHA256="${ALLOY_SHA256:-62d177feb18c9b6ffd636c8273aa82a6afc75a507d096ff951749df23c3176f9}"
ALLOY_ETC=/etc/alloy
ALLOY_LIB=/var/lib/alloy
TEXTFILE=$ALLOY_LIB/textfile
MEMORY_LOGS=(/var/lib/olyvr/state/memory/server.log /var/lib/olyvr/state/memory/install.log)

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
# shellcheck disable=SC1091
[ ! -f /etc/olyvr/bootstrap.env ] || . /etc/olyvr/bootstrap.env
# shellcheck disable=SC1091
[ ! -f /etc/olyvr/monitoring.env ] || . /etc/olyvr/monitoring.env
TEAMMIND_SERVER="${TEAMMIND_SERVER:-${NAME:-$(hostname)}}"
: "${CLOUD:?set CLOUD in /etc/olyvr/monitoring.env}" "${GATE_PORT:?set GATE_PORT in /etc/olyvr/monitoring.env}"
DOMAIN="${DOMAIN:-}"

# One KEY=value from grafana.env, refused unless it is letters, digits and . _ : / @ + = - only: it goes into Alloy's
# config inside a quoted string.
grafana() {
  local v
  v=$(sed -n "s/^[[:space:]]*$1=//p" "$GRAFANA_ENV" | tail -1 | tr -d '\r')
  [[ $v =~ ^[A-Za-z0-9._:/@+=-]+$ ]] || { echo "$GRAFANA_ENV: $1 is missing or has characters outside A-Za-z0-9._:/@+=-" >&2; return 1; }
  printf '%s' "$v"
}

# Alloy reads the memory API's logs through ACLs on exactly these paths: execute on the directories, read on the
# files. No default ACL: server.env sits beside them and holds the database password. copytruncate keeps the inode,
# so a rotation keeps the ACL; collect reapplies it for a file that appears later.
grant_logs() {
  id -u alloy >/dev/null 2>&1 || return 0
  local f d
  for f in "${MEMORY_LOGS[@]}"; do
    [ -f "$f" ] || continue
    d=$(dirname "$f")
    while [ "$d" != /var/lib ]; do setfacl -m u:alloy:x "$d"; d=$(dirname "$d"); done
    setfacl -m u:alloy:r "$f"
  done
}

collect() {
  local out=$TEXTFILE/teammind.prom tmp health=0 ready="" rc status t sni
  tmp=$(mktemp "$TEXTFILE/.teammind.XXXXXX")
  # Readiness only where the backup tools are installed (a hand-built VM without them would never be "ready").
  if [ -x /usr/local/bin/teammind-backup ]; then
    rc=0; /usr/local/bin/teammind-check > /run/teammind-check.last 2>&1 || rc=$?
    case $rc in 0) health=1; ready=1 ;; 2) health=1; ready=0 ;; *) health=0; ready=0 ;; esac
  else
    rc=0; /usr/local/bin/teammind-check --health > /run/teammind-check.last 2>&1 || rc=$?
    [ "$rc" = 0 ] && health=1
  fi
  {
    echo "# HELP teammind_health 1 when teammind-check --health passes."
    echo "# TYPE teammind_health gauge"
    echo "teammind_health $health"
    if [ -n "$ready" ]; then
      echo "# HELP teammind_ready 1 when teammind-check reports ready (backups and restore checks current)."
      echo "# TYPE teammind_ready gauge"
      echo "teammind_ready $ready"
    fi
    status=$(cat /var/lib/olyvr/backup-status.json 2>/dev/null || echo '{}')
    t=$(echo "$status" | jq -r '.last_success.time // empty')
    if [ -n "$t" ]; then
      echo "# TYPE teammind_backup_last_success_timestamp_seconds gauge"
      echo "teammind_backup_last_success_timestamp_seconds $(date -d "$t" +%s)"
    fi
    t=$(echo "$status" | jq -r 'if .restore_check.ok == true then .restore_check.time else empty end')
    if [ -n "$t" ]; then
      echo "# TYPE teammind_restore_check_timestamp_seconds gauge"
      echo "teammind_restore_check_timestamp_seconds $(date -d "$t" +%s)"
    fi
    sni=(); [ -z "$DOMAIN" ] || sni=(-servername "$DOMAIN")
    t=$(timeout 10 openssl s_client -connect "127.0.0.1:$GATE_PORT" "${sni[@]}" </dev/null 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    if [ -n "$t" ]; then
      echo "# HELP teammind_gate_cert_expiry_timestamp_seconds When the certificate the gate serves expires."
      echo "# TYPE teammind_gate_cert_expiry_timestamp_seconds gauge"
      echo "teammind_gate_cert_expiry_timestamp_seconds $(date -d "$t" +%s)"
    fi
    echo "# TYPE teammind_collect_timestamp_seconds gauge"
    echo "teammind_collect_timestamp_seconds $(date +%s)"
  } > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$out"
  grant_logs
}

# Alloy's config. The Grafana values are checked by grafana(); NAME and the rest by the server roots' variables'
# validation (or the operator, on a hand-built VM).
write_config() {
  local inst; inst=$(hostname)
  cat <<ALLOY
// Written by teammind-monitoring install from /etc/olyvr/grafana.env and bootstrap.env (or monitoring.env).
local.file "token" {
  filename  = "$ALLOY_ETC/grafana-token"
  is_secret = true
}

// ---------- metrics ----------
prometheus.exporter.unix "node" {
  enable_collectors = ["systemd"]
  systemd {
    unit_include    = "(olyvr|postgresql@16-main|alloy|teammind-collect)\\\\.service"
    enable_restarts = true
  }
  textfile {
    directory = "$TEXTFILE"
  }
}

prometheus.scrape "node" {
  targets         = prometheus.exporter.unix.node.targets
  job_name        = "teammind/node"
  scrape_interval = "60s"
  forward_to      = [prometheus.remote_write.grafana.receiver]
}

prometheus.remote_write "grafana" {
  external_labels = {
    teammind_server = "$TEAMMIND_SERVER",
    cloud           = "$CLOUD",
  }
  endpoint {
    url = "$GRAFANA_METRICS_URL"
    basic_auth {
      username = "$GRAFANA_METRICS_USER"
      password = local.file.token.content
    }
  }
}

// ---------- logs ----------
loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}

loki.source.journal "units" {
  matches       = "_SYSTEMD_UNIT=olyvr.service _SYSTEMD_UNIT=postgresql@16-main.service _SYSTEMD_UNIT=alloy.service"
  max_age       = "12h"
  relabel_rules = loki.relabel.journal.rules
  labels        = { job = "teammind/journal", instance = "$inst" }
  forward_to    = [loki.write.grafana.receiver]
}

local.file_match "logs" {
  path_targets = [
    { __path__ = "${MEMORY_LOGS[0]}", job = "teammind/memory", instance = "$inst" },
    { __path__ = "${MEMORY_LOGS[1]}", job = "teammind/memory-install", instance = "$inst" },
    { __path__ = "/var/log/teammind-bootstrap.log", job = "teammind/bootstrap", instance = "$inst" },
    { __path__ = "/var/log/teammind-backup.log", job = "teammind/backup", instance = "$inst" },
  ]
}

loki.source.file "logs" {
  targets    = local.file_match.logs.targets
  forward_to = [loki.write.grafana.receiver]
}

loki.write "grafana" {
  external_labels = {
    teammind_server = "$TEAMMIND_SERVER",
    cloud           = "$CLOUD",
  }
  endpoint {
    url = "$GRAFANA_LOGS_URL"
    basic_auth {
      username = "$GRAFANA_LOGS_USER"
      password = local.file.token.content
    }
  }
}
ALLOY
}

install_all() {
  [ -f "$GRAFANA_ENV" ] || { echo "$GRAFANA_ENV is missing (see the top of $0)" >&2; exit 1; }
  GRAFANA_METRICS_URL=$(grafana GRAFANA_METRICS_URL); GRAFANA_METRICS_USER=$(grafana GRAFANA_METRICS_USER)
  GRAFANA_LOGS_URL=$(grafana GRAFANA_LOGS_URL); GRAFANA_LOGS_USER=$(grafana GRAFANA_LOGS_USER)
  local token; token=$(grafana GRAFANA_TOKEN)
  [ -x /usr/local/bin/teammind-check ] || { echo "teammind-check isn't installed in /usr/local/bin" >&2; exit 1; }
  local need=() changed=0 tmp
  for p in unzip:unzip setfacl:acl jq:jq; do command -v "${p%%:*}" >/dev/null || need+=("${p#*:}"); done
  [ ${#need[@]} -eq 0 ] || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${need[@]}"; }

  # Alloy, pinned and checked against the release's digest.
  if [ ! -x /usr/local/bin/alloy ] || ! /usr/local/bin/alloy --version 2>/dev/null | grep -q "v$ALLOY_VERSION "; then
    tmp=$(mktemp -d)
    curl -fsSLo "$tmp/alloy.zip" "https://github.com/grafana/alloy/releases/download/v$ALLOY_VERSION/alloy-linux-amd64.zip"
    echo "$ALLOY_SHA256  $tmp/alloy.zip" | sha256sum -c --quiet
    unzip -q "$tmp/alloy.zip" -d "$tmp"
    install -m 755 "$tmp/alloy-linux-amd64" /usr/local/bin/alloy
    rm -rf "$tmp"
    changed=1
  fi

  id -u alloy >/dev/null 2>&1 || useradd -r -M -d "$ALLOY_LIB" -s /usr/sbin/nologin alloy
  install -d -o alloy -g alloy -m 750 "$ALLOY_LIB" "$ALLOY_LIB/data"
  install -d -o root -g alloy -m 755 "$TEXTFILE"
  install -d -o root -g alloy -m 750 "$ALLOY_ETC"
  tmp=$(mktemp); printf '%s' "$token" > "$tmp"; unset token
  if ! cmp -s "$tmp" "$ALLOY_ETC/grafana-token"; then
    install -o root -g alloy -m 640 "$tmp" "$ALLOY_ETC/grafana-token"; changed=1
  fi
  rm -f "$tmp"
  tmp=$(mktemp); write_config > "$tmp"
  if ! cmp -s "$tmp" "$ALLOY_ETC/config.alloy"; then
    install -o root -g alloy -m 640 "$tmp" "$ALLOY_ETC/config.alloy"; changed=1
  fi
  rm -f "$tmp"
  /usr/local/bin/alloy fmt "$ALLOY_ETC/config.alloy" >/dev/null || { echo "Alloy refuses $ALLOY_ETC/config.alloy" >&2; exit 1; }

  tmp=$(mktemp)
  cat > "$tmp" <<UNIT
[Unit]
Description=Grafana Alloy: TeamMind metrics and logs to Grafana Cloud
After=network-online.target
Wants=network-online.target

[Service]
User=alloy
Group=alloy
# The journal; the memory API's logs through ACLs (teammind-monitoring); /var/log's world-readable ones.
SupplementaryGroups=systemd-journal adm
ExecStart=/usr/local/bin/alloy run --storage.path=$ALLOY_LIB/data --server.http.listen-addr=127.0.0.1:12345 --disable-reporting $ALLOY_ETC/config.alloy
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$ALLOY_LIB

[Install]
WantedBy=multi-user.target
UNIT
  if ! cmp -s "$tmp" /etc/systemd/system/alloy.service; then install -m 644 "$tmp" /etc/systemd/system/alloy.service; changed=1; fi
  cat > /etc/systemd/system/teammind-collect.service <<UNIT
[Unit]
Description=TeamMind health and readiness for Alloy (teammind-monitoring collect)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/teammind-monitoring collect
TimeoutStartSec=50
UNIT
  cat > /etc/systemd/system/teammind-collect.timer <<UNIT
[Unit]
Description=Run teammind-monitoring collect every minute

[Timer]
OnCalendar=minutely
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
  rm -f "$tmp"
  systemctl daemon-reload
  systemctl enable -q --now teammind-collect.timer
  collect   # the first metrics, and the log ACLs, before Alloy starts
  systemctl enable -q alloy
  if [ "$changed" = 1 ] || ! systemctl is-active -q alloy; then systemctl restart alloy; fi
  # Alloy up and every component healthy (a bad URL or token shows as an unhealthy remote_write after a scrape).
  local end=$((SECONDS + 90))
  until curl -fsS -m 5 http://127.0.0.1:12345/-/ready >/dev/null 2>&1; do
    [ $SECONDS -lt $end ] || { echo "Alloy isn't ready: journalctl -u alloy" >&2; journalctl -u alloy -n 30 --no-pager >&2; exit 1; }
    sleep 3
  done
  echo "monitoring: Alloy $ALLOY_VERSION sends $TEAMMIND_SERVER's metrics and logs to Grafana Cloud"
}

case "${1:-}" in
  install) install_all ;;
  collect) collect ;;
  *) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
