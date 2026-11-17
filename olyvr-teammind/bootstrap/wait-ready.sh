#!/usr/bin/env bash
# The readiness check Terraform runs after the VM is created: polls over ssh for /var/lib/olyvr/teammind-ready,
# fails with the bootstrap log's tail on /var/lib/olyvr/teammind-failed or when the time is up.
#
#   READY_PRIVATE_KEY_FILE=<key or empty> wait-ready.sh <ip> <user> <timeout seconds> <known_hosts file>
set -euo pipefail
ip=$1; user=$2; timeout=$3; known=$4; key=${READY_PRIVATE_KEY_FILE:-}
rm -f "$known"; mkdir -p "$(dirname "$known")"; touch "$known"
opts=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known" -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR)
[ -n "$key" ] && opts+=(-i "$key")
end=$((SECONDS + timeout))
while :; do
  out=$(ssh "${opts[@]}" "$user@$ip" 'if [ -f /var/lib/olyvr/teammind-ready ]; then echo READY; cat /var/lib/olyvr/teammind-ready; elif [ -f /var/lib/olyvr/teammind-failed ]; then echo FAILED; fi' 2>/dev/null || true)
  case $out in
    READY*) echo "${out#READY}"; exit 0 ;;
    FAILED*) echo "bootstrap failed on $ip; the end of /var/log/teammind-bootstrap.log:" >&2
             ssh "${opts[@]}" "$user@$ip" 'sudo tail -40 /var/log/teammind-bootstrap.log' >&2 || true; exit 1 ;;
  esac
  if [ $SECONDS -ge $end ]; then
    echo "no ready marker on $ip after ${timeout}s; the end of /var/log/teammind-bootstrap.log:" >&2
    ssh "${opts[@]}" "$user@$ip" 'sudo tail -40 /var/log/teammind-bootstrap.log' >&2 || true; exit 1
  fi
  sleep 15
done
