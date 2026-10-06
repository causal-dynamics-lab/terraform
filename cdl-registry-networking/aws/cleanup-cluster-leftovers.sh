#!/bin/bash
# Runs on `terraform destroy`, before this module's subnets and VPC are deleted.
# Removes what a deleted Cielara EKS cluster can leave behind in this network,
# outside any terraform state:
#
#   1. VPC CNI secondary network interfaces: status `available`, description
#      `aws-K8S-<instance-id>`, tag `cluster.k8s.amazonaws.com/name=<cluster>`.
#      They block deleting the subnet.
#   2. The EKS cluster security group `eks-cluster-sg-<cluster>-<n>`, tag
#      `kubernetes.io/cluster/<cluster>=owned`. It blocks deleting the VPC.
#
# Only resources inside this module's VPC/subnets, carrying those tags, for a
# Cielara cluster name (`cdl-<epoch>-<name>`) that EKS reports as gone, are
# touched. A cluster that still exists, or whose state cannot be read, is left
# alone. Nothing else in the account is touched.
#
# Best effort: always exits 0. If something is left, the subnet or VPC delete
# that follows fails exactly as it would without this script.
#
# Usage: cleanup-cluster-leftovers.sh REGION VPC_ID SUBNET_ID[,SUBNET_ID...]
set -uo pipefail

REGION="${1:-}"
VPC_ID="${2:-}"
SUBNETS="${3:-}"

CNI_TAG="cluster.k8s.amazonaws.com/name"
CLUSTER_PATTERN='^cdl-[0-9]+-[a-z0-9-]+$'
RETRY_SLEEP="${CIELARA_CLEANUP_RETRY_SLEEP:-10}"
SG_ATTEMPTS=12

export AWS_PAGER=""

log() { echo "[cielara-network cleanup] $*" >&2; }

manual_steps() {
	log "If terraform destroy then fails with DependencyViolation, remove the leftovers by hand"
	log "(only ones tagged for a Cielara cluster that no longer exists), then re-run destroy:"
	log "  aws ec2 describe-network-interfaces --region ${REGION} --filters Name=subnet-id,Values=${SUBNETS} Name=status,Values=available Name=tag-key,Values=${CNI_TAG}"
	log "  aws ec2 delete-network-interface --region ${REGION} --network-interface-id <eni-id>"
	log "  aws ec2 describe-security-groups --region ${REGION} --filters Name=vpc-id,Values=${VPC_ID} Name=group-name,Values='eks-cluster-sg-cdl-*'"
	log "  aws ec2 delete-security-group --region ${REGION} --group-id <sg-id>"
}

if [ -z "${REGION}" ] || [ -z "${VPC_ID}" ] || [ -z "${SUBNETS}" ]; then
	log "missing region, VPC or subnets; skipping"
	exit 0
fi

if ! command -v aws >/dev/null 2>&1; then
	log "aws CLI not found; cannot check for leftovers of deleted Cielara clusters"
	manual_steps
	exit 0
fi

ERR=$(mktemp)
trap 'rm -f "${ERR}"' EXIT

# aws.exe under Git Bash prints CRLF; strip it so ids compare cleanly.
awsq() { aws --region "${REGION}" "$@" 2>"${ERR}" | tr -d '\r'; }

# Cluster verdicts are cached as "name=gone|keep" lines (bash 3.2 on macOS has
# no associative arrays).
VERDICTS=""

# cluster_gone NAME: 0 only when EKS says the cluster does not exist.
cluster_gone() {
	local name="$1" cached
	cached=$(printf '%s\n' "${VERDICTS}" | sed -n "s/^${name}=//p" | head -n1)
	if [ -n "${cached}" ]; then
		[ "${cached}" = "gone" ]
		return
	fi
	if aws --region "${REGION}" eks describe-cluster --name "${name}" >/dev/null 2>"${ERR}"; then
		log "cluster ${name} still exists; leaving its resources alone"
		VERDICTS="${VERDICTS}${name}=keep"$'\n'
		return 1
	fi
	if grep -q "ResourceNotFoundException" "${ERR}"; then
		VERDICTS="${VERDICTS}${name}=gone"$'\n'
		return 0
	fi
	log "cannot tell whether cluster ${name} still exists; leaving its resources alone: $(tr -d '\r' <"${ERR}" | head -n3)"
	VERDICTS="${VERDICTS}${name}=keep"$'\n'
	return 1
}

