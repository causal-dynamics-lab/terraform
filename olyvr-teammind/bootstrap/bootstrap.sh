#!/usr/bin/env bash
# Sets up one TeamMind server on a bare Ubuntu 24.04 VM: PostgreSQL 16 with pgvector, Olyvr headless (the public
# AppImage of OLYVR_TRACK, or a staged bundle's: ARTIFACTS, below), the memory server on PostgreSQL behind its gate, TLS, the reader token, backups (encrypted sets to
# BACKUP_TARGETS, olyvr-teammind/docs/teammind-backup-recovery.md).
# Run by cloud-init as root with /etc/olyvr/bootstrap.env written first (olyvr-teammind/<cloud>), or by hand:
#
#   sudo /opt/olyvr/bootstrap.sh
#
# Every step keeps a marker in /var/lib/olyvr/bootstrap/<step>.done holding a digest of the inputs it used, so a
# rerun redoes only the steps whose inputs changed (olyvr-teammind/docs/teammind-terraform-setup.md, "Rerun"). Ends by
# writing /var/lib/olyvr/teammind-ready (the URL inside) or /var/lib/olyvr/teammind-failed; the log is
# /var/log/teammind-bootstrap.log.
set -euo pipefail

ENV_FILE=/etc/olyvr/bootstrap.env
LOG=/var/log/teammind-bootstrap.log
MARKS=/var/lib/olyvr/bootstrap
READY=/var/lib/olyvr/teammind-ready
FAILED=/var/lib/olyvr/teammind-failed
OLYVR_HOME=/opt/olyvr
APP=$OLYVR_HOME/app                     # Olyvr unpacked from its AppImage: backend/, workspace/
OLYVR_RELEASE=$OLYVR_HOME/olyvr-release # which AppImage that was: version, track, where from
TOOLS=$OLYVR_HOME/tools                 # the bundle's backup tools
BUNDLE=$OLYVR_HOME/bundle               # the bundle's SHA256SUMS
MEMORY_SRC=$OLYVR_HOME/reasonara-memory # the memory API: the bundle's compiled archive
DROPIN=/etc/systemd/system/olyvr.service.d/appimage.conf  # older bootstraps' ExecStart override; removed
STATE=/var/lib/olyvr/state
OLYVR_ENV=/etc/olyvr/olyvr.env
PG_ENV=/etc/olyvr/pg.env
TLS_DIR=/etc/olyvr/tls
TOKEN_FILE=/etc/olyvr/teammind-token
BACKEND_PORT=9420
API=http://127.0.0.1:$BACKEND_PORT

exec > >(tee -a "$LOG") 2>&1
echo "== teammind bootstrap $(date -u +%FT%TZ)"

# shellcheck disable=SC1090
. "$ENV_FILE"
: "${CLOUD:?}" "${MEMORY_RELEASE:?}" "${LLM_BASE_URL:?}" "${LLM_MODEL:?}" "${TLS_MODE:?}" "${GATE_PORT:?}"
# Where Olyvr and the memory API come from: a staged bundle (ARTIFACTS, a folder made by operator/teammind-stage.sh,
# pinned by the SHA-256 of its SHA256SUMS). OLYVR_TRACK (beta, stable) takes Olyvr from that track's public AppImage
# instead, the newest at each run; memory API releases are for licensed Olyvrs only, so that stays in the bundle.
OLYVR_TRACK="${OLYVR_TRACK:-}"
OLYVR_UPDATES_URL="${OLYVR_UPDATES_URL:-https://olyvr.ai/updates}"
case $OLYVR_TRACK in
  ""|beta|stable) ;;
  *) echo "OLYVR_TRACK is beta, stable or empty (the bundle's AppImage), not '$OLYVR_TRACK'" >&2; exit 1 ;;
esac
: "${ARTIFACTS:?ARTIFACTS names the staged bundle (operator/teammind-stage.sh)}"
: "${ARTIFACTS_SHA256:?ARTIFACTS needs the SHA-256 of its SHA256SUMS}"
: "${BACKUP_BUCKET:?}" "${PUBLIC_IP:?}" "${BACKUP_AGE_RECIPIENTS:?backups are never written unencrypted}"
DOMAIN="${DOMAIN:-}"; ACME_EMAIL="${ACME_EMAIL:-}"; TLS_SECRET="${TLS_SECRET:-}"; LLM_KEY_SECRET="${LLM_KEY_SECRET:-}"
UV_VERSION="${UV_VERSION:-0.12.18}"
AWSCLI_VERSION="${AWSCLI_VERSION:-2.32.0}"
GCP_PROJECT="${GCP_PROJECT:-}"; AZURE_VAULT="${AZURE_VAULT:-}"
# rclone pushes the backup sets; Ubuntu's own (1.60) predates --inplace, which SFTP targets need. Checked against the
# digest in rclone's SHA256SUMS for this release.
RCLONE_VERSION="${RCLONE_VERSION:-1.75.2}"
RCLONE_SHA256="${RCLONE_SHA256:-349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702}"
BACKUP_TARGETS="${BACKUP_TARGETS:-}"; BACKUP_REMOTE_SECRET="${BACKUP_REMOTE_SECRET:-}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-15 3 * * *}"; PULL_SSH_PUBLIC_KEY="${PULL_SSH_PUBLIC_KEY:-}"

