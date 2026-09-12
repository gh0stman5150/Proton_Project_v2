#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${QBT_BIN_DIR:-/usr/local/bin/proton}"
MANIFEST_FILE="${QBT_INSTANCE_MANIFEST:-/opt/qbittorrent-common/qbittorrent-instances.tsv}"
VERIFY_SCRIPT="${QBT_FLEET_VERIFY_SCRIPT:-${BIN_DIR}/proton-qbt-fleet-verify.sh}"
SYNC_SCRIPT="${QBT_SYNC_SCRIPT:-${BIN_DIR}/proton-qbittorrent-sync-safe.sh}"
INSTANCE_COMMON_SCRIPT="${PROTON_INSTANCE_COMMON_SCRIPT:-${BIN_DIR}/proton-instance-common.sh}"
HEALTH_TRIES="${QBT_RECREATE_HEALTH_TRIES:-12}"
HEALTH_DELAY="${QBT_RECREATE_HEALTH_DELAY:-5}"
PORT_TRIES="${QBT_RECREATE_PORT_TRIES:-40}"
PORT_DELAY="${QBT_RECREATE_PORT_DELAY:-3}"
START_TIMEOUT="${QBT_RECREATE_START_TIMEOUT:-120}"

usage() {
	cat <<'EOF'
Usage: recreate-qbittorrent-fleet.sh --bootstrap

Recreate all five managed qBittorrent containers when one or more containers
are absent. Each instance is restored sequentially from its current Proton
lease. This command requires root and uses the installed synchronizer; it does
not run docker run or an unqualified docker compose command.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi
if [[ "${1:-}" != "--bootstrap" || "${2:-}" != "" ]]; then
	usage >&2
	exit 2
fi
if ((EUID != 0)); then
	echo "ERROR: --bootstrap must run as root." >&2
	exit 1
fi
if [[ ! -x "$VERIFY_SCRIPT" ]]; then
	echo "ERROR: Fleet verifier is not executable: $VERIFY_SCRIPT" >&2
	exit 1
fi
if [[ ! -x "$SYNC_SCRIPT" ]]; then
	echo "ERROR: qBittorrent sync script is not executable: $SYNC_SCRIPT" >&2
	exit 1
fi
if [[ ! -f "$INSTANCE_COMMON_SCRIPT" ]]; then
	echo "ERROR: Proton instance helper not found: $INSTANCE_COMMON_SCRIPT" >&2
	exit 1
fi
if [[ ! -r "$MANIFEST_FILE" ]]; then
	echo "ERROR: Instance manifest is missing or unreadable: $MANIFEST_FILE" >&2
	exit 1
fi
if [[ ! "$HEALTH_TRIES" =~ ^[0-9]+$ ]] || ((HEALTH_TRIES < 1)); then
	echo "ERROR: QBT_RECREATE_HEALTH_TRIES must be a positive integer." >&2
	exit 2
fi
if [[ ! "$HEALTH_DELAY" =~ ^[0-9]+$ ]]; then
	echo "ERROR: QBT_RECREATE_HEALTH_DELAY must be a non-negative integer." >&2
	exit 2
fi
if [[ ! "$PORT_TRIES" =~ ^[0-9]+$ ]] || ((PORT_TRIES < 1)); then
	echo "ERROR: QBT_RECREATE_PORT_TRIES must be a positive integer." >&2
	exit 2
fi
if [[ ! "$PORT_DELAY" =~ ^[0-9]+$ ]]; then
	echo "ERROR: QBT_RECREATE_PORT_DELAY must be a non-negative integer." >&2
	exit 2
fi
if [[ ! "$START_TIMEOUT" =~ ^[0-9]+$ ]] || ((START_TIMEOUT < 1)); then
	echo "ERROR: QBT_RECREATE_START_TIMEOUT must be a positive integer." >&2
	exit 2
fi

if ! command -v timeout >/dev/null 2>&1; then
	echo "ERROR: Required command 'timeout' is not installed." >&2
	exit 1
fi

"$VERIFY_SCRIPT" --config

# shellcheck disable=SC1090
source "$INSTANCE_COMMON_SCRIPT"

QBT_COMMON_SCRIPT="${QBT_COMMON_SCRIPT:-${BIN_DIR}/proton-qbittorrent-common.sh}"
# shellcheck disable=SC1090
source "$QBT_COMMON_SCRIPT"
qbt_fleet_preflight "$MANIFEST_FILE" 1

instances=()
while IFS=$'\t' read -r instance _; do
	[[ -n "$instance" && "$instance" != \#* ]] || continue
	instances+=("$instance")
done <"$MANIFEST_FILE"

recreate_instance() (
	local instance="$1"
	local container
	local port_env
	local override_env
	local state_file
	local health=""
	local attempt

	proton_instance_init "$instance" || return 1
	port_env="$QBITTORRENT_ENV_FILE"
	# shellcheck disable=SC2153 # STATE_FILE is populated by the sourced instance helper.
	state_file="$STATE_FILE"
	container="${QBT_CONTAINER_NAME:-qbittorrent-${instance}}"

	if [[ "${QBT_PORT_APPLY_MODE:-compose-recreate}" != "compose-recreate" ]]; then
		echo "ERROR: $instance must use QBT_PORT_APPLY_MODE=compose-recreate for bootstrap." >&2
		return 1
	fi
	if [[ ! -r "$port_env" ]]; then
		echo "ERROR: qBittorrent environment is missing or unreadable: $port_env" >&2
		return 1
	fi

	override_env="$(mktemp)" || return 1
	trap 'rm -f "$override_env"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	chmod 0600 "$override_env" || return 1
	awk '
		$0 ~ /^[[:space:]]*QBT_RESPECT_MANUAL_STOP=/ { next }
		$0 ~ /^[[:space:]]*QBT_FORCE_RECREATE=/ { next }
		{ print }
	' "$port_env" >"$override_env" || return 1
	printf '%s\n' 'QBT_RESPECT_MANUAL_STOP=0' 'QBT_FORCE_RECREATE=1' >>"$override_env" || return 1

	echo "=== Recreating $container from its current Proton lease ==="
	echo "Starting proton-port-forward@${instance}.service (timeout ${START_TIMEOUT}s)..."
	if ! timeout --foreground "${START_TIMEOUT}s" systemctl start "proton-port-forward@${instance}.service"; then
		echo "ERROR: proton-port-forward@${instance}.service did not start." >&2
		systemctl status "proton-wg@${instance}.service" "proton-port-forward@${instance}.service" --no-pager -l || true
		return 1
	fi
	if ! systemctl is-active --quiet "proton-port-forward@${instance}.service"; then
		echo "ERROR: proton-port-forward@${instance}.service is not active after start." >&2
		systemctl status "proton-wg@${instance}.service" "proton-port-forward@${instance}.service" --no-pager -l || true
		return 1
	fi
	echo "Waiting for the live Proton port state..."
	for ((attempt = 1; attempt <= PORT_TRIES; attempt++)); do
		proton_lease_read "$state_file" >/dev/null && break
		sleep "$PORT_DELAY"
	done
	if ! proton_lease_read "$state_file" >/dev/null; then
		echo "ERROR: Proton port state did not appear for $instance: $state_file" >&2
		return 1
	fi

	echo "Invoking the qBittorrent synchronizer..."
	QBITTORRENT_ENV_FILE="$override_env" "$SYNC_SCRIPT" "$instance" || return 1
	for ((attempt = 1; attempt <= HEALTH_TRIES; attempt++)); do
		health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
		[[ "$health" == healthy ]] && break
		sleep "$HEALTH_DELAY"
	done
	if [[ "$health" != healthy ]]; then
		echo "ERROR: $container did not become healthy (health=${health:-unknown})." >&2
		return 1
	fi
)

for instance in "${instances[@]}"; do
	recreate_instance "$instance" || exit 1
done

"$VERIFY_SCRIPT" --runtime
echo "All qBittorrent instances were recreated sequentially and passed runtime parity checks."