#!/usr/bin/env bash
# Restore a backup set onto this server (olyvr-teammind/docs/teammind-backup-recovery.md, "Restore"):
#
#   teammind-unpack.py ./<set> | ssh <admin>@<ip> sudo teammind-restore [--db-only] [--sanitize] [--allow-version-skew] -
#   sudo teammind-restore /path/to/teammind-Mon.dump        # a plain dump from before backup sets: the database only
#   sudo teammind-restore --rotation-done                   # after a --sanitize restore, once every secret is rotated
#
# The set arrives decrypted on stdin from teammind-unpack, which checked its signature on the operator's machine (this
# host has no private key); every plaintext digest is checked again here. Three stages, the server up until the third:
#
# 1. Stage: the dump into a scratch database (counts compared with the manifest's), the state into a staging folder,
#    checked (store integrity, its schema not newer than this Olyvr's, the vault key opens the vault, the gate pair).
#    Any failure: the scratch database and the folder go; nothing on the server changed.
# 2. Swap: Olyvr stopped, the databases renamed, each state file moved aside as <file>.before_<time> and the staged one
#    moved in. Host configuration (bootstrap.env, pg.env, server.env, the session token, TLS, and the port, domain and
#    certificate fields of config.json) is never replaced: this server keeps its own.
# 3. Start: Olyvr started and `teammind-check --health` waited for. If it doesn't pass, everything moved is put back and
#    the old database renamed back, and the server is started as it was. Readiness (a backup, the rotation) is not part
#    of this decision; a successful restore takes a backup at once.
#
# --sanitize, for a host that was compromised: the vault key is kept (a new one would orphan every sealed row) but every
# vault row is deleted and every restored reader token revoked; new tokens are made and the gate keeps this host's own
# certificate. The secrets the old host could read are listed in /var/lib/olyvr/rotation-required, and the server is
# not ready (teammind-check exits 2) until --rotation-done.
set -euo pipefail
# shellcheck disable=SC1091
. /etc/olyvr/bootstrap.env

STATE=/var/lib/olyvr/state
API=http://127.0.0.1:9420
ROTATION=/var/lib/olyvr/rotation-required
PY=/usr/bin/python3   # with python3-cryptography (bootstrap.sh, packages), which the vault uses
HEALTH_SECONDS=${TEAMMIND_HEALTH_SECONDS:-600}

db_only=0; sanitize=0; skew=0; rotation_done=0; input=""
for a in "$@"; do
  case $a in
    --db-only) db_only=1 ;;
    --sanitize) sanitize=1 ;;
    --allow-version-skew) skew=1 ;;
    --rotation-done) rotation_done=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    -) input=- ;;
    -*) echo "unknown option $a" >&2; exit 1 ;;
    *) input=$a ;;
  esac
done

exec 8>/run/lock/teammind-restore.lock
flock -n 8 || { echo "another restore is running" >&2; exit 1; }

session() { cat /etc/olyvr/session-token; }
api() { curl -fsS -m 30 -H "Authorization: Bearer $(session)" -H 'Content-Type: application/json' "$@"; }
psql_admin() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }
backup_now() { TEAMMIND_RESTORE_CALLER=1 /usr/local/bin/teammind-backup || echo "the backup after the restore failed: the server is healthy but not ready until one succeeds (teammind-check)" >&2; }

# ---------- --rotation-done ----------
if [ "$rotation_done" = 1 ]; then
  [ -f "$ROTATION" ] || { echo "nothing to confirm: no $ROTATION"; exit 0; }
  exec 3<>/dev/tty || { echo "needs a terminal to confirm each secret (ssh -t)" >&2; exit 1; }
  while IFS= read -r line; do
    case $line in "- "*) ;; *) continue ;; esac
    printf '%s\n  rotated? [y/N] ' "$line" >&3
    read -r answer <&3
    case $answer in y|Y|yes) ;; *) echo "not confirmed; the server stays not ready" >&2; exit 1 ;; esac
  done < "$ROTATION"
  echo "rotation confirmed $(date -u +%FT%TZ) by ${SUDO_USER:-root}" >> /var/log/teammind-restore.log
  rm -f "$ROTATION"
  backup_now
  exit 0