mkdir -p "$MARKS" /etc/olyvr "$TLS_DIR"
# Root only, except that the olyvr group may pass through to tls/ (users step): the gate reads its pair there.
chmod 710 /etc/olyvr
rm -f "$READY" "$FAILED"
# shellcheck disable=SC2154  # rc is set inside the trap
trap 'rc=$?; if [ $rc -ne 0 ]; then echo "== bootstrap FAILED (exit $rc) near line ${BASH_LINENO[0]}"; date -u +%FT%TZ > "$FAILED"; fi' EXIT

# ---------- helpers ----------

digest() { printf '%s' "$*" | sha256sum | cut -c1-16; }
# done STEP DIGEST: true when the step's marker holds this digest.
is_done() { [ -f "$MARKS/$1.done" ] && [ "$(cat "$MARKS/$1.done")" = "$2" ]; }
mark() { echo "$2" > "$MARKS/$1.done"; }
step() { echo "-- $*"; }

# A secret by name from the cloud's secret store, through the instance's identity (no CLI but aws). The identity's
# role may still be propagating when cloud-init runs (Azure assigns it after the VM exists; every cloud's IAM is
# eventually consistent), so a refusal is retried for up to ten minutes.
read_secret() {
  local name=$1 value end=$((SECONDS + 600))
  until value=$(read_secret_once "$name"); do
    [ $SECONDS -lt $end ] || { echo "couldn't read secret $name in ten minutes (is the VM's identity allowed to?)" >&2; return 1; }
    echo "secret $name not readable yet (the identity's access may still be propagating); retrying" >&2
    sleep 20
  done
  printf '%s' "$value"
}
# The GCP service account's token; fails on an empty or null one.
gcp_token() {
  local t
  t=$(curl -fsS -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r .access_token) || return 1
  case $t in '' | null) echo "no metadata token" >&2; return 1 ;; esac
  printf '%s' "$t"
}
read_secret_once() {
  local name=$1 tok
  case $CLOUD in
    gcp)
      tok=$(gcp_token) || return 1
      curl -fsS -H "Authorization: Bearer $tok" \
        "https://secretmanager.googleapis.com/v1/projects/$GCP_PROJECT/secrets/$name/versions/latest:access" \
        | jq -r .payload.data | base64 -d ;;
    aws)
      aws secretsmanager get-secret-value --secret-id "$name" --query SecretString --output text ;;
    azure)
      tok=$(curl -fsS -H Metadata:true 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' | jq -r .access_token)
      curl -fsS -H "Authorization: Bearer $tok" "https://$AZURE_VAULT.vault.azure.net/secrets/$name?api-version=7.4" | jq -r .value ;;
    *) echo "unknown CLOUD=$CLOUD" >&2; return 1 ;;
  esac
}

