#!/usr/bin/env bash
# certbot's deploy hook: a renewed certificate is copied where the gate reads it, then Olyvr is restarted: the
# gate serves the certificate it started with, and the local API's save restarts it only when the paths change,
# not when the bytes at them do. Runs as root; RENEWED_LINEAGE is certbot's.
set -euo pipefail
TLS_DIR=/etc/olyvr/tls
install -o olyvr -g olyvr -m 600 "$RENEWED_LINEAGE/fullchain.pem" "$TLS_DIR/gate.crt"
install -o olyvr -g olyvr -m 600 "$RENEWED_LINEAGE/privkey.pem" "$TLS_DIR/gate.key"
systemctl restart olyvr
echo "$(date -u +%FT%TZ) certificate renewed; olyvr restarted" >> /var/log/teammind-certbot.log
