#!/bin/bash
# terraform external data source (JSON on stdout): does the infra-version
# bucket already exist? Distinguishes "absent" from lookup failures so an
# auth problem never silently reports the bucket as missing.
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

BUCKET="$1"

if OUT=$(gcloud storage buckets describe "gs://${BUCKET}" --format="value(name)" 2>&1); then
	echo '{"exists":"true"}'
elif grep -qiE "not found|404" <<<"${OUT}"; then
	echo '{"exists":"false"}'
else
	echo "Error checking gs://${BUCKET}: ${OUT}" >&2
	exit 1
fi