# A bundle file into DEST, checked against SHA256SUMS (itself against ARTIFACTS_SHA256); retried like read_secret,
# unless fetch_artifact_once returns 2 (a scheme this cloud can't read).
fetch_artifact() {
  local name=$1 dest=$2 end=$((SECONDS + 600)) want
  until fetch_artifact_once "$name" "$dest"; do
    [ $? -ne 2 ] || return 1
    [ $SECONDS -lt $end ] || { echo "couldn't fetch $ARTIFACTS/$name in ten minutes (is the VM's identity allowed to read it?)" >&2; return 1; }
    echo "$ARTIFACTS/$name not readable yet; retrying" >&2
    sleep 20
  done
  if [ "$name" = SHA256SUMS ]; then want=$ARTIFACTS_SHA256; else want=$(awk -v f="$name" '$2 == f || $2 == "*" f {print $1}' "$BUNDLE/SHA256SUMS"); fi
  [ -n "$want" ] || { echo "$name isn't listed in $ARTIFACTS/SHA256SUMS" >&2; return 1; }
  [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ] || { rm -f "$dest"; echo "$ARTIFACTS/$name doesn't match its SHA-256" >&2; return 1; }
}
# OLYVR_TRACK's newest public AppImage into $1, checked against the SHA-512 in the track's feed; sets FEED_VERSION.
fetch_public_appimage() {
  local feed="$OLYVR_UPDATES_URL/feed/$OLYVR_TRACK/latest-linux.yml" body url sha end=$((SECONDS + 600))
  key() { printf '%s\n' "$body" | sed -n "s/^$1: *'\{0,1\}\([^']*\)'\{0,1\} *$/\1/p" | head -n1; }  # top level only
  until body=$(curl -fsSL -m 30 "$feed"); do
    [ $SECONDS -lt $end ] || { echo "couldn't read $feed" >&2; return 1; }
    sleep 20
  done
  FEED_VERSION=$(key version); url=$(key path); sha=$(key sha512)
  case $url in https://*) [ -n "$FEED_VERSION" ] && [ -n "$sha" ] ;; *) false ;; esac || { echo "$feed: no AppImage, version or sha512" >&2; return 1; }
  echo "Olyvr: the $OLYVR_TRACK track is on $FEED_VERSION"
  [ -n "${1:-}" ] || return 0
  curl -fsSL --retry 5 --retry-all-errors -o "$1" "$url"
  [ "$(openssl dgst -sha512 -binary "$1" | base64 -w0)" = "$sha" ] || { echo "$url doesn't match its SHA-512" >&2; return 1; }
  printf 'version=%s\ntrack=%s\nfrom=%s\n' "$FEED_VERSION" "$OLYVR_TRACK" "$url" > "$1.release"
}
fetch_artifact_once() {
  case $ARTIFACTS in
    s3://*) [ "$CLOUD" = aws ] || { echo "s3:// artifacts need CLOUD=aws" >&2; return 2; }
            aws s3 cp --only-show-errors "$ARTIFACTS/$1" "$2" ;;
    gs://*) [ "$CLOUD" = gcp ] || { echo "gs:// artifacts need CLOUD=gcp" >&2; return 2; }
            local tok; tok=$(gcp_token) || return 1
            curl -fsSLo "$2" -H "Authorization: Bearer $tok" "https://storage.googleapis.com/${ARTIFACTS#gs://}/$1" ;;
    https://*.blob.core.windows.net/*)   # Azure Blob storage, with the VM's identity (Storage Blob Data Reader)
      [ "$CLOUD" = azure ] || { echo "a blob.core.windows.net bundle needs CLOUD=azure" >&2; return 2; }
      local tok; tok=$(curl -fsS -H Metadata:true 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F' | jq -r .access_token) || return 1
      curl -fsSLo "$2" -H "Authorization: Bearer $tok" -H 'x-ms-version: 2021-08-06' "$ARTIFACTS/$1" ;;
    https://*) curl -fsSLo "$2" "$ARTIFACTS/$1" ;;
    *) echo "ARTIFACTS must be an s3://, gs:// or https:// folder" >&2; return 2 ;;
  esac
}

api() { curl -fsS -m 30 -H "Authorization: Bearer $SESSION" -H 'Content-Type: application/json' "$@"; }
ms_get() { api "$API/api/memory-server"; }
ms_post() { api -X POST -d "$1" "$API/api/memory-server"; }
# The memory server's state as "running<tab>storage_backend<tab>llm<tab>install phase".
ms_state() { ms_get | jq -r '[.running, .storage_backend, .llm, .install.phase] | @tsv'; }
install_done() { local p; p=$(ms_state | cut -f4); [ "$p" = "done" ] || { [ "$p" = "error" ] && return 2; return 1; }; }
on_postgres() { [ "$(ms_state | cut -f1,2)" = "true	postgres" ]; }
wait_for() { # wait_for SECONDS "description" command...
  local secs=$1 what=$2; shift 2
  local end=$((SECONDS + secs))
  until "$@"; do
    [ $SECONDS -lt $end ] || { echo "timed out waiting for $what" >&2; return 1; }
    sleep 5
  done
}

# ---------- 1. packages ----------
step packages
if ! is_done packages 3; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q postgresql-16 postgresql-16-pgvector certbot jq curl dnsutils unzip logrotate gpg \
    age sqlite3 zstd rsync python3-cryptography
  if [ "$CLOUD" = aws ] && ! command -v aws >/dev/null; then
    # The one CLI the bootstrap needs: SigV4 for Secrets Manager and S3 is not worth doing by hand.
    tmp=$(mktemp -d)
    # Amazon signs the zip; the key is shipped in aws-cli.pub.asc (fingerprint FB5DB77FD5C118B80511ADA8A6310ACC4672475C,
    # as the AWS CLI install guide publishes it) and the signature is checked before anything is unpacked or run.
    curl -fsSo "$tmp/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$AWSCLI_VERSION.zip"
    curl -fsSo "$tmp/awscli.zip.sig" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$AWSCLI_VERSION.zip.sig"
    export GNUPGHOME="$tmp/gnupg"; mkdir -m 700 "$GNUPGHOME"
    gpg --batch --quiet --import "$OLYVR_HOME/bootstrap/aws-cli.pub.asc"
    [ "$(gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')" = FB5DB77FD5C118B80511ADA8A6310ACC4672475C ]
    gpg --batch --quiet --trust-model always --verify "$tmp/awscli.zip.sig" "$tmp/awscli.zip"
    unset GNUPGHOME
    unzip -q "$tmp/awscli.zip" -d "$tmp" && "$tmp/aws/install" >/dev/null
    rm -rf "$tmp"
  fi
  # uv, pinned, checked against its published digest. The memory server reuses it (OLYVR_UV).
  if [ ! -x /usr/local/bin/uv ] || [ "$(/usr/local/bin/uv --version | awk '{print $2}')" != "$UV_VERSION" ]; then
    tmp=$(mktemp -d)
    asset=uv-x86_64-unknown-linux-gnu.tar.gz
    curl -fsSLo "$tmp/$asset" "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/$asset"
    curl -fsSLo "$tmp/$asset.sha256" "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/$asset.sha256"
    (cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null)
    tar -xzf "$tmp/$asset" -C "$tmp"
    install -m 755 "$tmp"/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv
    rm -rf "$tmp"
  fi
  mark packages 3
