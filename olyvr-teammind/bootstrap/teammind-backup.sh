#!/usr/bin/env bash
# One backup set of this TeamMind server, sent to every target in BACKUP_TARGETS. Run by /etc/cron.d/teammind-backup
# as root, by the bootstrap once before it reports ready, and by teammind-restore after a restore:
#
#   teammind-backup [--verify]
#
# A set (docs/plans/teammind-backup-recovery.md, "What one backup holds") is the database dump and the portable state
# (Olyvr's store with the token rows, the vault key, the reader token, the memory server's settings and its
# self-signed pair), each encrypted with age to BACKUP_AGE_RECIPIENTS, and a manifest, encrypted too and signed with
# this host's key (/etc/olyvr/backup-sign). Host configuration (bootstrap.env, pg.env, server.env, TLS) is not in it:
# a restore keeps the target's own. Plain files exist only in a root-only work folder for the length of the run.
#
# The dump and the manifest's row counts come from one exported snapshot, so writes during the run can't make a
# valid dump fail its own count check. --verify (or the last check being 6 days old) restores the dump into a
# scratch database and compares the counts: the proof that it loads. The result goes to
# /var/lib/olyvr/backup-status.json, which teammind-check's readiness reads, and to BACKUP_PING_URL.
set -euo pipefail
# shellcheck disable=SC1091
. /etc/olyvr/bootstrap.env

STATE=/var/lib/olyvr/state
BACKUPS=/var/backups/teammind
STATUS=/var/lib/olyvr/backup-status.json
RCLONE_CONF=/etc/olyvr/rclone.conf
SIGN_KEY=/etc/olyvr/backup-sign
FILES=(db.dump.age state.tar.zst.age manifest.json.age manifest.json.age.sig SHA256SUMS)
VERIFY_EVERY_DAYS=6

# Not while a restore swaps databases, unless that restore is the caller (it takes this backup at its end).
exec 9>/run/lock/teammind-backup.lock
flock -n 9 || { echo "another backup is running" >&2; exit 1; }
if [ "${TEAMMIND_RESTORE_CALLER:-0}" != 1 ]; then
  exec 8>/run/lock/teammind-restore.lock
  flock -n 8 || { echo "a restore is running; not backing up a half-swapped server" >&2; exit 1; }
fi

verify=0; [ "${1:-}" = --verify ] && verify=1
host=$(hostname)
# Unique to the second; two runs in one second (a restore's backup right after another) wait for the next.
while :; do
  set_name="teammind-$host-$(date -u +%Y%m%dT%H%M%SZ)"
  [ -e "$BACKUPS/$set_name" ] || break
  sleep 1
