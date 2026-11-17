#!/usr/bin/env bash
# Proves an SFTP backup destination is write-only before it is used, and again after an OpenSSH upgrade on it
# (olyvr-teammind/docs/teammind-backup-recovery.md, "An SFTP destination is an SFTP server"):
#
#   sudo teammind-check-sftp <remote>:<folder>      # a target as BACKUP_TARGETS names it
#
# From this host, with the remote's own credential: a new file must be created and written (and its size seen), and a
# read, a listing, an overwrite, a rename, a mkdir and a delete of it must each be refused. Exit 0 only then. The probe
# file stays (the backup user can't remove it, which is the point); the destination's own retention job clears it.
# Record the far side's `ssh -V` beside the result.
set -uo pipefail
CONF=${RCLONE_CONFIG:-/etc/olyvr/rclone.conf}
target=${1:?usage: teammind-check-sftp <remote>:<folder>}
remote=${target%%:*}; path=${target#*:}
type=$(rclone --config "$CONF" config dump | jq -r --arg r "$remote" '.[$r].type // empty')
[ "$type" = sftp ] || { echo "$remote is not an sftp remote in $CONF (type: ${type:-none})" >&2; exit 1; }
probe="teammind-probe-$(date -u +%Y%m%dT%H%M%SZ)"
dest="$remote:${path:+${path%/}/}$probe"
rc=(--config "$CONF" --no-check-dest --no-traverse --retries 1 --low-level-retries 1 -q)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
head -c 4096 /dev/urandom > "$tmp/a"; head -c 2048 /dev/urandom > "$tmp/b"

bad=0
expect() { # expect ok|refused LABEL COMMAND...
  local want=$1 label=$2 got; shift 2
  if "$@" >"$tmp/out" 2>&1; then got=ok; else got=refused; fi
  if [ "$got" = "$want" ]; then printf 'PASS  %-16s %s\n' "$label" "$got"
  else printf 'FAIL  %-16s %s, want %s: %s\n' "$label" "$got" "$want" "$(tail -1 "$tmp/out")"; bad=1; fi
}
# shellcheck disable=SC2317  # called through expect
size_is() { [ "$(rclone lsjson "${rc[@]}" --stat "$1" | jq -r .Size)" = "$2" ]; }

echo "checking $target with rclone $(rclone version | head -1 | cut -d' ' -f2)"
expect ok      create+write  rclone copyto "${rc[@]}" --inplace "$tmp/a" "$dest"
expect ok      size          size_is "$dest" 4096
expect refused read          rclone cat "${rc[@]}" "$dest"
expect refused list          rclone lsf "${rc[@]}" "$remote:$path"
expect refused overwrite     rclone copyto "${rc[@]}" --inplace "$tmp/b" "$dest"
expect refused rename        rclone moveto "${rc[@]}" "$dest" "$dest.moved"
expect refused mkdir         rclone mkdir "${rc[@]}" "$dest.dir"
expect refused delete        rclone deletefile "${rc[@]}" "$dest"
expect ok      still-there   size_is "$dest" 4096
if [ "$bad" = 0 ]; then echo "OK: $target takes new files and refuses read, list, overwrite, rename, mkdir and delete"
else echo "NOT WRITE-ONLY: don't use $target until every line passes"; fi
exit "$bad"
