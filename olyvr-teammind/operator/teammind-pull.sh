#!/usr/bin/env bash
# Pull a TeamMind server's backup sets to this machine (a laptop, a NAS), from cron or launchd:
#
#   teammind-pull.sh [-i <ssh key>] teammind-pull@<server> <folder>
#
# The server can't reach a laptop and holds no credential for one, so the copy is pulled. The key's line in the
# server's authorized_keys is `command="rrsync -ro /var/backups/teammind",restrict <key>` (Terraform's
# pull_ssh_public_key): rsync can read the encrypted sets and nothing else, not even a shell. This machine must be
# allowed to reach the server's ssh port (admin_cidrs, or the VPN).
#
# Each new set's SHA256SUMS is checked: a complete transfer, not authenticity (that needs the age key and the signing
# key; teammind-unpack.py checks both). Keeps the newest 14 sets and the newest set of each of the 8 latest weeks
# before those, and writes <folder>/.last-success, which is what to watch on this side. Windows: run it in WSL.
set -euo pipefail
key=()
if [ "${1:-}" = -i ]; then key=(-i "$2"); shift 2; fi
src=${1:?usage: teammind-pull.sh [-i key] teammind-pull@<server> <folder>}
dest=${2:?usage: teammind-pull.sh [-i key] teammind-pull@<server> <folder>}
mkdir -p "$dest"
if command -v sha256sum >/dev/null; then sumcheck=(sha256sum -c --quiet); else sumcheck=(shasum -a 256 -c --quiet); fi

# Only finished sets: the server builds each one under a dot name and renames it into place.
rsync -rt --ignore-existing --exclude '.*' -e "ssh ${key[*]:+${key[*]} }-o BatchMode=yes" "$src:" "$dest/"

bad=0
shopt -s nullglob   # no sets yet (a pull before the first backup) is nothing to check, not a failure
for d in "$dest"/teammind-*/; do
  d=${d%/}
  [ ! -f "$d/.checked" ] || continue
  if (cd "$d" && "${sumcheck[@]}" SHA256SUMS); then touch "$d/.checked"
  else echo "$(basename "$d"): incomplete or damaged; removed, the next pull fetches it again" >&2; rm -rf "$d"; bad=1; fi
done

# Retention: the 14 newest, then the newest of each ISO week for 8 more weeks. Set names end in a UTC timestamp,
# so they sort by time.
mapfile -t sets < <(find "$dest" -mindepth 1 -maxdepth 1 -type d -name 'teammind-*' -exec basename {} \; | sort -r)
keep=(); weeks=()
for i in "${!sets[@]}"; do
  s=${sets[$i]}
  if [ "$i" -lt 14 ]; then keep+=("$s"); continue; fi
  stamp=${s##*-}   # 20261030T031500Z
  week=$(date -u -d "${stamp:0:8}" +%G-%V 2>/dev/null || date -u -j -f %Y%m%d "${stamp:0:8}" +%G-%V)
  case " ${weeks[*]:-} " in *" $week "*) continue ;; esac
  [ ${#weeks[@]} -lt 8 ] || continue
  weeks+=("$week"); keep+=("$s")
done
for s in "${sets[@]}"; do
  case " ${keep[*]} " in *" $s "*) ;; *) rm -rf "${dest:?}/$s" ;; esac
done

[ "$bad" = 0 ] || exit 1
date -u +%FT%TZ > "$dest/.last-success"
echo "$(date -u +%FT%TZ) pulled; ${#keep[@]} sets kept in $dest"