fi
if ! is_done rclone "$(digest "$RCLONE_VERSION" "$RCLONE_SHA256")"; then
  tmp=$(mktemp -d)
  asset=rclone-v$RCLONE_VERSION-linux-amd64
  curl -fsSLo "$tmp/$asset.zip" "https://downloads.rclone.org/v$RCLONE_VERSION/$asset.zip"
  echo "$RCLONE_SHA256  $tmp/$asset.zip" | sha256sum -c --quiet
  unzip -q "$tmp/$asset.zip" -d "$tmp"
  install -m 755 "$tmp/$asset/rclone" /usr/local/bin/rclone
  rm -rf "$tmp"
  mark rclone "$(digest "$RCLONE_VERSION" "$RCLONE_SHA256")"
fi

# ---------- 2. PostgreSQL ----------
step postgresql
if ! is_done postgresql 1; then
  conf=/etc/postgresql/16/main/postgresql.conf
  sed -i -E "s/^#?shared_buffers = .*/shared_buffers = 512MB/; s/^#?work_mem = .*/work_mem = 16MB/" "$conf"
  grep -q "^listen_addresses = 'localhost'" "$conf" || sed -i -E "s/^#?listen_addresses = .*/listen_addresses = 'localhost'/" "$conf"
  systemctl enable -q postgresql
  systemctl restart postgresql
  if [ ! -f "$PG_ENV" ]; then
    pw=$(openssl rand -hex 24)   # hex: no / or + to break DATABASE_URL
    (umask 077; echo "PG_PASSWORD=$pw" > "$PG_ENV")
  fi
  # shellcheck disable=SC1090
  . "$PG_ENV"
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'teammind') THEN
    CREATE ROLE teammind LOGIN PASSWORD '$PG_PASSWORD';
  ELSE
    ALTER ROLE teammind WITH PASSWORD '$PG_PASSWORD';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE teammind OWNER teammind' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'teammind') \gexec
SQL
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d teammind -c 'CREATE EXTENSION IF NOT EXISTS vector'
  psql "postgresql://teammind:$PG_PASSWORD@127.0.0.1:5432/teammind" -tAc "select extversion from pg_extension where extname = 'vector'" | grep -q .
  mark postgresql 1
fi
# shellcheck disable=SC1090
. "$PG_ENV"

# ---------- 3. the olyvr user, the session token and the sources ----------
step users
id -u olyvr >/dev/null 2>&1 || useradd -r -m -d /var/lib/olyvr -s /usr/sbin/nologin olyvr
install -d -o olyvr -g olyvr -m 700 "$STATE" "$OLYVR_HOME" /var/lib/olyvr/device "$TLS_DIR"
chgrp olyvr /etc/olyvr
if [ ! -f /etc/olyvr/session-token ]; then
  (umask 077; openssl rand -base64 32 | tr -d '\n' > /etc/olyvr/session-token)
fi
SESSION=$(cat /etc/olyvr/session-token)

step sources
install -d -m 755 "$BUNDLE"
fetch_artifact SHA256SUMS "$BUNDLE/SHA256SUMS.new"
mv "$BUNDLE/SHA256SUMS.new" "$BUNDLE/SHA256SUMS"
# What went in (teammind-stage.sh).
if grep -qE ' [*]?BUNDLE$' "$BUNDLE/SHA256SUMS"; then
  fetch_artifact BUNDLE "$BUNDLE/BUNDLE"
  staged=$(sed -n 's/^memory_release=//p' "$BUNDLE/BUNDLE")
  [ -z "$staged" ] || [ "$staged" = "$MEMORY_RELEASE" ] \
    || { echo "the bundle holds memory release $staged, but MEMORY_RELEASE is $MEMORY_RELEASE" >&2; exit 1; }
fi
if [ -n "$OLYVR_TRACK" ]; then
  fetch_public_appimage
  OLYVR_DIGEST=$(digest "$OLYVR_TRACK" "$FEED_VERSION" "$ARTIFACTS" "$ARTIFACTS_SHA256")
else
  OLYVR_DIGEST=$(digest "$ARTIFACTS" "$ARTIFACTS_SHA256")
