#!/bin/bash
# Looks up the object ids the AKS migration path needs (Azure ids are random,
# unlike the deterministic GCP names) and writes them to migrate.auto.tfvars.
#
# Usage: ./discover-migrate.sh <CIELARA_CLIENT_ID>
# Requires: az CLI logged in, target subscription selected.

set -euo pipefail

# Git Bash on Windows rewrites arguments that look like POSIX paths - the
# /subscriptions/... role-assignment scope becomes C:/Program Files/Git/... and
# Azure rejects it with MissingSubscription. Disable that conversion (no-ops on
# macOS/Linux; both spellings so Git Bash and plain MSYS2 are covered).
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

if [ $# -lt 1 ]; then
	echo "Usage: $0 <CIELARA_CLIENT_ID>" >&2
	exit 1
fi

CIELARA_CLIENT_ID="$1"
SP_NAME="cielara_aks_deployer_${CIELARA_CLIENT_ID}"

# On Windows (Git Bash), az emits CRLF line endings; the stray \r would corrupt
# every captured id (Azure then rejects the scope with MissingSubscription).
az_tsv() {
	az "$@" --output tsv | tr -d '\r'
}

SUBSCRIPTION_ID=$(az_tsv account show --query id)
SUB_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

APP_OBJECT_ID=$(az_tsv ad app list --display-name "${SP_NAME}" --query "[0].id")
APP_CLIENT_ID=$(az_tsv ad app list --display-name "${SP_NAME}" --query "[0].appId")
if [ -z "${APP_OBJECT_ID}" ]; then
	echo "Error: no Entra application named '${SP_NAME}' in this tenant." >&2
	exit 1
fi

SP_OBJECT_ID=$(az_tsv ad sp show --id "${APP_CLIENT_ID}" --query id)

CONTRIBUTOR_ID=$(az_tsv role assignment list --assignee "${APP_CLIENT_ID}" \
	--role "Contributor" --scope "${SUB_SCOPE}" --query "[0].id")
RBAC_ADMIN_ID=$(az_tsv role assignment list --assignee "${APP_CLIENT_ID}" \
	--role "Role Based Access Control Administrator" --scope "${SUB_SCOPE}" --query "[0].id")

if [ -z "${CONTRIBUTOR_ID}" ] || [ -z "${RBAC_ADMIN_ID}" ]; then
	echo "Error: expected Contributor + RBAC Administrator assignments for ${SP_NAME} at ${SUB_SCOPE}." >&2
	echo "Found: Contributor='${CONTRIBUTOR_ID}' RBACAdmin='${RBAC_ADMIN_ID}'" >&2
	exit 1
fi

cat > migrate.auto.tfvars <<EOF
migrate                           = true
create_secret                     = false
migrate_app_object_id             = "${APP_OBJECT_ID}"
migrate_sp_object_id              = "${SP_OBJECT_ID}"
migrate_contributor_assignment_id = "${CONTRIBUTOR_ID}"
migrate_rbac_admin_assignment_id  = "${RBAC_ADMIN_ID}"
EOF

# The infra-version resources are not discovered here: the module's
# check-version-marker.sh looks them up at plan time whenever migrate = true.

echo "Wrote migrate.auto.tfvars:"
cat migrate.auto.tfvars