fi

[ -n "$input" ] || { echo "usage: teammind-restore [--db-only] [--sanitize] [--allow-version-skew] - | <file.dump>" >&2; exit 1; }
stamp=$(date -u +%Y%m%d%H%M%S)
stage=/var/lib/olyvr/restore-$stamp
scratch=teammind_restore_$stamp
before=teammind_before_$stamp
install -d -m 700 "$stage" "$stage/in"
stopped=0; swapped=0; finished=0; rolling=0
moved=()   # live paths moved aside as <path>.before_<stamp>
added=()   # live paths that didn't exist before the swap
# Before the swap an exit leaves the server untouched (the scratch database goes). Between stopping Olyvr and the
# swap (the renames are one transaction, so they either both happened or neither did) an exit starts Olyvr again on
# the old database. After the swap, any exit that isn't the end of a healthy restore rolls back, so the server is never
# left half swapped. A --sanitize restore keeps its rotation marker on every failure, a rollback included: the compromise
# it answers happened whether or not this restore stuck, so the rotation is owed either way.
on_exit() {
  local rc=$?
  rm -rf "$stage"
  if [ "$swapped" = 0 ]; then
    psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$scratch'" >/dev/null 2>&1 || true
    psql_admin -c "DROP DATABASE IF EXISTS $scratch" >/dev/null 2>&1 || true
    if [ "$stopped" = 1 ]; then
      echo "stopped (exit $rc) before the swap; starting olyvr again on the old database" >&2
      systemctl start olyvr || true
    fi
  elif [ "$finished" = 0 ] && [ "$rolling" = 0 ]; then
    echo "stopped (exit $rc) after the swap" >&2
    rollback
  fi
}
trap on_exit EXIT

healthy() {
  local end=$((SECONDS + HEALTH_SECONDS))
  until /usr/local/bin/teammind-check --health >/dev/null 2>&1; do
    [ $SECONDS -lt $end ] || return 1
    sleep 10
  done
}
rollback() {
  rolling=1
  set +e   # best effort from here: put back everything that can be
  echo "rolling back to the server as it was" >&2
  systemctl stop olyvr
  local live
  for live in "${added[@]}"; do rm -f "$live"; done
  for live in "${moved[@]}"; do rm -f "$live"; mv "$live.before_$stamp" "$live"; done
  # The restored store's write-ahead log, which the health check's server made, must not be replayed onto the old
  # store. A clean stop usually leaves none (SQLite checkpoints and removes them), so these are rarely in `moved`.
  rm -f "$STATE/olyvr.sqlite3-wal" "$STATE/olyvr.sqlite3-shm"
  psql_admin <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'teammind' AND pid <> pg_backend_pid();
ALTER DATABASE teammind RENAME TO teammind_failed_$stamp;
ALTER DATABASE $before RENAME TO teammind;
SQL
  rm -rf "$STATE/memory/data/tantivy-postgres"
  systemctl start olyvr
  if healthy; then
    echo "rolled back; the server is healthy as before. The failed restore's database is teammind_failed_$stamp" >&2
  else
    echo "rolled back, but the server isn't healthy either: teammind-check --health, journalctl -u olyvr" >&2
  fi
  exit 1
}

