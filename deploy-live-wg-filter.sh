#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="/usr/local/bin/proton_project"
LIVE_DIR="/usr/local/bin/proton"

install -m 755 "$PROJECT_DIR/proton-wg-up-safe.sh" "$LIVE_DIR/proton-wg-up-safe.sh"
install -m 755 "$PROJECT_DIR/proton-wg-down-safe.sh" "$LIVE_DIR/proton-wg-down-safe.sh"

systemctl restart proton-port-forward.service proton-healthcheck.service

echo "Deployed proton-wg-up-safe.sh and proton-wg-down-safe.sh to $LIVE_DIR"
echo "Restarted proton-port-forward.service and proton-healthcheck.service"
