# Sourced by teammind-prepare.sh and teammind-finish.sh: reads a server's .conf (teammind.conf.example) and fills
# in the defaults. Sets ROOT (the server root), BACKUPS_ROOT and the TF_DATA_DIR of each.
# shellcheck shell=bash disable=SC2034  # the variables are for the scripts that source this

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "$c is not installed"; done; }

[ $# -eq 1 ] && [ -f "$1" ] || die "usage: $0 <cloud>/<name>.conf (see operator/teammind.conf.example)"
CONF=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # olyvr-teammind/
# shellcheck disable=SC1090
. "$CONF"

case ${CLOUD:-} in gcp|aws) ;; azure) die "azure isn't scripted yet: follow the runbook" ;; *) die "CLOUD is gcp or aws" ;; esac
[ -n "${NAME:-}" ] || die "NAME is required"
[[ $NAME =~ ^[a-z][a-z0-9-]{0,40}$ ]] || die "NAME: lowercase letters, digits and -, starting with a letter"
[ "$CLOUD" != gcp ] || [ -n "${PROJECT:-}" ] || die "PROJECT is required on gcp"

REGION=${REGION:-$([ "$CLOUD" = gcp ] && echo us-east1 || echo us-east-1)}
ZONE=${ZONE:-$REGION-b}
STATE_BUCKET=${STATE_BUCKET:-$NAME-tfstate}
BACKUP_BUCKET=${BACKUP_BUCKET:-$NAME-teammind-backups}
BUNDLE_BUCKET=${BUNDLE_BUCKET:-$NAME-teammind-bundles}
BACKUP_ENV=${BACKUP_ENV:-$NAME}
OLYVR_TRACK=${OLYVR_TRACK-beta}
LLM_BASE_URL=${LLM_BASE_URL:-https://llm-proxy.cielara-dev.net/t/shared/v1}
LLM_MODEL=${LLM_MODEL:-gpt-6-luna}
LLM_KEY_SECRET=${LLM_KEY_SECRET:-teammind-llm-key}
TLS_MODE=${TLS_MODE:-self_signed}
READER_CIDRS=${READER_CIDRS:-}
ALLOW_PUBLIC_READERS=${ALLOW_PUBLIC_READERS:-false}
AGE_KEY=${AGE_KEY:-~/.config/teammind/age.key}
AGE_KEY=${AGE_KEY/#\~/$HOME}
MACHINE_TYPE=${MACHINE_TYPE:-$([ "$CLOUD" = gcp ] && echo e2-standard-2 || echo t3.large)}
BROWSER_SESSION=${BROWSER_SESSION:-0}
if [ -z "${SSH_PUBLIC_KEY_FILE:-}" ]; then
  for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do [ -f "$k" ] && { SSH_PUBLIC_KEY_FILE=$k; break; }; done
fi
SSH_PUBLIC_KEY_FILE=${SSH_PUBLIC_KEY_FILE/#\~/$HOME}
[ -f "${SSH_PUBLIC_KEY_FILE:-}" ] || die "no ssh public key: set SSH_PUBLIC_KEY_FILE"
SSH_PRIVATE_KEY_FILE=${SSH_PUBLIC_KEY_FILE%.pub}

ROOT=$HERE/$CLOUD
BACKUPS_ROOT=$ROOT/backups
SERVER_DATA_DIR=.terraform-$NAME          # TF_DATA_DIR of the server root, one per server
BACKUPS_DATA_DIR=.terraform-$BACKUP_ENV   # and of the backups root
CONFIG_DIR=~/.config/teammind
