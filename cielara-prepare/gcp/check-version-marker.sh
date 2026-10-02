#!/bin/bash
# terraform external data source (JSON on stdout): does the infra-version
# bucket already exist? Distinguishes "absent" from lookup failures so an
# auth problem never silently reports the bucket as missing.
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# The shell gcloud launcher needs MSYS path conversion to hand Windows Python
# a real path to gcloud.py. Conversion is disabled above, so use gcloud.cmd.
# Only under MSYS: WSL also finds gcloud.cmd on the appended Windows PATH but
# cannot run batch files.
if [[ "${OSTYPE:-}" == msys* ]] && command -v gcloud.cmd >/dev/null 2>&1; then
	gcloud() { command gcloud.cmd "$@"; }
fi

BUCKET="$1"

if OUT=$(gcloud storage buckets describe "gs://${BUCKET}" --format="value(name)" 2>&1); then
	echo '{"exists":"true"}'
elif grep -qiE "not found|404" <<<"${OUT}"; then
	echo '{"exists":"false"}'
else
	echo "Error checking gs://${BUCKET}: ${OUT}" >&2
	exit 1
fi
