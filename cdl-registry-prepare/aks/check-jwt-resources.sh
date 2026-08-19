#!/bin/bash
# terraform external data source (JSON on stdout): which JWT signing resources
# already exist, and the ids terraform needs to import them. The frozen prepare
# scripts create none of them, so a script-prepared subscription adopts by
# CREATING them; this path matters when the module ran before and the state was
# lost. Empty string means "absent", so the matching import is skipped.
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

RG="$1"
VAULT="$2"
IDENTITY="$3"
APPLIER_OBJECT_ID="$4"
CIELARA_CLIENT_ID="$5"

az_tsv() {
	az "$@" --output tsv 2>/dev/null | tr -d '\r' || true
}

RG_ID=$(az_tsv group show --name "${RG}" --query id)
VAULT_ID=""
KEY_ID=""
IDENTITY_ID=""
IDENTITY_PRINCIPAL=""
CRYPTO_USER_ID=""
APPLIER_OFFICER_ID=""
DEPLOYER_MI_ID=""

if [ -n "${RG_ID}" ]; then
	VAULT_ID=$(az_tsv keyvault show --name "${VAULT}" --resource-group "${RG}" --query id)
	IDENTITY_ID=$(az_tsv identity show --name "${IDENTITY}" --resource-group "${RG}" --query id)
	# The MSI resource provider returns "resourcegroups" lowercased; the azurerm
	# UserAssignedIdentity id parser rejects anything but "resourceGroups".
	IDENTITY_ID=${IDENTITY_ID//\/resourcegroups\//\/resourceGroups\/}
	IDENTITY_PRINCIPAL=$(az_tsv identity show --name "${IDENTITY}" --resource-group "${RG}" --query principalId)
fi

if [ -n "${VAULT_ID}" ]; then
	# The azurerm key resource imports by its versioned URL, not by name.
	KEY_ID=$(az_tsv keyvault key show --vault-name "${VAULT}" --name jwt-signing --query key.kid)

	if [ -n "${IDENTITY_PRINCIPAL}" ]; then
		CRYPTO_USER_ID=$(az_tsv role assignment list --assignee "${IDENTITY_PRINCIPAL}" \
			--role "Key Vault Crypto User" --scope "${VAULT_ID}" --query "[0].id")
	fi
	APPLIER_OFFICER_ID=$(az_tsv role assignment list --assignee "${APPLIER_OBJECT_ID}" \
		--role "Key Vault Crypto Officer" --scope "${VAULT_ID}" --query "[0].id")
fi

if [ -n "${IDENTITY_ID}" ]; then
	DEPLOYER_APP_ID=$(az_tsv ad app list --display-name "cielara_aks_deployer_${CIELARA_CLIENT_ID}" --query "[0].appId")
	if [ -n "${DEPLOYER_APP_ID}" ]; then
		DEPLOYER_MI_ID=$(az_tsv role assignment list --assignee "${DEPLOYER_APP_ID}" \
			--role "Managed Identity Contributor" --scope "${IDENTITY_ID}" --query "[0].id")
	fi
fi

cat <<EOF
{"rg_id":"${RG_ID}","vault_id":"${VAULT_ID}","key_id":"${KEY_ID}","identity_id":"${IDENTITY_ID}","crypto_user_id":"${CRYPTO_USER_ID}","applier_officer_id":"${APPLIER_OFFICER_ID}","deployer_mi_id":"${DEPLOYER_MI_ID}"}
EOF