fi
if ! is_done olyvr "$OLYVR_DIGEST"; then
  systemctl stop olyvr 2>/dev/null || true
  if [ -d "$APP.previous" ]; then rm -rf "$APP"; mv "$APP.previous" "$APP"; fi
  tmp=$(mktemp -d)
  if [ -n "$OLYVR_TRACK" ]; then
    fetch_public_appimage "$tmp/olyvr.AppImage"
  else
    fetch_artifact olyvr.AppImage "$tmp/olyvr.AppImage"
    echo "from=$ARTIFACTS" > "$tmp/olyvr.AppImage.release"
  fi
  # Unpacked, never run as an app.
  chmod +x "$tmp/olyvr.AppImage"
  (cd "$tmp" && ./olyvr.AppImage --appimage-extract >/dev/null)
  [ -x "$tmp/squashfs-root/resources/backend/olyvr-backend" ] || { echo "olyvr.AppImage has no resources/backend/olyvr-backend" >&2; exit 1; }
  fetch_artifact teammind-tools.tar.gz "$tmp/tools.tar.gz"
  [ ! -d "$APP" ] || mv "$APP" "$APP.previous"   # kept until the new one is in place and marked done
  mkdir -p "$APP"
  mv "$tmp/squashfs-root/resources/backend" "$tmp/squashfs-root/resources/workspace" "$APP/"
  chown -R olyvr:olyvr "$APP"
  rm -rf "$TOOLS"; mkdir -p "$TOOLS"; tar -xzf "$tmp/tools.tar.gz" -C "$TOOLS"
  mv "$tmp/olyvr.AppImage.release" "$OLYVR_RELEASE"
  rm -rf "$tmp"
  mark olyvr "$OLYVR_DIGEST"
  rm -rf "$APP.previous"
fi
MEMORY_DIGEST=$(digest "$ARTIFACTS" "$ARTIFACTS_SHA256" "$MEMORY_RELEASE")
if ! is_done memory-source "$MEMORY_DIGEST"; then
  if [ -f "$OLYVR_ENV" ] && systemctl is-active -q olyvr; then ms_post '{"action":"stop"}' >/dev/null || true; fi
  rm -rf "$STATE/memory/venv"
  tmp=$(mktemp -d)
  fetch_artifact reasonara-memory.tar.gz "$tmp/memory.tar.gz"
  rm -rf "$MEMORY_SRC"; tar -xzf "$tmp/memory.tar.gz" -C "$OLYVR_HOME"; rm -rf "$tmp"
  [ -f "$MEMORY_SRC/pyproject.toml" ] || { echo "reasonara-memory.tar.gz has no reasonara-memory/pyproject.toml" >&2; exit 1; }
  chown -R olyvr:olyvr "$MEMORY_SRC"
  mark memory-source "$MEMORY_DIGEST"
fi
# olyvr.service runs the unpacked backend itself; an older bootstrap's override of it goes.
rm -f "$DROPIN"; rmdir --ignore-fail-on-non-empty "$(dirname "$DROPIN")" 2>/dev/null || true
RESOURCE_ROOT=$APP/workspace

# ---------- 4. Olyvr headless: env file, storage, service ----------
step olyvr-env
LLM_KEY=""
[ -n "$LLM_KEY_SECRET" ] && LLM_KEY=$(read_secret "$LLM_KEY_SECRET")
ENV_DIGEST=$(digest "$LLM_BASE_URL" "$LLM_MODEL" "$(digest "$LLM_KEY")" "$MEMORY_RELEASE" "$OLYVR_DIGEST" "$RESOURCE_ROOT" "$STATE" vault=file)
if ! is_done olyvr-env "$ENV_DIGEST"; then
  (umask 077; cat > "$OLYVR_ENV" <<ENVF
# Written by bootstrap.sh; edit /etc/olyvr/bootstrap.env and rerun it instead.
OLYVR_SESSION_TOKEN=$SESSION
OLYVR_FEATURE_MEMORY_SERVER=1
OLYVR_REQUIRE_ACCOUNT=0
OLYVR_RESOURCE_ROOT=$RESOURCE_ROOT
# The state the backend opens: without it, a per-account folder under the resource root (paths.py).
OLYVR_STATE_DIR=$STATE
OLYVR_DEVICE_DIR=/var/lib/olyvr/device
OLYVR_MEMORY_SOURCE_DIR=$MEMORY_SRC
OLYVR_MEMORY_RELEASE=$MEMORY_RELEASE
OLYVR_UV=/usr/local/bin/uv
OLYVR_VAULT=file
OLYVR_MODEL_BASE=$LLM_BASE_URL
OLYVR_MODEL_KEY=$LLM_KEY
OLYVR_MODEL=$LLM_MODEL
HOME=/var/lib/olyvr
ENVF
  )
  mark olyvr-env "$ENV_DIGEST"
  RESTART_OLYVR=1
fi
unset LLM_KEY

# server.env: the memory API's storage. Owned by olyvr, mode 600, or Olyvr refuses it and stays on local storage.
install -d -o olyvr -g olyvr -m 700 "$STATE/memory"
if [ ! -f "$STATE/memory/server.env" ]; then
  tmp=$(mktemp)
  cat > "$tmp" <<ENVF
MEMORY_BACKEND=pgvector
DATABASE_URL=postgresql://teammind:$PG_PASSWORD@127.0.0.1:5432/teammind
PG_POOL_SIZE=8
ENVF
  install -o olyvr -g olyvr -m 600 "$tmp" "$STATE/memory/server.env"; rm -f "$tmp"
fi

