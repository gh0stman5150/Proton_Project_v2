#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="/usr/local/bin/proton_project"
LIVE_DIR="/usr/local/bin/proton"

install -m 755 "$PROJECT_DIR/proton-healthcheck.sh" "$LIVE_DIR/proton-healthcheck.sh"

systemctl restart proton-healthcheck.service

echo "Deployed proton-healthcheck.sh to $LIVE_DIR"
echo "Restarted proton-healthcheck.service"
