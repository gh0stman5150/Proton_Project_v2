#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/proton-instance-common.sh" && -f "$SCRIPT_DIR/../proton-instance-common.sh" ]]; then
	SCRIPT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
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
require_command flock

cleanup_dnat() {
	local batch
	proton_nft_chain_snapshot ip proton_nat prerouting || return 1
	if [[ "$PROTON_NFT_CHAIN_EXISTS" == 0 ]]; then
		log "No DNAT chain proton_nat.prerouting present, nothing to do"
		return 0
	fi
	batch="$(proton_nft_delete_comment_rules ip proton_nat prerouting "qbt-dnat-${INSTANCE}" "$PROTON_NFT_RULES")" || return 1
	if [[ -n "$batch" ]]; then
		nft -f - <<<"$batch" || return 1
	fi
	log "Removed qBittorrent DNAT rules for $INSTANCE"
}

proton_with_firewall_lock cleanup_dnat
