#!/bin/bash
# Blocks until Cloud KMS actually serves this project, so the keyring create
# that follows is not the call that discovers the API is still propagating.
# A failed keyring create is unrecoverable without operator surgery: GCP can
# have made the keyring anyway, keyrings are indelible, and terraform can then
# only plan a replace that always fails "already exists".
#
# Polling beats a fixed sleep in both directions - it returns as soon as the
# API answers, and it keeps waiting when propagation runs long. Best-effort by
# design: the caller runs it with on_failure = continue, so a machine with no
# gcloud, no bash or no CLI credentials falls back to the fixed sleep instead
# of failing the apply.
set -uo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

PROJECT="$1"
LOCATION="$2"
TIMEOUT="${3:-600}"
INTERVAL=10

DEADLINE=$((SECONDS + TIMEOUT))

while :; do
	# --quiet, or gcloud offers to enable the API and waits on an answer.
	if out=$(gcloud kms keyrings list --quiet --location "${LOCATION}" --project "${PROJECT}" --format="value(name)" 2>&1); then
		echo "cloudkms.googleapis.com is serving ${PROJECT} (waited ${SECONDS}s)"
		exit 0
	fi

	# Only the propagation window is worth waiting out. Anything else (no
	# gcloud, no credentials, wrong project, no permission) will not resolve
	# itself, so give up immediately rather than burning the whole timeout.
	if ! grep -qiE "has not been used|is not enabled|SERVICE_DISABLED|accessNotConfigured" <<<"${out}"; then
		echo "cloudkms probe stopped early, falling back to the fixed wait: ${out}" >&2
		exit 1
	fi

	if ((SECONDS >= DEADLINE)); then
		echo "cloudkms.googleapis.com still not serving ${PROJECT} after ${SECONDS}s (gave up at ${TIMEOUT}s): ${out}" >&2
		exit 1
	fi

	sleep "${INTERVAL}"
done