# ---------- input ----------
manifest=""
if [ "$input" = - ]; then
  tar -x -C "$stage/in" -f - manifest.json db.dump state.tar.zst \
    || { echo "no complete set on stdin: pipe teammind-unpack's output in (nothing changed)" >&2; exit 1; }
  manifest=$stage/in/manifest.json
  for f in db.dump state.tar.zst; do
    [ "$db_only" = 0 ] || [ "$f" = db.dump ] || continue
    [ -f "$stage/in/$f" ] || { echo "the stream ended before $f" >&2; exit 1; }
    [ "$(sha256sum "$stage/in/$f" | cut -d' ' -f1)" = "$(jq -r --arg f "$f" '.files[$f].sha256' "$manifest")" ] \
      || { echo "$f doesn't match the manifest's digest; nothing changed" >&2; exit 1; }
  done
  set_name=$(jq -r .set "$manifest")
  # The Olyvr build: the set's (olyvr_commit in sets from before bundles) against this host's bundle.
  theirs=$(jq -r '.versions.olyvr_version // .versions.olyvr_commit // "unknown"' "$manifest")
  mine=$(sed -n 's/^olyvr_version=//p' /opt/olyvr/bundle/BUNDLE 2>/dev/null || true)
  if [ "$theirs" != "${mine:-unknown}" ] && [ "$skew" = 0 ]; then
    echo "the set was made by Olyvr $theirs; this server runs ${mine:-an unknown version}. Bootstrap from a bundle" >&2
    echo "of $theirs, restore, then upgrade; or pass --allow-version-skew" >&2; exit 1
  fi
  echo "restoring $set_name (made $(jq -r .created "$manifest") on $(jq -r .host "$manifest"))"
elif [ -f "$input" ] && [ "$(head -c 5 "$input")" = PGDMP ]; then
  cp "$input" "$stage/in/db.dump"; db_only=1; set_name=$(basename "$input")
  echo "restoring the plain dump $set_name: the database only"
else
  echo "$input is neither - (a set from teammind-unpack) nor a pg_dump custom-format file" >&2; exit 1
fi

# ---------- 1. stage ----------
echo "staging the database as $scratch (the server keeps running)"
psql_admin -c "CREATE DATABASE $scratch OWNER teammind"
psql_admin -d "$scratch" -c 'CREATE EXTENSION IF NOT EXISTS vector'
# The extension's own entries are left out: the scratch database made it already, and only its owner (postgres) may
# comment on it, so restoring them as teammind fails.
list=$(mktemp)
runuser -u postgres -- pg_restore -l < "$stage/in/db.dump" | grep -v -E ' (EXTENSION - |COMMENT - EXTENSION )' > "$list"
chown postgres "$list"   # after writing: in sticky /tmp, root may not write to a file postgres owns
runuser -u postgres -- pg_restore -d "$scratch" --no-owner --role=teammind --exit-on-error -L "$list" < "$stage/in/db.dump" \
  || { rm -f "$list"; echo "pg_restore failed; nothing changed" >&2; exit 1; }
rm -f "$list"
if [ -n "$manifest" ]; then
  COUNTS_SQL="SELECT n.nspname || '.' || c.relname || '|' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%' ORDER BY 1;"
  runuser -u postgres -- psql -X -q -At -d "$scratch" -c "$COUNTS_SQL" > "$stage/restored.counts"
  jq -r '.counts | to_entries | sort_by(.key)[] | "\(.key)|\(.value)"' "$manifest" > "$stage/manifest.counts"
  diff -u "$stage/manifest.counts" "$stage/restored.counts" >&2 \
    || { echo "the restored rows differ from the manifest's counts; nothing changed" >&2; exit 1; }
fi

# staged path -> live path; filled below
pairs=()
if [ "$db_only" = 0 ]; then
  echo "staging the state"
  mkdir -p "$stage/state"
  zstd -q -d -c "$stage/in/state.tar.zst" | tar -x -C "$stage/state"
  s=$stage/state/state
  for f in olyvr.sqlite3 credential.key memory/config.json; do
    [ -f "$s/$f" ] || { echo "the set's state has no $f; nothing changed" >&2; exit 1; }
  done
  # The store opens and is sound, its schema is one this Olyvr knows, the vault key opens its vault; --sanitize
  # deletes the vault rows and revokes the token rows in the staged copy, before anything is live.
  "$PY" - "$s/olyvr.sqlite3" "$STATE/olyvr.sqlite3" "$s/credential.key" "$sanitize" <<'PY'
import json, sqlite3, sys, time
from cryptography.fernet import Fernet, InvalidToken
staged, live, keyfile, sanitize = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
db = sqlite3.connect(staged)
if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
    sys.exit("the set's store fails its integrity check")
