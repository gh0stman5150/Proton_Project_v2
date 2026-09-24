#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_COMMON_SCRIPT="${PROTON_INSTANCE_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-instance-common.sh}"
if [[ ! -f "$INSTANCE_COMMON_SCRIPT" ]]; then
	echo "ERROR: Proton instance helper not found: $INSTANCE_COMMON_SCRIPT" >&2
	exit 1
fi
# shellcheck disable=SC1090
source "$INSTANCE_COMMON_SCRIPT"
PROTON_PORT_FORWARD_ENV="${PROTON_PORT_FORWARD_ENV:-/etc/proton/proton-port-forward.env}"
proton_instance_init "${1:-}" "$PROTON_PORT_FORWARD_ENV"
QBT_COMMON_SCRIPT="${QBT_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-qbittorrent-common.sh}"

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "ERROR: Required command '$cmd' is not installed." >&2
		exit 1
	fi
}

# ExecStartPre preflight: ip, natpmpc, and systemd-cat are checked for the
# port-forward loop that starts next, not used here.
for cmd in curl ip natpmpc systemd-cat; do
	require_command "$cmd"
done

if [[ ! -f "$QBT_COMMON_SCRIPT" ]]; then
	echo "ERROR: qBittorrent helper script not found: $QBT_COMMON_SCRIPT" >&2
	exit 1
fi

# shellcheck disable=SC1090
source "$QBT_COMMON_SCRIPT"

# proton_instance_init already checked and sourced the qBittorrent env file.
: "${QBITTORRENT_URL:?QBITTORRENT_URL must be set in ${QBITTORRENT_ENV_FILE}}"
QBITTORRENT_URL="${QBITTORRENT_URL%/}"

HTTP_STATUS="$(qbt_webui_http_status 5)"
if ! qbt_webui_status_reachable "$HTTP_STATUS"; then
	echo "WARNING: qBittorrent Web API is not reachable at $QBITTORRENT_URL (HTTP ${HTTP_STATUS:-000}); continuing and relying on the sync loop to retry later." >&2
fi
