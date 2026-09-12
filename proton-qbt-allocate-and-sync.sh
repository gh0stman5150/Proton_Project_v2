#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_COMMON_SCRIPT="${PROTON_INSTANCE_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-instance-common.sh}"
if [[ ! -f "$INSTANCE_COMMON_SCRIPT" ]]; then
	echo "ERROR: Proton instance helper not found: $INSTANCE_COMMON_SCRIPT" >&2
	exit 2
fi
# shellcheck disable=SC1090
source "$INSTANCE_COMMON_SCRIPT"
proton_instance_init "${1:-}"

LOCK_FILE="${QBT_ALLOC_LOCK_FILE:-${STATE_DIR}/qbt-allocate.lock}"
QBITTORRENT_SYNC_SCRIPT="${QBITTORRENT_SYNC_SCRIPT:-/usr/local/bin/proton/proton-qbittorrent-sync-safe.sh}"
WAIT_TRIES="${WAIT_TRIES:-40}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-3}"
ALLOCATION_TIMEOUT_SECONDS="${ALLOCATION_TIMEOUT_SECONDS:-150}"
QBT_SYNC_TIMEOUT_SECONDS="${QBT_SYNC_TIMEOUT_SECONDS:-120}"
QBT_ALLOC_LOCK_WAIT_SECONDS="${QBT_ALLOC_LOCK_WAIT_SECONDS:-30}"

for cmd in flock journalctl mkdir sleep systemctl timeout; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "ERROR: Required command '$cmd' is not installed." >&2
		exit 1
	fi
done

if [[ ! "$WAIT_TRIES" =~ ^[1-9][0-9]{0,5}$ ]]; then
	echo "ERROR: WAIT_TRIES must be a positive integer." >&2
	exit 2
fi
if [[ ! "$WAIT_INTERVAL_SECONDS" =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
	echo "ERROR: WAIT_INTERVAL_SECONDS must be a non-negative integer." >&2
	exit 2
fi
if [[ ! "$ALLOCATION_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{0,2}$ ]] || ((ALLOCATION_TIMEOUT_SECONDS > 150)); then
	echo "ERROR: ALLOCATION_TIMEOUT_SECONDS must be between 1 and 150." >&2
	exit 2
fi
if [[ ! "$QBT_SYNC_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{0,5}$ || ! "$QBT_ALLOC_LOCK_WAIT_SECONDS" =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
	echo "ERROR: Invalid sync timeout or allocator lock wait." >&2
	exit 2
fi
if [[ ! -x "$QBITTORRENT_SYNC_SCRIPT" ]]; then
	echo "ERROR: qBittorrent sync script is not executable: $QBITTORRENT_SYNC_SCRIPT" >&2
	exit 1
fi

ensure_directory() {
	local dir="${1:-}"
	[[ -d "$dir" ]] || mkdir -p "$dir"
}

ensure_directory "${LOCK_FILE%/*}"
ALLOCATION_DEADLINE=$((SECONDS + ALLOCATION_TIMEOUT_SECONDS))

run_bounded() {
	local limit="$1" remaining
	shift
	remaining=$((ALLOCATION_DEADLINE - SECONDS))
	((remaining > 0)) || return 124
	if ((remaining < limit)); then limit="$remaining"; fi
	timeout --kill-after=2s "${limit}s" "$@"
}

# Coalesce duplicate callers for this instance without blocking unrelated
# Proton tunnels. Each tunnel has its own NAT-PMP gateway and lease.
exec 201>"$LOCK_FILE"
run_bounded "$ALLOCATION_TIMEOUT_SECONDS" flock -w "$QBT_ALLOC_LOCK_WAIT_SECONDS" 201

if ! run_bounded 5 systemctl --no-block start "proton-port-forward@${INSTANCE}.service"; then
	echo "ERROR: Could not confirm the port-forward start request; any queued systemd job is not canceled." >&2
	exit 1
fi

lease_ready=0
for ((wait_try = 0; wait_try < WAIT_TRIES && SECONDS < ALLOCATION_DEADLINE; wait_try++)); do
	if proton_lease_read >/dev/null && run_bounded 5 systemctl is-active --quiet "proton-port-forward@${INSTANCE}.service"; then
		lease_ready=1
		break
	fi
	delay="$WAIT_INTERVAL_SECONDS"
	remaining=$((ALLOCATION_DEADLINE - SECONDS))
	if ((delay > remaining)); then delay="$remaining"; fi
	if ((delay > 0)); then sleep "$delay"; fi
done

if ((lease_ready == 0)) || ! proton_lease_read >/dev/null; then
	echo "ERROR: No fresh lease from an active port-forward service for $INSTANCE within the allocation budget; queued jobs are not canceled." >&2
	echo "--- unit status for proton-port-forward@${INSTANCE}.service ---"
	run_bounded 5 systemctl status "proton-port-forward@${INSTANCE}.service" --no-pager || true
	echo "--- recent journal for proton-port-forward@${INSTANCE}.service (last 200 lines) ---"
	run_bounded 5 journalctl -u "proton-port-forward@${INSTANCE}.service" -n 200 --no-pager -o cat || true
	exit 1
fi

# Run the sync (this script will do its own locking for qB syncs)
run_bounded "$QBT_SYNC_TIMEOUT_SECONDS" "$QBITTORRENT_SYNC_SCRIPT" "$INSTANCE"

# Release lock implicitly on exit
exit 0