LEFT=0

# --- 1. Detached VPC CNI interfaces in this module's subnets -------------------
if ! ENIS=$(awsq ec2 describe-network-interfaces \
	--filters "Name=subnet-id,Values=${SUBNETS}" "Name=status,Values=available" "Name=tag:${CNI_TAG},Values=cdl-*" \
	--query "NetworkInterfaces[].[NetworkInterfaceId, join('', TagSet[?Key=='${CNI_TAG}'].Value), Description]" \
	--output text); then
	log "could not list network interfaces: $(tr -d '\r' <"${ERR}" | head -n3)"
	manual_steps
	exit 0
fi

while IFS=$'\t' read -r eni cluster desc; do
	[ -n "${eni}" ] || continue
	case "${desc}" in
	aws-K8S-*) ;;
	*) continue ;;
	esac
	[[ "${cluster}" =~ ${CLUSTER_PATTERN} ]] || continue
	cluster_gone "${cluster}" || continue
	if awsq ec2 delete-network-interface --network-interface-id "${eni}" >/dev/null ||
		grep -q "InvalidNetworkInterfaceID.NotFound" "${ERR}"; then
		log "deleted network interface ${eni} (cluster ${cluster})"
	else
		log "could not delete network interface ${eni}: $(tr -d '\r' <"${ERR}" | head -n3)"
		LEFT=$((LEFT + 1))
	fi
done <<<"${ENIS}"

# --- 2. EKS cluster security groups in this module's VPC -----------------------
if ! SGS=$(awsq ec2 describe-security-groups \
	--filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=eks-cluster-sg-cdl-*" \
	--query "SecurityGroups[].[GroupId, GroupName]" \
	--output text); then
	log "could not list security groups: $(tr -d '\r' <"${ERR}" | head -n3)"
	manual_steps
	exit 0
fi

while IFS=$'\t' read -r sg name; do
	[ -n "${sg}" ] || continue
	# eks-cluster-sg-<cluster>-<n>
	cluster="${name#eks-cluster-sg-}"
	cluster="${cluster%-*}"
	[[ "${cluster}" =~ ${CLUSTER_PATTERN} ]] || continue
	# EKS stamps the cluster's own tag on the group it created; a lookalike name
	# without it is not ours.
	owned=$(awsq ec2 describe-security-groups --group-ids "${sg}" \
		--filters "Name=tag:kubernetes.io/cluster/${cluster},Values=owned" \
		--query "length(SecurityGroups)" --output text) || owned=0
	[ "${owned}" = "1" ] || continue
	cluster_gone "${cluster}" || continue

	deleted=false
	for attempt in $(seq 1 "${SG_ATTEMPTS}"); do
		if awsq ec2 delete-security-group --group-id "${sg}" >/dev/null ||
			grep -q "InvalidGroup.NotFound" "${ERR}"; then
			deleted=true
			break
		fi
		# Freshly deleted interfaces can hold the group for a few seconds.
		grep -q "DependencyViolation" "${ERR}" || break
		[ "${attempt}" -lt "${SG_ATTEMPTS}" ] && sleep "${RETRY_SLEEP}"
	done
	if ${deleted}; then
		log "deleted security group ${sg} (${name})"
	else
		log "could not delete security group ${sg} (${name}): $(tr -d '\r' <"${ERR}" | head -n3)"
		LEFT=$((LEFT + 1))
	fi
done <<<"${SGS}"

if [ "${LEFT}" -gt 0 ]; then
	manual_steps
fi
exit 0