install -m 644 "$OLYVR_HOME/bootstrap/olyvr.service" /etc/systemd/system/olyvr.service
systemctl daemon-reload
systemctl enable -q olyvr
if [ "${RESTART_OLYVR:-0}" = 1 ] || ! systemctl is-active -q olyvr; then
  systemctl restart olyvr
fi
wait_for 180 "the backend's /api/health" api -o /dev/null "$API/api/health"

# ---------- 5. TLS ----------
step tls
CERT=""; KEY=""
case $TLS_MODE in
  letsencrypt)
    if [ -z "$DOMAIN" ] || [ -z "$ACME_EMAIL" ]; then echo "letsencrypt needs DOMAIN and ACME_EMAIL" >&2; exit 1; fi
    TLS_DIGEST=$(digest letsencrypt "$DOMAIN" "$ACME_EMAIL")
    if ! is_done tls "$TLS_DIGEST"; then
      [ ! -f "$MARKS/tls.done" ] || TLS_CHANGED=1
      wait_for 900 "$DOMAIN to resolve to $PUBLIC_IP" bash -c "dig +short @1.1.1.1 A '$DOMAIN' | grep -qx '$PUBLIC_IP'"
      certbot certonly -n --standalone --agree-tos -m "$ACME_EMAIL" -d "$DOMAIN" --keep-until-expiring
      install -m 755 "$OLYVR_HOME/bootstrap/certbot-deploy.sh" /etc/letsencrypt/renewal-hooks/deploy/olyvr.sh
      mark tls "$TLS_DIGEST"
    fi
    install -o olyvr -g olyvr -m 600 "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$TLS_DIR/gate.crt"
    install -o olyvr -g olyvr -m 600 "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$TLS_DIR/gate.key"
    CERT=$TLS_DIR/gate.crt; KEY=$TLS_DIR/gate.key ;;
  provided)
    [ -n "$TLS_SECRET" ] || { echo "provided needs TLS_SECRET" >&2; exit 1; }
    pem=$(read_secret "$TLS_SECRET")
    TLS_DIGEST=$(digest provided "$DOMAIN" "$(digest "$pem")")
    if ! is_done tls "$TLS_DIGEST"; then
      [ ! -f "$MARKS/tls.done" ] || TLS_CHANGED=1
      # One secret: the private key block and the certificate chain, in either order. The awk range reopens at
      # every BEGIN, so all certificate blocks (leaf and intermediates) are kept, in their order.
      printf '%s\n' "$pem" | awk '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/' > "$TLS_DIR/gate.key.new"
      printf '%s\n' "$pem" | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > "$TLS_DIR/gate.crt.new"
      if [ ! -s "$TLS_DIR/gate.key.new" ] || [ ! -s "$TLS_DIR/gate.crt.new" ]; then echo "secret $TLS_SECRET holds no key + certificate pair" >&2; exit 1; fi
      # Every block parses, and the key is the first certificate's (Olyvr checks the pair again on save).
      n=$(openssl crl2pkcs7 -nocrl -certfile "$TLS_DIR/gate.crt.new" | openssl pkcs7 -print_certs -noout | grep -c '^subject=')
      echo "provided certificate chain: $n certificate(s)"
      [ "$(openssl x509 -in "$TLS_DIR/gate.crt.new" -pubkey -noout)" = "$(openssl pkey -in "$TLS_DIR/gate.key.new" -pubout)" ] \
        || { echo "secret $TLS_SECRET: the key isn't the certificate's" >&2; exit 1; }
      install -o olyvr -g olyvr -m 600 "$TLS_DIR/gate.key.new" "$TLS_DIR/gate.key"
      install -o olyvr -g olyvr -m 600 "$TLS_DIR/gate.crt.new" "$TLS_DIR/gate.crt"
      rm -f "$TLS_DIR"/gate.*.new
      mark tls "$TLS_DIGEST"
    fi
    unset pem
    CERT=$TLS_DIR/gate.crt; KEY=$TLS_DIR/gate.key ;;
  self_signed)
    mark tls "$(digest self_signed "$DOMAIN")" ;;
  *) echo "TLS_MODE must be letsencrypt, provided or self_signed" >&2; exit 1 ;;
esac

# ---------- 6. the memory server, through the local API ----------
step memory-server
save=$(jq -nc --arg port "$GATE_PORT" --arg domain "$DOMAIN" --arg cert "$CERT" --arg key "$KEY" \
  '{action:"save", enabled:true, shared:true, port:($port|tonumber), public:false, domain:$domain, cert_file:$cert, key_file:$key}')
out=$(ms_post "$save")
[ "$(echo "$out" | jq -r .ok)" = true ] || { echo "save refused: $out" >&2; exit 1; }
if [ "${TLS_CHANGED:-0}" = 1 ]; then
  # The gate serves the certificate it started with, and save() restarts it only when the paths change. New bytes
  # at the same paths need a restart of Olyvr (which brings the memory server and the gate back by itself).
  echo "the certificate changed; restarting olyvr so the gate serves it"
  systemctl restart olyvr
  wait_for 180 "the backend's /api/health" api -o /dev/null "$API/api/health"