done
read -r -a recipients <<< "${BACKUP_AGE_RECIPIENTS:-}"
[ ${#recipients[@]} -gt 0 ] || { echo "BACKUP_AGE_RECIPIENTS is empty: backups are never written unencrypted" >&2; exit 1; }
read -r -a targets <<< "${BACKUP_TARGETS:-}"

# The status file keeps the last full success and the last restore check across runs.
previous=$(cat "$STATUS" 2>/dev/null || echo '{}')
echo "$previous" | jq -e . >/dev/null 2>&1 || previous='{}'
restore_check=$(echo "$previous" | jq -c '.restore_check // null')
failed=()
targets_json='{}'
work=$(mktemp -d /var/lib/olyvr/backup-work.XXXXXX)   # root, 700: the only place plain files exist
scratch=""
finished=0
# On any exit: plain files go, a scratch database goes, and a run that died half way is still recorded and pinged
# as failed (finish), so a broken backup is never silent.
on_exit() {
  local rc=$?
  rm -rf "$work"
  [ -z "$scratch" ] || runuser -u postgres -- psql -X -q -c "DROP DATABASE IF EXISTS $scratch" >/dev/null 2>&1 || true
  if [ "$finished" = 0 ]; then failed+=("stopped (exit $rc)"); finish || true; exit 1; fi
}
trap on_exit EXIT

say() { echo "$(date -u +%FT%TZ) $*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# Every table's row count as "schema.table|count", sorted. The same query on both sides of a restore.
COUNTS_SQL="SELECT n.nspname || '.' || c.relname || '|' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%' ORDER BY 1;"
counts_of() { runuser -u postgres -- psql -X -q -At -v ON_ERROR_STOP=1 -d "$1" -c "$COUNTS_SQL"; }

# The dump and the counts from one snapshot: a psql session exports its snapshot, counts in it, and stays open
# while pg_dump --snapshot reads the same one; then it commits. Nothing stops writing meanwhile.
dump_with_counts() { # dump_with_counts DUMP COUNTS
  local snap line="" in out
  coproc PG { runuser -u postgres -- psql -X -q -At -v ON_ERROR_STOP=1 -d teammind 2>&1; }
  in=${PG[1]}; out=${PG[0]}
  printf '%s\n' 'BEGIN ISOLATION LEVEL REPEATABLE READ;' 'SELECT pg_export_snapshot();' >&"$in"
  read -r -t 60 snap <&"$out" || true
  [[ $snap =~ ^[0-9A-Fa-f]+(-[0-9A-Fa-f]+)+$ ]] || { echo "couldn't export a snapshot: $snap" >&2; return 1; }
  printf '%s\n' "$COUNTS_SQL" "SELECT '--end--';" >&"$in"
  : > "$2"
  while read -r -t 600 line <&"$out"; do
    [ "$line" = --end-- ] && break
    printf '%s\n' "$line" >> "$2"
  done
  [ "$line" = --end-- ] || { echo "the row counts didn't finish: $(tail -3 "$2")" >&2; return 1; }
  runuser -u postgres -- pg_dump -Fc --snapshot="$snap" teammind > "$1"
  printf '%s\n' 'COMMIT;' '\q' >&"$in"
  wait "$PG_PID"
}

# The scratch restore: the dump loads, and holds the rows the snapshot counted.
# Called inside `if`, where set -e is off, so every step says when it failed: a pg_restore that dies after the rows
# are in (on an index, say) must not pass on matching counts.
verify_restore() { # verify_restore DUMP COUNTS
  scratch="teammind_verify_$(date -u +%Y%m%d%H%M%S)"
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $scratch OWNER teammind" >/dev/null \
    || { echo "couldn't create $scratch" >&2; return 1; }
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d "$scratch" -c 'CREATE EXTENSION IF NOT EXISTS vector' >/dev/null \
    || { echo "couldn't create the vector extension in $scratch" >&2; return 1; }
  # The same pg_restore as teammind-restore runs: as the teammind role, without the extension's own entries (the
  # scratch database made it, and COMMENT ON EXTENSION is the owner's alone). A dump that passes here passes there.
  local list; list=$(mktemp) || return 1
  runuser -u postgres -- pg_restore -l < "$1" | grep -v -E ' (EXTENSION - |COMMENT - EXTENSION )' > "$list" \
    || { rm -f "$list"; echo "couldn't list the dump" >&2; return 1; }
  chown postgres "$list"
  runuser -u postgres -- pg_restore -d "$scratch" --no-owner --role=teammind --exit-on-error -L "$list" < "$1" \
    || { rm -f "$list"; echo "pg_restore into $scratch failed" >&2; return 1; }
  rm -f "$list"
  counts_of "$scratch" > "$work/verify.counts" || { echo "couldn't count the rows in $scratch" >&2; return 1; }
  diff -u "$2" "$work/verify.counts" >&2 || { echo "the restored rows differ from the snapshot's counts" >&2; return 1; }
  runuser -u postgres -- psql -X -q -c "DROP DATABASE $scratch" >/dev/null || return 1
  scratch=""
}

if [ "$verify" = 0 ]; then
  last=$(echo "$restore_check" | jq -r '.time // empty')
  if [ -z "$last" ] || [ $(( $(date +%s) - $(date -d "$last" +%s) )) -gt $((VERIFY_EVERY_DAYS * 86400)) ]; then verify=1; fi
fi

# Writes the status file and pings; returns 1 when anything failed.
finish() {
  local ok=true now url; now=$(date -u +%FT%TZ)
  finished=1
  [ ${#failed[@]} -eq 0 ] || ok=false
  jq -n --arg time "$now" --arg set "$set_name" --argjson ok "$ok" --argjson targets "$targets_json" \
    --argjson restore_check "$restore_check" --argjson previous "$previous" --arg errors "${failed[*]:-}" \
    --arg size "$(du -sb "$BACKUPS/$set_name" 2>/dev/null | cut -f1)" \
    '{time: $time, set: $set, ok: $ok, size: ($size | tonumber? // 0), targets: $targets, errors: $errors,
      last_success: (if $ok then {time: $time, set: $set} else ($previous | .last_success) end),
      restore_check: $restore_check}' > "$STATUS.tmp"
  mv "$STATUS.tmp" "$STATUS"
  if [ -n "${BACKUP_PING_URL:-}" ]; then
    url=$BACKUP_PING_URL; [ "$ok" = true ] || url="${BACKUP_PING_URL%/}/fail"
    curl -fsS -m 10 --retry 3 -o /dev/null "$url" || say "couldn't ping $url"
  fi
  if [ "$ok" = true ]; then say "set $set_name done"; else say "set $set_name FAILED: ${failed[*]}"; return 1; fi
}

# ---------- the database ----------
say "backing up as $set_name"
dump_with_counts "$work/db.dump" "$work/counts"
# Reads every block of the archive to the end (--list would read only its table of contents): a truncated or
# damaged dump fails here. Still a read, not a restore; verify_restore is the proof that it loads.
runuser -u postgres -- pg_restore --file=/dev/null < "$work/db.dump"
if [ "$verify" = 1 ]; then
  if verify_restore "$work/db.dump" "$work/counts"; then
    restore_check=$(jq -nc --arg time "$(date -u +%FT%TZ)" --arg set "$set_name" '{time: $time, set: $set, ok: true}')
  else
    restore_check=$(jq -nc --arg time "$(date -u +%FT%TZ)" --arg set "$set_name" '{time: $time, set: $set, ok: false}')
    failed+=("restore-check")
  fi
fi

# ---------- the portable state ----------
mkdir -p "$work/state/state/memory/tls" "$work/state/etc"
# sqlite3's online backup, not cp: a consistent copy while Olyvr writes to it.
sqlite3 "$STATE/olyvr.sqlite3" ".backup '$work/state/state/olyvr.sqlite3'"
for f in credential.key vault.id memory/config.json memory/tls/gate.key memory/tls/gate.crt; do
  [ ! -f "$STATE/$f" ] || cp -p "$STATE/$f" "$work/state/state/$f"
done
[ -f "$work/state/state/credential.key" ] || { echo "no $STATE/credential.key: the vault key isn't in a file (OLYVR_VAULT=file)" >&2; exit 1; }
[ ! -f /etc/olyvr/teammind-token ] || cp -p /etc/olyvr/teammind-token "$work/state/etc/teammind-token"
tar -C "$work/state" -cf - . | zstd -q -o "$work/state.tar.zst"

# ---------- encrypt, manifest, sign ----------
age_args=(); for r in "${recipients[@]}"; do age_args+=(-r "$r"); done
out="$work/out"; mkdir -m 700 "$out"
age -e "${age_args[@]}" -o "$out/db.dump.age" "$work/db.dump"
age -e "${age_args[@]}" -o "$out/state.tar.zst.age" "$work/state.tar.zst"
IFS='|' read -r pg_version vector_version < <(runuser -u postgres -- psql -X -At -F '|' -d teammind \
  -c "SELECT current_setting('server_version'), (SELECT extversion FROM pg_extension WHERE extname = 'vector')")
jq -R 'split("|") | {(.[0]): (.[1] | tonumber)}' "$work/counts" | jq -s 'add // {}' > "$work/counts.json"
jq -n --arg set "$set_name" --arg created "$(date -u +%FT%TZ)" --arg host "$host" --arg machine "$(cat /etc/machine-id)" \
  --arg olyvr "$OLYVR_SOURCE_COMMIT" --arg memory "$MEMORY_SOURCE_COMMIT" --arg release "$MEMORY_RELEASE" \
  --arg pg "$pg_version" --arg vector "$vector_version" --slurpfile counts "$work/counts.json" \
  --arg db_plain "$(sha "$work/db.dump")" --arg db_size "$(stat -c %s "$work/db.dump")" --arg db_age "$(sha "$out/db.dump.age")" \
  --arg st_plain "$(sha "$work/state.tar.zst")" --arg st_size "$(stat -c %s "$work/state.tar.zst")" --arg st_age "$(sha "$out/state.tar.zst.age")" \
  --arg cloud "$CLOUD" --arg domain "${DOMAIN:-}" --arg ip "${PUBLIC_IP:-}" --arg port "${GATE_PORT:-}" --arg tls "${TLS_MODE:-}" \
  --arg targets "${BACKUP_TARGETS:-}" \
  '{format: 1, set: $set, created: $created, host: $host, machine_id: $machine,
    versions: {olyvr_commit: $olyvr, memory_commit: $memory, memory_release: $release, postgresql: $pg, pgvector: $vector},
    files: {"db.dump": {sha256: $db_plain, size: ($db_size | tonumber), age_sha256: $db_age},
            "state.tar.zst": {sha256: $st_plain, size: ($st_size | tonumber), age_sha256: $st_age}},
    counts: $counts[0],
    source_config: {cloud: $cloud, domain: $domain, public_ip: $ip, gate_port: $port, tls_mode: $tls, backup_targets: $targets}}' \
  > "$work/manifest.json"
age -e "${age_args[@]}" -o "$out/manifest.json.age" "$work/manifest.json"
ssh-keygen -q -Y sign -f "$SIGN_KEY" -n teammind-backup "$out/manifest.json.age"
(cd "$out" && sha256sum db.dump.age state.tar.zst.age manifest.json.age manifest.json.age.sig > SHA256SUMS)

# Into place in one rename, readable by the pull user's group; a half-built set is never visible to it.
chgrp -R teammind-pull "$out"; chmod 750 "$out"; chmod 640 "$out"/*
mv -T "$out" "$BACKUPS/.$set_name"            # may cross file systems: a copy, under a name the pull skips
mv -T "$BACKUPS/.$set_name" "$BACKUPS/$set_name"
dir="$BACKUPS/$set_name"
say "set written: $(du -sh "$dir" | cut -f1)"

# ---------- push ----------
rc=(--config "$RCLONE_CONF" --no-check-dest --no-traverse --s3-no-check-bucket --s3-no-head --gcs-bucket-policy-only
    --retries 3 --low-level-retries 5 -q)
push() { # push REMOTE:PATH
  local remote=${1%%:*} path=${1#*:} type dest f
  type=$(rclone --config "$RCLONE_CONF" config dump | jq -r --arg r "$remote" '.[$r].type // empty')
  case $type in
    "") echo "no remote named $remote in $RCLONE_CONF" >&2; return 1 ;;
    sftp)
      # Flat names in one existing folder, written in place: the restricted SFTP server refuses mkdir and rename.
      for f in "${FILES[@]}"; do
        rclone copyto "${rc[@]}" --inplace "$dir/$f" "$remote:${path:+${path%/}/}$set_name.$f" || return 1
      done ;;
    *)
      # The trailing slash says it's a folder: without it rclone asks whether the path is an object, which
      # --s3-no-head and a write-only identity can't answer, so it refuses the copy as "a file".
      dest="$remote:${path:+${path%/}/}$set_name/"
      rclone copy "${rc[@]}" "$dir" "$dest" ;;
  esac
}
for t in "${targets[@]}"; do
  if err=$(push "$t" 2>&1); then
    targets_json=$(echo "$targets_json" | jq -c --arg t "$t" '.[$t] = "ok"')
    say "pushed to $t"
  else
    targets_json=$(echo "$targets_json" | jq -c --arg t "$t" --arg e "$err" '.[$t] = $e')
    failed+=("$t")
    say "push to $t FAILED: $err"
  fi
done

# The local copy is the only thing this host prunes; destinations keep their own retention.
find "$BACKUPS" -mindepth 1 -maxdepth 1 -name 'teammind-*' -mtime +7 -exec rm -rf {} +
finish
