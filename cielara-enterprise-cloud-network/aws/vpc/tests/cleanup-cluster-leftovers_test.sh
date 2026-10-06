#!/bin/bash
# Offline tests for cleanup-cluster-leftovers.sh against a fake `aws` on PATH.
# No AWS credentials needed. Run from anywhere:
#   bash tests/cleanup-cluster-leftovers_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../cleanup-cluster-leftovers.sh"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

FAILED=0
fail() {
	echo "FAIL: $*"
	FAILED=1
}

# A PATH holding only the tools the script needs, so "no aws CLI" can be tested
# on machines (and CI runners) that have one installed.
TOOLS="${WORK}/tools"
mkdir -p "${TOOLS}"
for t in bash mktemp tr sed grep head seq rm cat sleep touch; do
	ln -s "$(command -v "${t}")" "${TOOLS}/${t}"
done

# The fake answers from the account below and logs every call to $CALLS.
#   cdl-1700000000-gone   deleted cluster: its leftovers must go
#   cdl-1700000001-live   still exists: must be left alone
#   cdl-1700000002-denied cluster state unreadable: must be left alone
FAKEBIN="${WORK}/fakebin"
mkdir -p "${FAKEBIN}"
cat >"${FAKEBIN}/aws" <<'FAKE'
#!/bin/bash
echo "$*" >>"${CALLS}"
# Like the snap-packaged aws CLI: fails, printing nothing, when stdout or
# stderr is a regular file. The script must only ever hand it pipes.
if [ -f /dev/fd/1 ] || [ -f /dev/fd/2 ]; then
	exit 1
fi
args="$*"
case "${args}" in
*"ec2 describe-network-interfaces"*)
	[ "${FAKE_LIST_FAILS:-}" = "1" ] && { echo "UnauthorizedOperation" >&2; exit 254; }
	# CRLF on purpose: aws.exe under Git Bash prints it.
	printf 'eni-gone\tcdl-1700000000-gone\taws-K8S-i-0aaa\r\n'
	printf 'eni-live\tcdl-1700000001-live\taws-K8S-i-0bbb\r\n'
	printf 'eni-denied\tcdl-1700000002-denied\taws-K8S-i-0ccc\r\n'
	printf 'eni-notcni\tcdl-1700000000-gone\tCustomer interface\r\n'
	printf 'eni-other\tother-cluster\taws-K8S-i-0ddd\r\n'
	;;
*"ec2 describe-security-groups --group-ids sg-lookalike"*) echo 0 ;;
*"ec2 describe-security-groups --group-ids"*) echo 1 ;;
*"ec2 describe-security-groups"*)
	printf 'sg-gone\teks-cluster-sg-cdl-1700000000-gone-123\r\n'
	printf 'sg-live\teks-cluster-sg-cdl-1700000001-live-9\r\n'
	printf 'sg-lookalike\teks-cluster-sg-cdl-1700000000-gone-77\r\n'
	;;
*"eks describe-cluster --name cdl-1700000000-gone"*)
	echo "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found" >&2
	exit 254
	;;
*"eks describe-cluster --name cdl-1700000001-live"*) echo ACTIVE ;;
*"eks describe-cluster"*)
	echo "An error occurred (AccessDeniedException) when calling the DescribeCluster operation" >&2
	exit 254
	;;
*"ec2 delete-network-interface"*) ;;
*"ec2 delete-security-group --group-id sg-gone"*)
	# First attempt races the interface delete.
	if [ ! -f "${STATE}/sg-gone-tried" ]; then
		touch "${STATE}/sg-gone-tried"
		echo "An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation" >&2
		exit 254
	fi
	;;
*) echo "unexpected call: ${args}" >&2; exit 2 ;;
esac
FAKE
chmod +x "${FAKEBIN}/aws"

run_script() {
	CALLS="${WORK}/calls" STATE="${WORK}/state" CIELARA_CLEANUP_RETRY_SLEEP=0 \
		"${TOOLS}/bash" "${SCRIPT}" us-east-2 vpc-0abc subnet-1,subnet-2 2>"${WORK}/stderr"
}

reset() {
	rm -rf "${WORK}/calls" "${WORK}/state" "${WORK}/stderr"
	mkdir -p "${WORK}/state"
	touch "${WORK}/calls"
}

deletes() { grep -oE 'delete-(network-interface --network-interface-id|security-group --group-id) [a-z0-9-]+' "${WORK}/calls" | awk '{print $NF}' | sort | tr '\n' ' '; }

# --- deletes only a deleted cdl- cluster's tagged leftovers ---------------------
reset
PATH="${FAKEBIN}:${TOOLS}" run_script
rc=$?
[ "${rc}" -eq 0 ] || fail "scoped cleanup: exit ${rc}, want 0"
got=$(deletes)
[ "${got}" = "eni-gone sg-gone sg-gone " ] || fail "scoped cleanup: deleted '${got}', want 'eni-gone sg-gone sg-gone ' (sg retried once)"
n=$(grep -c 'describe-cluster --name cdl-1700000000-gone' "${WORK}/calls")
[ "${n}" -eq 1 ] || fail "scoped cleanup: described the gone cluster ${n} times, want 1 (cached)"
grep -q 'other-cluster' "${WORK}/calls" && fail "scoped cleanup: looked up a non-cdl cluster"
grep -q 'deleted security group sg-gone' "${WORK}/stderr" || fail "scoped cleanup: no success line for sg-gone"
grep -q 'DependencyViolation' "${WORK}/stderr" && fail "scoped cleanup: reported a retried DependencyViolation as a failure"
grep -q 'cluster cdl-1700000002-denied still exists; leaving its resources alone: An error occurred (AccessDeniedException)' "${WORK}/stderr" ||
	fail "scoped cleanup: the unreadable cluster's AWS error is not in the log"
grep -q 'cluster cdl-1700000001-live still exists (ACTIVE)' "${WORK}/stderr" ||
	fail "scoped cleanup: no 'still exists' line for the live cluster"

# --- no aws CLI: prints the manual steps, exits 0 -------------------------------
reset
PATH="${TOOLS}" run_script
rc=$?
[ "${rc}" -eq 0 ] || fail "no aws: exit ${rc}, want 0"
grep -q 'aws CLI not found' "${WORK}/stderr" || fail "no aws: missing explanation"
grep -q 'delete-network-interface' "${WORK}/stderr" || fail "no aws: missing manual steps"

# --- listing fails: deletes nothing, exits 0 ------------------------------------
reset
FAKE_LIST_FAILS=1 PATH="${FAKEBIN}:${TOOLS}" run_script
rc=$?
[ "${rc}" -eq 0 ] || fail "list fails: exit ${rc}, want 0"
[ -z "$(deletes)" ] || fail "list fails: deleted '$(deletes)', want nothing"
grep -q 'could not list network interfaces' "${WORK}/stderr" || fail "list fails: missing explanation"

# --- missing arguments: does nothing, exits 0 -----------------------------------
reset
PATH="${FAKEBIN}:${TOOLS}" CALLS="${WORK}/calls" "${TOOLS}/bash" "${SCRIPT}" us-east-2 "" "" 2>"${WORK}/stderr"
rc=$?
[ "${rc}" -eq 0 ] || fail "missing args: exit ${rc}, want 0"
[ -s "${WORK}/calls" ] && fail "missing args: called aws"

if [ "${FAILED}" -ne 0 ]; then
	exit 1
fi
echo "PASS"
