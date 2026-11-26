#!/usr/bin/env bash
# Everything after a TeamMind server's `terraform apply`, from the same settings file as teammind-prepare.sh:
#
#   operator/teammind-finish.sh gcp/<name>.conf
#
# Adds the server's backup signing key to ~/.config/teammind/allowed_signers (a restore refuses sets from a key not
# there), saves the reader token to ~/.config/teammind/<name>.token (mode 600), runs teammind-check on the VM and the
# gate check from this machine, and, with BROWSER_SESSION=1, lets the server's Olyvr open in a browser through an
# ssh tunnel. It prints what to send colleagues. Safe to rerun.
set -euo pipefail
# shellcheck source=teammind-conf.sh source-path=SCRIPTDIR
. "$(dirname "$0")/teammind-conf.sh"
need terraform ssh jq

cd "$ROOT"
export TF_DATA_DIR=$SERVER_DATA_DIR
out=$(terraform output -json) || die "no outputs: run the apply first (cd $ROOT; TF_DATA_DIR=$SERVER_DATA_DIR terraform apply -var-file=$NAME.tfvars)"
o() { printf '%s' "$out" | jq -r --arg k "$1" '.[$k].value // empty'; }
ip=$(o public_ip); url=$(o teammind_url)
[ -n "$ip" ] && [ -n "$url" ] || die "the outputs have no public_ip or teammind_url"

# The readiness check pinned the VM's host key here (a path that doesn't follow TF_DATA_DIR).
known=$ROOT/.terraform/teammind-known-hosts
ssh_opts=(-i "$SSH_PRIVATE_KEY_FILE" -o BatchMode=yes -o ConnectTimeout=15)
if [ -s "$known" ]; then ssh_opts+=(-o UserKnownHostsFile="$known" -o StrictHostKeyChecking=yes)
else ssh_opts+=(-o StrictHostKeyChecking=accept-new); fi
# shellcheck disable=SC2029  # the commands are meant to run on the VM
on_vm() { ssh "${ssh_opts[@]}" "ubuntu@$ip" "$@"; }

mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"

say "The backup signing key"
signer=$(on_vm cat /var/lib/olyvr/backup-signer)
[ -n "$signer" ] || die "the server has no backup signing key yet: is the apply finished?"
touch "$CONFIG_DIR/allowed_signers"
if grep -qxF "$signer" "$CONFIG_DIR/allowed_signers"; then echo "already in $CONFIG_DIR/allowed_signers"
else echo "$signer" >> "$CONFIG_DIR/allowed_signers"; echo "added to $CONFIG_DIR/allowed_signers"; fi

say "The reader token"
token_file=$CONFIG_DIR/$NAME.token
(umask 077; on_vm sudo cat /etc/olyvr/teammind-token > "$token_file")
[ -s "$token_file" ] || die "couldn't read the reader token"
echo "saved to $token_file"

if [ "$BROWSER_SESSION" = 1 ]; then
  say "Browser access to the server's Olyvr"
  on_vm 'sudo install -d /etc/systemd/system/olyvr.service.d
    printf "[Service]\nEnvironment=OLYVR_BROWSER_SESSION=1\n" | sudo tee /etc/systemd/system/olyvr.service.d/browser.conf >/dev/null
    sudo systemctl daemon-reload && sudo systemctl restart olyvr'
  echo "on. Open it with: ssh -N -L 9420:127.0.0.1:9420 ubuntu@$ip   then http://127.0.0.1:9420/"
fi

say "teammind-check on the VM"
status=0; on_vm sudo teammind-check || status=$?

say "The gate, from this machine"
crt=()
if [ "$TLS_MODE" = self_signed ]; then
  # Pin the certificate read over ssh, rather than trusting what the gate serves.
  cert_file=$(mktemp); trap 'rm -f "$cert_file"' EXIT
  on_vm sudo cat /var/lib/olyvr/state/memory/tls/gate.crt > "$cert_file"
  crt=("$cert_file")
fi
gate=0; "$HERE/bootstrap/teammind-check.sh" "$url" "$(cat "$token_file")" "${crt[@]}" || gate=$?

cat <<EOF

Server:   $NAME ($ip)
Address:  $url
Token:    $token_file   (put it in a 1Password item with the address, and share that with the team)
Logs:     ssh ubuntu@$ip sudo tail -f /var/log/teammind-bootstrap.log

Next: add the team's data sources in the server's Olyvr (runbook, step 7)$([ "$BROWSER_SESSION" = 1 ] || echo "; set BROWSER_SESSION=1 and rerun this to open it in a browser").
EOF
[ "$status" = 0 ] || echo "teammind-check said the server is not ready (exit $status): see above"
[ "$gate" = 0 ] || { echo "the gate check failed (exit $gate)"; exit 1; }