fi

s=$(ms_get)
if [ "$(echo "$s" | jq -r .running)" != true ] || [ "$(echo "$s" | jq -r .storage_backend)" != postgres ]; then
  if [ ! -x "$STATE/memory/venv/bin/python" ]; then
    echo "installing the memory API's environment (uv sync of $MEMORY_RELEASE; several minutes)"
    out=$(ms_post '{"action":"install"}')
    [ "$(echo "$out" | jq -r .ok)" = true ] || { echo "install refused: $out" >&2; exit 1; }
    end=$((SECONDS + 1800))
    until install_done; do
      [ $? -ne 2 ] || { echo "install failed: $(ms_get | jq -c .install)"; tail -50 "$STATE/memory/install.log" || true; exit 1; }
      [ $SECONDS -lt $end ] || { echo "the install didn't finish in 30 minutes: $(ms_get | jq -c .install)" >&2; exit 1; }
      sleep 10
    done
    INSTALLED_NOW=1   # install() goes on to start the server itself; a start sent now is refused as "already starting"
  fi
  if [ "${INSTALLED_NOW:-0}" = 0 ] && [ "$(ms_get | jq -r '[.running, .starting] | any')" != true ]; then
    out=$(ms_post '{"action":"start"}')
    [ "$(echo "$out" | jq -r .ok)" = true ] || { echo "start refused: $out" >&2; exit 1; }
  fi
fi
wait_for 600 "the memory API on PostgreSQL" on_postgres \
  || { ms_get | jq '{running, storage, storage_backend, storage_error, start_error}'; exit 1; }
s=$(ms_get)
if [ "$(echo "$s" | jq -r .llm)" != true ]; then
  echo "the memory API started without a model: $LLM_BASE_URL doesn't answer or doesn't list $LLM_MODEL (journalctl -u olyvr)" >&2
  exit 1
fi
if [ "$(echo "$s" | jq -r .gate.running)" != true ]; then
  echo "the gate isn't listening on $GATE_PORT: $(echo "$s" | jq -c .gate)" >&2; exit 1
fi

# ---------- 7. the reader token, once ----------
step token
if [ ! -s "$TOKEN_FILE" ]; then
  out=$(ms_post '{"action":"token","slot":"primary"}')
  tok=$(echo "$out" | jq -r '.token // empty')
  [ -n "$tok" ] || { echo "no token in: $out" >&2; exit 1; }
  (umask 077; printf '%s\n' "$tok" > "$TOKEN_FILE")
  unset tok
fi

# ---------- 8. housekeeping ----------
step housekeeping
install -m 644 "$OLYVR_HOME/bootstrap/olyvr-memory.logrotate" /etc/logrotate.d/olyvr-memory
install -m 755 "$OLYVR_HOME/bootstrap/teammind-check.sh" /usr/local/bin/teammind-check

# ---------- 9. backups ----------
step backups
# The backup and restore tools come from the bundle (its SHA256SUMS is the integrity check), not user data, which
# AWS caps at 16 KiB.
tools=$TOOLS
for f in teammind-backup teammind-restore teammind-check-sftp; do
  [ -f "$tools/$f.sh" ] \
    || { echo "$tools has no $f.sh: use a bundle with encrypted backup sets" >&2; exit 1; }
  install -m 755 "$tools/$f.sh" "/usr/local/bin/$f"
done
groupadd -f teammind-pull
install -d -o root -g teammind-pull -m 750 /var/backups/teammind
# This host's backup signing key: made once, never in a backup (a replacement host makes its own).
if [ ! -f /etc/olyvr/backup-sign ]; then
  ssh-keygen -q -t ed25519 -N '' -C "teammind-backup@$(hostname)" -f /etc/olyvr/backup-sign
fi
SIGNING_KEY="$(hostname) namespaces=\"teammind-backup\" $(cut -d' ' -f1,2 /etc/olyvr/backup-sign.pub)"
echo "$SIGNING_KEY" > /var/lib/olyvr/backup-signer; chmod 644 /var/lib/olyvr/backup-signer   # signing_key_command
# The pull user: rsync reads the encrypted sets and nothing else. rrsync is the rsync package's (Ubuntu 24.04 puts it
# in /usr/bin); the forced command would silently refuse every pull if it weren't there, so that is checked here.
if [ -n "$PULL_SSH_PUBLIC_KEY" ]; then
  RRSYNC=$(command -v rrsync || true)
  [ -x "$RRSYNC" ] || { echo "rrsync isn't installed (it comes with rsync on Ubuntu 24.04); the pull user can't be set up" >&2; exit 1; }
  id -u teammind-pull >/dev/null 2>&1 || useradd -r -m -d /var/lib/teammind-pull -s /bin/sh -g teammind-pull teammind-pull
  install -d -o teammind-pull -g teammind-pull -m 700 /var/lib/teammind-pull/.ssh
  echo "command=\"$RRSYNC -ro /var/backups/teammind\",restrict $PULL_SSH_PUBLIC_KEY" > /var/lib/teammind-pull/.ssh/authorized_keys
  chown teammind-pull:teammind-pull /var/lib/teammind-pull/.ssh/authorized_keys; chmod 600 /var/lib/teammind-pull/.ssh/authorized_keys
