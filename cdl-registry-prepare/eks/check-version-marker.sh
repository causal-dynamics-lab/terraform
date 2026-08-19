#!/bin/bash
# terraform external data source (JSON on stdout): does the infra-version
# bucket already exist? A 301 means it exists in another region - the module
# must run in the bucket's region, so that is a hard error naming the fix.
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

BUCKET="$1"
REGION="${2:-}"

ARGS=(--bucket "${BUCKET}")
if [ -n "${REGION}" ]; then
	ARGS+=(--region "${REGION}")
fi

if OUT=$(aws s3api head-bucket "${ARGS[@]}" 2>&1); then
	echo '{"exists":"true"}'
elif grep -q "404" <<<"${OUT}"; then
	echo '{"exists":"false"}'
elif grep -q "301" <<<"${OUT}"; then
	ACTUAL=$(aws s3api get-bucket-location --bucket "${BUCKET}" \
		--query LocationConstraint --output text 2>/dev/null | sed 's/^None$/us-east-1/' || true)
	echo "Error: s3://${BUCKET} exists in region '${ACTUAL:-unknown}' - set region = \"${ACTUAL:-<bucket-region>}\" on the module call." >&2
	exit 1
else
	echo "Error checking s3://${BUCKET}: ${OUT}" >&2
	exit 1
fi
