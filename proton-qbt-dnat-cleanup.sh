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
proton_instance_init "${1:-}"

LOG_TAG="${LOG_TAG:-proton-qbt-dnat}"

log() {
	local prefix=""

	if command -v date >/dev/null 2>&1; then
		prefix="$(date '+%F %T') | "
	fi

	if command -v systemd-cat >/dev/null 2>&1; then
		printf '%s%s\n' "$prefix" "$*" | systemd-cat -t "$LOG_TAG"
	else
		printf '%s%s\n' "$prefix" "$*" >&2
	fi
}

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

require_command nft

NFT_TABLE="proton_nat"
NFT_CHAIN="prerouting"

if ! nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1; then
	log "No DNAT chain $NFT_TABLE.$NFT_CHAIN present, nothing to do"
	exit 0
fi

# Find and remove rules with this instance's qBittorrent DNAT comment.
handles=$(nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" -a 2>/dev/null | awk -v comment="qbt-dnat-${INSTANCE}" '$0 ~ comment {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}') || true

if [[ -n "$handles" ]]; then
	for h in $handles; do
		nft delete rule ip "$NFT_TABLE" "$NFT_CHAIN" handle "$h" 2>/dev/null || log "Failed to delete DNAT rule handle $h"
	done
	log "Removed qBittorrent DNAT rules for $INSTANCE"
else
	log "No qBittorrent DNAT rules found for $INSTANCE"
fi

# Attempt to delete chain/table if empty (best-effort)
if ! nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" -a 2>/dev/null | grep -q 'handle'; then
	nft delete chain ip "$NFT_TABLE" "$NFT_CHAIN" 2>/dev/null || true
	# try to delete table
	nft delete table ip "$NFT_TABLE" 2>/dev/null || true
	log "Cleaned up empty DNAT table/chain if present"
fi

exit 0
