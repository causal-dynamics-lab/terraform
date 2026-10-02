#!/bin/bash
# terraform external data source (JSON on stdout): how many user-managed keys
# the deployer service account holds. GCP caps a service account at 10, and
# every lost-state re-adopt mints one more.
set -euo pipefail

PROJECT="$1"
SA="$2"

ERR=$(mktemp)
trap 'rm -f "${ERR}"' EXIT

if OUT=$(gcloud iam service-accounts keys list --iam-account "${SA}" --project "${PROJECT}" --managed-by user --format="value(name)" 2>"${ERR}"); then
	echo "{\"count\":\"$(grep -c . <<<"${OUT}" || true)\"}"
elif grep -qiE "not found|404|NOT_FOUND|does not exist" "${ERR}"; then
	echo '{"count":"0"}'
else
	echo "Error listing keys of ${SA} in ${PROJECT}: $(cat "${ERR}")" >&2
	exit 1
fi
