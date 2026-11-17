#!/usr/bin/env bash
# Smoke test. On the VM, two levels (docs/plans/teammind-backup-recovery.md, "Health and readiness"):
#
#   teammind-check --health   the application: the backend, the memory API on PostgreSQL with its model, the gate
#                             serving and refusing a request without a token. What a restore's rollback decides on.
#   teammind-check            readiness: health, plus no secret rotation outstanding, a fully successful backup within
#                             BACKUP_MAX_AGE_HOURS, and a passing restore check within 8 days.
#
# Exit 0 healthy/ready, 1 unhealthy, 2 healthy but not ready (with the reasons).
#
# From a laptop: teammind-check https://host:8013 <token> [gate.crt]: /health, /collections with and without the
# token. A self-signed gate (the default) is pinned, as readers do: give its certificate (the host's
# /var/lib/olyvr/state/memory/tls/gate.crt), or none to fetch it from the server and print its SHA-256 fingerprint
# to compare with the one the host's Settings → Server pane shows.
set -euo pipefail
if [ $# -eq 0 ] || [ "$1" = --health ]; then
  health_only=0; [ "${1:-}" = --health ] && health_only=1
  SESSION=$(sudo cat /etc/olyvr/session-token)
  s=$(curl -fsS -m 10 -H "Authorization: Bearer $SESSION" http://127.0.0.1:9420/api/memory-server) \
    || { echo "UNHEALTHY: the backend doesn't answer on 127.0.0.1:9420"; exit 1; }
  # Which bundle the server runs, when it runs one (teammind-stage.sh).
  if [ "$health_only" = 0 ] && sudo grep -q "^ARTIFACTS='.\+'" /etc/olyvr/bootstrap.env; then
    echo "bundle: $(sudo cat /opt/olyvr/bundle/BUNDLE 2>/dev/null | tr '\n' ' ')"
  fi
  [ "$health_only" = 1 ] || echo "$s" | jq '{running, installed, storage, storage_backend, storage_error, llm, shared, shared_port, domain, gate, start_error}'
  [ "$(echo "$s" | jq -r '[.running, .storage_backend, .llm, .gate.running] | @tsv')" = "true	postgres	true	true" ] \
    || { echo "UNHEALTHY: $(echo "$s" | jq -c '{running, storage_backend, llm, gate: .gate.running, storage_error, start_error}')"; exit 1; }
  port=$(echo "$s" | jq -r '.shared_port // .gate.port // empty')
  code=$(curl -ksS -m 10 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$port/collections" || true)
  [ "$code" = 401 ] || { echo "UNHEALTHY: the gate on $port answered $code without a token, not 401"; exit 1; }
  if [ "$health_only" = 1 ]; then echo HEALTHY; exit 0; fi

  reasons=()
  max_hours=$(sudo bash -c '. /etc/olyvr/bootstrap.env; echo "${BACKUP_MAX_AGE_HOURS:-26}"')
  if sudo test -f /var/lib/olyvr/rotation-required; then
    reasons+=("secrets to rotate after a --sanitize restore (sudo cat /var/lib/olyvr/rotation-required; then sudo teammind-restore --rotation-done)")
  fi
  status=$(sudo cat /var/lib/olyvr/backup-status.json 2>/dev/null || echo '{}')
  hours_since() { echo $(( ($(date +%s) - $(date -d "$1" +%s)) / 3600 )); }
  last=$(echo "$status" | jq -r '.last_success.time // empty')
  if [ -z "$last" ]; then
    reasons+=("no successful backup yet (sudo teammind-backup; log /var/log/teammind-backup.log)")
  elif [ "$(hours_since "$last")" -ge "$max_hours" ]; then
    reasons+=("last successful backup $(hours_since "$last") h ago, over $max_hours h (/var/log/teammind-backup.log)")
  fi
  [ "$(echo "$status" | jq -r '.ok // true')" = true ] || echo "warning: the last backup run failed: $(echo "$status" | jq -r .errors)"
  check=$(echo "$status" | jq -r '.restore_check | if . == null then "" else "\(.time) \(.ok)" end')
  if [ -z "$check" ]; then
    reasons+=("no restore check yet (sudo teammind-backup --verify)")
  elif [ "${check#* }" != true ]; then
    reasons+=("the last restore check failed (${check% *}): the dump didn't load or its rows differ")
  elif [ "$(hours_since "${check% *}")" -ge $((8 * 24)) ]; then
    reasons+=("the last restore check is $(( $(hours_since "${check% *}") / 24 )) days old")
  fi
  if [ ${#reasons[@]} -gt 0 ]; then
    echo "HEALTHY, NOT READY:"; printf '  - %s\n' "${reasons[@]}"; exit 2
  fi
  echo "READY (last backup $(echo "$status" | jq -r .last_success.set))"; exit 0
fi
BASE=${1%/}; TOKEN=$2; CERT=${3:-}
hostport=${BASE#https://}; hostport=${hostport%%/*}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pin=()
if ! curl -fsS -o /dev/null -H "Authorization: Bearer $TOKEN" "$BASE/health" 2>/dev/null; then
  # The system's CAs refuse it (self-signed), so pin the certificate's public key, as readers do.
  if [ -z "$CERT" ]; then
    openssl s_client -connect "$hostport" -servername "${hostport%%:*}" </dev/null 2>/dev/null | openssl x509 > "$tmp/gate.crt"
    CERT=$tmp/gate.crt
    echo "no certificate given; using the server's, with fingerprint $(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2)"
    echo "compare it with the one the host's Settings → Server pane shows"
  fi
  openssl x509 -in "$CERT" -pubkey -noout > "$tmp/gate.pub"
  pin=(--insecure --pinnedpubkey "$tmp/gate.pub")
fi
c() { curl "${pin[@]}" "$@"; }
c -fsS -o /dev/null -w "/health %{http_code}\n" -H "Authorization: Bearer $TOKEN" "$BASE/health"
code=$(c -sS -o /dev/null -w '%{http_code}' "$BASE/collections"); echo "/collections without a token: $code"; [ "$code" = 401 ]
c -fsS -H "Authorization: Bearer $TOKEN" "$BASE/collections" | head -c 300; echo
c -fsS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"query":"zzqx-nothing-matches","collection":"default"}' "$BASE/retrieve" | head -c 300; echo
echo OK
