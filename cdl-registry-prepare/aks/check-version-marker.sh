#!/bin/bash
# terraform external data source (JSON on stdout): do the infra-version
# resources already exist? Reports the storage account plus the deployer's
# Storage Blob Data Reader assignment id (Azure ids are random, so the
# assignment cannot be derived - it must be looked up). Distinguishes
# "absent" from lookup failures so an auth problem never silently reports
# the resources as missing.
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

RG_NAME="$1"
SA_NAME="$2"
SP_OBJECT_ID="$3"
SUBSCRIPTION_ID="$4"

if ! OUT=$(az storage account show --name "${SA_NAME}" --resource-group "${RG_NAME}" \
	--subscription "${SUBSCRIPTION_ID}" --query name --output tsv 2>&1); then
	if grep -qiE "ResourceNotFound|ResourceGroupNotFound|was not found" <<<"${OUT}"; then
		echo '{"exists":"false","ra_id":""}'
		exit 0
	fi
	echo "Error checking storage account ${SA_NAME}: ${OUT}" >&2
	exit 1
fi

RA_ID=""
if [ -n "${SP_OBJECT_ID}" ]; then
	SA_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}"
	RA_ID=$(az role assignment list --assignee "${SP_OBJECT_ID}" \
		--role "Storage Blob Data Reader" --scope "${SA_SCOPE}" \
		--query "[0].id" --output tsv 2>/dev/null | tr -d '\r' || true)
fi

printf '{"exists":"true","ra_id":"%s"}\n' "${RA_ID}"