def version(conn):
    try:
        return conn.execute("SELECT coalesce(max(version), 0) FROM migrations").fetchone()[0]
    except sqlite3.Error:
        return 0
mine = version(sqlite3.connect(f"file:{live}?mode=ro", uri=True))
if version(db) > mine:
    sys.exit(f"the set's store is at schema {version(db)}, newer than this Olyvr's {mine}: upgrade first")
key = Fernet(open(keyfile, "rb").read().strip())
rows = [r[0] for r in db.execute("SELECT body FROM entities WHERE kind = 'secret'")]
opened = 0
for body in rows:
    try:
        key.decrypt(json.loads(body)["sealed"].encode())
        opened += 1
    except (InvalidToken, ValueError, KeyError):
        pass
if rows and not opened:
    sys.exit(f"the set's vault key opens none of its {len(rows)} vault rows")
print(f"store ok: schema {version(db)}, {opened}/{len(rows)} vault rows open")
if sanitize:
    n = db.execute("DELETE FROM entities WHERE kind = 'secret'").rowcount
    tokens = []
    for ident, body in db.execute("SELECT id, body FROM entities WHERE kind = 'memory_token'").fetchall():
        row = json.loads(body)
        if not row.get("revoked"):
            row.update(revoked=True, revoked_at=time.time())
            tokens.append((json.dumps(row), ident))
    db.executemany("UPDATE entities SET body = ? WHERE kind = 'memory_token' AND id = ?", tokens)
    db.commit()
    print(f"sanitized: {n} vault rows deleted, {len(tokens)} reader tokens revoked")
db.close()
PY
  # Settings from the set; the port, domain, certificate paths, and the enabled, shared and public switches stay this
  # host's (shared is whether the gate runs: health needs it, and a set from a host that had it off must not turn
  # this one off, nor the reverse).
  jq -s '.[0] * (.[1] | with_entries(select(.key as $k | ["enabled", "shared", "port", "public", "domain", "cert_file", "key_file"] | index($k))))' \
    "$s/memory/config.json" "$STATE/memory/config.json" > "$s/memory/config.json.merged"
  mv "$s/memory/config.json.merged" "$s/memory/config.json"
  pairs+=("$s/olyvr.sqlite3|$STATE/olyvr.sqlite3" "$s/credential.key|$STATE/credential.key" "$s/memory/config.json|$STATE/memory/config.json")
  [ ! -f "$s/vault.id" ] || pairs+=("$s/vault.id|$STATE/vault.id")
  # The gate's self-signed pair travels only when this host is self-signed and the pair names this host's address.
  crt=$s/memory/tls/gate.crt; key=$s/memory/tls/gate.key
  if [ "$sanitize" = 0 ] && [ "$TLS_MODE" = self_signed ] && [ -f "$crt" ] && [ -f "$key" ]; then
    if [ -n "${DOMAIN:-}" ]; then check=(-checkhost "$DOMAIN"); else check=(-checkip "$PUBLIC_IP"); fi
    if openssl x509 -in "$crt" -noout "${check[@]}" | grep -q 'does match' \
       && [ "$(openssl x509 -in "$crt" -pubkey -noout)" = "$(openssl pkey -in "$key" -pubout)" ]; then
      pairs+=("$crt|$STATE/memory/tls/gate.crt" "$key|$STATE/memory/tls/gate.key")
      echo "the gate keeps the set's certificate: readers needn't pin again"
    else
      echo "the set's gate certificate doesn't name ${DOMAIN:-$PUBLIC_IP}; this host keeps its own (readers pin it again)"
    fi
  fi
  if [ "$sanitize" = 0 ] && [ -f "$stage/state/etc/teammind-token" ]; then
    pairs+=("$stage/state/etc/teammind-token|/etc/olyvr/teammind-token")
  fi
  chown -R olyvr:olyvr "$s"; find "$s" -type f -exec chmod 600 {} +
  [ ! -f "$stage/state/etc/teammind-token" ] || { chown root:root "$stage/state/etc/teammind-token"; chmod 600 "$stage/state/etc/teammind-token"; }
fi

