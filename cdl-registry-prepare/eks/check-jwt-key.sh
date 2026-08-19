#!/bin/bash
# terraform external data source (JSON on stdout): does alias/cielara-jwt-signing
# already exist, and which key does it target? The frozen prepare scripts create
# neither, so a script-prepared account adopts by CREATING them. Absence is
# distinguished from lookup failure, so an auth error never turns an import into
# a create that then fails on the live key.
set -euo pipefail

ALIAS="alias/cielara-jwt-signing"

if OUT=$(aws kms describe-key --key-id "${ALIAS}" --query "KeyMetadata.KeyId" --output text 2>&1); then
	echo "{\"exists\":\"true\",\"key_id\":\"${OUT}\"}"
elif grep -qiE "NotFoundException|not found|does not exist" <<<"${OUT}"; then
	echo '{"exists":"false","key_id":""}'
else
	echo "Error checking ${ALIAS}: ${OUT}" >&2
	exit 1
fi