elif id -u teammind-pull >/dev/null 2>&1; then
  rm -f /var/lib/teammind-pull/.ssh/authorized_keys
fi
# rclone.conf: the reserved `cloud` remote for this cloud's bucket, through the VM's identity (no key), then the
# operator's remotes from the secret store.
case $CLOUD in
  gcp) cloud_remote=$'type = google cloud storage\nenv_auth = true\nbucket_policy_only = true\nno_check_bucket = true'
       cloud_target="cloud:$BACKUP_BUCKET/$(hostname)" ;;
  aws) imds=$(curl -fsS -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
       region=$(curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $imds" http://169.254.169.254/latest/meta-data/placement/region)
       cloud_remote=$'type = s3\nprovider = AWS\nenv_auth = true\nno_check_bucket = true\nno_head = true\nregion = '"$region"
       cloud_target="cloud:$BACKUP_BUCKET/$(hostname)" ;;
  azure) # BACKUP_BUCKET is the container URL: https://<account>.blob.core.windows.net/<container>
       account=${BACKUP_BUCKET#https://}; account=${account%%.*}
       cloud_remote=$'type = azureblob\nenv_auth = true\naccount = '"$account"
       cloud_target="cloud:${BACKUP_BUCKET##*/}/$(hostname)" ;;
esac
REMOTES=""
[ -z "$BACKUP_REMOTE_SECRET" ] || REMOTES=$(read_secret "$BACKUP_REMOTE_SECRET")
if printf '%s\n' "$REMOTES" | grep -qE '^[[:space:]]*\[cloud\][[:space:]]*$'; then
  echo "secret $BACKUP_REMOTE_SECRET defines a remote named cloud, which is reserved for this cloud's bucket" >&2; exit 1
fi
(umask 077; printf '[cloud]\n%s\n\n%s\n' "$cloud_remote" "$REMOTES" > /etc/olyvr/rclone.conf)
[ -n "$BACKUP_TARGETS" ] || { BACKUP_TARGETS=$cloud_target; echo "BACKUP_TARGETS='$BACKUP_TARGETS'" >> "$ENV_FILE"; }
remotes=$(rclone --config /etc/olyvr/rclone.conf listremotes)
for t in $BACKUP_TARGETS; do
  printf '%s\n' "$remotes" | grep -qxF "${t%%:*}:" \
    || { echo "backup target $t names no remote in rclone.conf (cloud, or one from $BACKUP_REMOTE_SECRET)" >&2; exit 1; }
done
echo "$BACKUP_SCHEDULE root /usr/local/bin/teammind-backup >> /var/log/teammind-backup.log 2>&1" > /etc/cron.d/teammind-backup
# One verified backup before the ready marker, whenever what it depends on changed: a fresh server is ready at once,
# and a wrong target or credential fails the apply here rather than the first night.
BACKUP_DIGEST=$(digest "$BACKUP_TARGETS" "$BACKUP_AGE_RECIPIENTS" "$(digest "$REMOTES")" "$OLYVR_DIGEST" "$CLOUD")
unset REMOTES
if ! is_done backups "$BACKUP_DIGEST" || [ -z "$(jq -r '.last_success.time // empty' /var/lib/olyvr/backup-status.json 2>/dev/null)" ]; then
  echo "taking the first backup (verified by a scratch restore)"
  /usr/local/bin/teammind-backup --verify 2>&1 | tee -a /var/log/teammind-backup.log
  mark backups "$BACKUP_DIGEST"
fi

# ---------- 10. monitoring (docs/teammind-monitoring.md) ----------
step monitoring
if [ -n "${GRAFANA_SECRET:-}" ]; then
  [ -f "$tools/teammind-monitoring.sh" ] || { echo "$tools has no teammind-monitoring.sh: stage a newer bundle" >&2; exit 1; }
  install -m 755 "$tools/teammind-monitoring.sh" /usr/local/bin/teammind-monitoring
  g=$(read_secret "$GRAFANA_SECRET"); (umask 077; printf '%s\n' "$g" > /etc/olyvr/grafana.env); unset g
  teammind-monitoring install
fi

URL="https://${DOMAIN:-$PUBLIC_IP}:$GATE_PORT"
printf '%s\nbackup signing key (add to allowed_signers): %s\n' "$URL" "$SIGNING_KEY" > "$READY"
echo "== TeamMind is up at $URL (token: sudo cat $TOKEN_FILE)"
[ ! -f "$OLYVR_RELEASE" ] || echo "== Olyvr: $(tr '\n' ' ' < "$OLYVR_RELEASE")"
[ ! -f "$BUNDLE/BUNDLE" ] || echo "== from $ARTIFACTS: $(tr '\n' ' ' < "$BUNDLE/BUNDLE")"
echo "== backup signing key, for your allowed_signers: $SIGNING_KEY"