# ---------- 2. swap ----------
echo "stopping olyvr and swapping"
systemctl stop olyvr
stopped=1
# One transaction: the two renames happen together or not at all, so a failure here leaves the old database in place
# and on_exit starts Olyvr on it.
psql_admin --single-transaction <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'teammind' AND pid <> pg_backend_pid();
ALTER DATABASE teammind RENAME TO $before;
ALTER DATABASE $scratch RENAME TO teammind;
SQL
swapped=1
aside() { # aside LIVE: move it out of the way, remembered for a rollback
  if [ -e "$1" ]; then mv "$1" "$1.before_$stamp"; moved+=("$1"); else added+=("$1"); fi
}
for p in "${pairs[@]}"; do
  staged=${p%%|*}; live=${p#*|}
  aside "$live"
  mkdir -p "$(dirname "$live")"
  mv "$staged" "$live"
done
if [ "$db_only" = 0 ]; then
  # A write-ahead log of the old store must not be replayed into the restored one. Usually none: a clean stop
  # checkpoints and removes them.
  for f in "$STATE/olyvr.sqlite3-wal" "$STATE/olyvr.sqlite3-shm"; do [ ! -e "$f" ] || { mv "$f" "$f.before_$stamp"; moved+=("$f"); }; done
fi
# The lexical index is derived from the database and keyed by the connection, so it would be the old data's.
rm -rf "$STATE/memory/data/tantivy-postgres"
if [ "$sanitize" = 1 ]; then
  # Written before the sanitized server starts, so from here no failure leaves it reporting ready. The new tokens are
  # added below once they exist.
  cat > "$ROTATION" <<EOF
# Restored from $set_name with --sanitize on $(date -u +%FT%TZ). The old host could read these; rotate each, then
# run: sudo teammind-restore --rotation-done
- llm_key_secret (${LLM_KEY_SECRET:-none}): revoke the model endpoint's key, store a new one
- backup_remote_secret (${BACKUP_REMOTE_SECRET:-none}): replace every credential in it at its destination
- tls_secret (${TLS_SECRET:-none}) or the Let's Encrypt certificate: replace the key pair (certbot revoke for Let's Encrypt)
- the old host's backup signing key: remove it from allowed_signers, or keep it only for sets made before the compromise
- the old host's ssh host key: remove it from known_hosts files that trust it
- readers: every restored token was revoked; new ones are not made yet (the restore didn't get that far: run it again, or POST {"action":"token","slot":"primary"} to the local API)
EOF
  chmod 600 "$ROTATION"
fi

# ---------- 3. start, health, rollback ----------
echo "starting olyvr; waiting up to $((HEALTH_SECONDS / 60)) minutes for teammind-check --health"
systemctl start olyvr
if ! healthy; then
  /usr/local/bin/teammind-check --health >&2 || true
  rollback
fi
finished=1
echo "healthy on the restored data"

if [ "$sanitize" = 1 ]; then
  for slot in primary secondary; do
    out=$(api -X POST -d "{\"action\":\"token\",\"slot\":\"$slot\"}" "$API/api/memory-server") \
      || { echo "couldn't make the $slot token; the server stays not ready ($ROTATION)" >&2; exit 1; }
    tok=$(echo "$out" | jq -r '.token // empty')
    [ -n "$tok" ] || { echo "couldn't make the $slot token: $out; the server stays not ready ($ROTATION)" >&2; exit 1; }
    [ "$slot" != primary ] || (umask 077; printf '%s\n' "$tok" > /etc/olyvr/teammind-token)
  done
  unset tok
  sed -i '$d' "$ROTATION"
  echo "- readers: hand out the new token (sudo cat /etc/olyvr/teammind-token); every restored token was revoked" >> "$ROTATION"
  echo "SANITIZED: new reader tokens made; the server is not ready until the secrets in $ROTATION are rotated"
fi

backup_now
echo "restored $set_name. When happy, drop what the restore kept aside:"
echo "  sudo -u postgres psql -c 'DROP DATABASE $before'"
for live in "${moved[@]}"; do echo "  sudo rm $live.before_$stamp"; done
