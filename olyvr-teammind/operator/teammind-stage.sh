#!/usr/bin/env bash
# Stages a TeamMind bundle: the folder the `artifacts` variable names, the only way a server gets Olyvr and the memory
# API (bootstrap.sh, step 3); servers never fetch source. BUNDLE's tools_commit is this repo's commit (the backup
# tools come from here), not Olyvr's.
#
#   teammind-stage.sh --olyvr-run <id> --memory-run <id> s3://bucket/teammind
#   teammind-stage.sh --olyvr-run <id> --memory-run <id> gs://bucket/teammind
#   teammind-stage.sh --olyvr-run <id> --memory-run <id> https://<account>.blob.core.windows.net/<container>/teammind
#   teammind-stage.sh --appimage <file> --memory <file> [--track dev|beta|stable] s3://bucket/teammind
#
# Olyvr is the olyvr-linux artifact of a Release run (release.yml); its track (dev, or beta/stable for
# production's services) is read from the run. The memory API is the linux-x86_64 archive of a Memory API release
# run (memory-release.yml), for the tag memory_release names. The backup tools come from this checkout.
#
# Writes <dest>/<track>-<version>/ (olyvr.AppImage, reasonara-memory.tar.gz, teammind-tools.tar.gz, BUNDLE with what
# went in, SHA256SUMS), so a dev and a beta bundle sit side by side; uploads it with your AWS credentials when DEST is
# s3://, your gcloud login when it is gs://, or your az login when it is an Azure Blob container (you need Storage Blob
# Data Contributor on it), and prints the two variables to set. Switching a server between bundles is those two values
# (README.md).
# A DEST without a scheme is a local folder, for serving over https:// some other way.
set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
olyvr_run=""; memory_run=""; appimage=""; memory=""; track=""; repo=xfabric-sec/olyvr
while [ $# -gt 1 ]; do
  case $1 in
    --olyvr-run) olyvr_run=$2 ;;
    --memory-run) memory_run=$2 ;;
    --appimage) appimage=$2 ;;
    --memory) memory=$2 ;;
    --track) track=$2 ;;
    --repo) repo=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[ $# -eq 1 ] || usage
dest=${1%/}
if [ -z "$olyvr_run$appimage" ] || [ -z "$memory_run$memory" ]; then usage; fi
here=$(cd "$(dirname "$0")" && pwd)
bootstrap=$here/../bootstrap

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
out=$work/bundle; mkdir -p "$out"

if [ -n "$olyvr_run" ]; then
  gh run download "$olyvr_run" -R "$repo" -n olyvr-linux -D "$work/olyvr"
  appimage=$(ls "$work"/olyvr/*.AppImage)
  # The build's track, as release.yml passed it to the build.
  # (the run's log archive: gh run view --log prints nothing for some runs).
  if [ -z "$track" ]; then
    gh api "repos/$repo/actions/runs/$olyvr_run/logs" > "$work/logs.zip"
    track=$(unzip -p "$work/logs.zip" | sed -n 's/.*  OLYVR_TRACK: \([a-z]*\).*/\1/p' | head -n1)
  fi
fi
if [ -n "$memory_run" ]; then
  gh run download "$memory_run" -R "$repo" -n memory-archives -D "$work/memory"
  memory=$(ls "$work"/memory/*-linux-x86_64.tar.gz)
fi
[ -f "$appimage" ] || { echo "no AppImage at $appimage" >&2; exit 1; }
[ -f "$memory" ] || { echo "no memory archive at $memory" >&2; exit 1; }
case $track in dev|beta|stable) ;; *) echo "the build's track is '$track': give --track dev, beta or stable" >&2; exit 1 ;; esac
tar -tzf "$memory" reasonara-memory/pyproject.toml >/dev/null 2>&1 \
  || { echo "$memory isn't a Memory API release archive (no reasonara-memory/pyproject.toml)" >&2; exit 1; }

# Olyvr-<version>-x86_64.AppImage and reasonara-memory-<tag>[-<platform>].tar.gz, as the workflows name them.
version=$(basename "$appimage" | sed -n 's/^Olyvr-\(.*\)-x86_64\.AppImage$/\1/p')
memory_tag=$(basename "$memory" | sed -n 's/^reasonara-memory-\(v[^-]*\(-[a-z]*\.[0-9]*\)\{0,1\}\).*\.tar\.gz$/\1/p')
[ -n "$version" ] || { echo "can't read the version from $(basename "$appimage")" >&2; exit 1; }

cp "$appimage" "$out/olyvr.AppImage"
cp "$memory" "$out/reasonara-memory.tar.gz"
tar -czf "$out/teammind-tools.tar.gz" -C "$bootstrap" teammind-backup.sh teammind-restore.sh teammind-check-sftp.sh \
  teammind-monitoring.sh
cat > "$out/BUNDLE" <<EOF
olyvr_version=$version
olyvr_track=$track
olyvr_run=${olyvr_run:-}
memory_release=$memory_tag
memory_run=${memory_run:-}
tools_commit=$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)
staged=$(date -u +%FT%TZ)
EOF
(cd "$out" && sha256sum olyvr.AppImage reasonara-memory.tar.gz teammind-tools.tar.gz BUNDLE > SHA256SUMS)
sums=$(sha256sum "$out/SHA256SUMS" | cut -d' ' -f1)

folder=$dest/$track-$version
case $dest in
  s3://*) aws s3 cp --only-show-errors --recursive "$out" "$folder" ;;
  gs://*) gcloud storage cp --quiet "$out"/* "$folder/" ;;
  https://*.blob.core.windows.net/*)
    rest=${folder#https://}; account=${rest%%.*}; rest=${rest#*/}; container=${rest%%/*}
    az storage blob upload-batch --only-show-errors --auth-mode login --overwrite --account-name "$account" \
      -d "$container" --destination-path "${rest#*/}" -s "$out" >/dev/null ;;
  *://*) echo "DEST is an s3:// or gs:// folder, an Azure Blob container URL, or a local folder" >&2; exit 1 ;;
  *) mkdir -p "$folder" && cp "$out"/* "$folder/" ;;
esac

cat "$out/BUNDLE"
echo
echo "artifacts        = \"$folder\""
echo "artifacts_sha256 = \"$sums\""
echo "memory_release   = \"$memory_tag\""
