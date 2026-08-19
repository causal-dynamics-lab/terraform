#!/bin/bash
# terraform external data source (JSON on stdout): which app-SA / JWT signing
# resources already exist? Each is probed separately because a partly-applied
# earlier run can have some and not others. Absence is distinguished from lookup
# failure, so an auth error never turns an import into a create that then fails.
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

PROJECT="$1"
REGION="$2"
APP_SA="$3"

exists() {
	local what="$1"
	shift
	local out
	if out=$("$@" 2>&1); then
		echo "true"
	elif grep -qiE "not found|404|NOT_FOUND|does not exist|has not been used|is not enabled|SERVICE_DISABLED" <<<"${out}"; then
		echo "false"
	else
		echo "Error checking ${what} in ${PROJECT}: ${out}" >&2
		exit 1
	fi
}

APP=$(exists "app service account" gcloud iam service-accounts describe "${APP_SA}" --project "${PROJECT}" --format="value(email)")
KEYRING=$(exists "kms keyring cielara-jwt" gcloud kms keyrings describe cielara-jwt --location "${REGION}" --project "${PROJECT}" --format="value(name)")
KEY=$(exists "kms key jwt-signing" gcloud kms keys describe jwt-signing --keyring cielara-jwt --location "${REGION}" --project "${PROJECT}" --format="value(name)")
ROLE=$(exists "custom role cielaraAppJwtSigner" gcloud iam roles describe cielaraAppJwtSigner --project "${PROJECT}" --format="value(name)")

echo "{\"app_sa\":\"${APP}\",\"keyring\":\"${KEYRING}\",\"key\":\"${KEY}\",\"role\":\"${ROLE}\"}"
