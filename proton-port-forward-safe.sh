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

if [[ $# -gt 2 ]]; then
	echo "ERROR: Usage: ${0##*/} INSTANCE [loop|once]" >&2
	exit 1
fi

MODE="${2:-loop}"
WG_PROFILE="${WG_PROFILE:-proton}"
VPN_INTERFACE="${VPN_INTERFACE:-$WG_PROFILE}"
NATPMP_GATEWAY="${NATPMP_GATEWAY:-10.2.0.1}"
STATE_DIR="${STATE_DIR:-/run/proton}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/proton-port.state}"
LOG_TAG="${LOG_TAG:-proton-port}"
CHECK_INTERVAL="${CHECK_INTERVAL:-45}"
MAX_FAILURES="${MAX_FAILURES:-5}"
# When a server that has already proven it can forward ports hits MAX_FAILURES,
# the failure is treated as a transient NAT-PMP hiccup and the tunnel is kept in
# place (so the forwarded port -- and the qBittorrent container -- stay stable).
# After this many consecutive transient windows without a successful port, fall
# back to a full reconnect so a genuinely dead proven server still recovers.
PROVEN_TRANSIENT_MAX_KEEPS="${PROVEN_TRANSIENT_MAX_KEEPS:-5}"
PORT_LEASE_SECONDS="${PORT_LEASE_SECONDS:-60}"
NATPMP_TIMEOUT_SECONDS="${NATPMP_TIMEOUT_SECONDS:-15}"
NATPMP_LOCK_WAIT_SECONDS="${NATPMP_LOCK_WAIT_SECONDS:-5}"
QBT_SYNC_TIMEOUT_SECONDS="${QBT_SYNC_TIMEOUT_SECONDS:-120}"
NATPMP_KILL_AFTER_SECONDS=2
LEASE_RENEW_MARGIN_SECONDS=5
for setting in CHECK_INTERVAL PORT_LEASE_SECONDS NATPMP_TIMEOUT_SECONDS NATPMP_LOCK_WAIT_SECONDS QBT_SYNC_TIMEOUT_SECONDS; do
	if [[ ! "${!setting}" =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
		echo "ERROR: $setting must be a non-negative integer." >&2
		exit 1
	fi
done
RENEW_BUDGET_SECONDS=$((2 * NATPMP_LOCK_WAIT_SECONDS + 2 * (NATPMP_TIMEOUT_SECONDS + NATPMP_KILL_AFTER_SECONDS) + LEASE_RENEW_MARGIN_SECONDS))
if ((NATPMP_TIMEOUT_SECONDS < 1 || QBT_SYNC_TIMEOUT_SECONDS < 1 || PORT_LEASE_SECONDS <= RENEW_BUDGET_SECONDS)); then
	echo "ERROR: PORT_LEASE_SECONDS must exceed the NAT-PMP renewal budget ($RENEW_BUDGET_SECONDS seconds)." >&2
	exit 1
fi
RENEW_INTERVAL_SECONDS=$((PORT_LEASE_SECONDS - RENEW_BUDGET_SECONDS))
if ((CHECK_INTERVAL < RENEW_INTERVAL_SECONDS)); then RENEW_INTERVAL_SECONDS="$CHECK_INTERVAL"; fi
WG_UP_SCRIPT="${WG_UP_SCRIPT:-/usr/local/bin/proton/proton-wg-up-safe.sh}"
QBITTORRENT_SYNC_SCRIPT="${QBITTORRENT_SYNC_SCRIPT:-/usr/local/bin/proton/proton-qbittorrent-sync-safe.sh}"
SERVER_POOL_ENABLED="${SERVER_POOL_ENABLED:-auto}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
RECOVERY_LOCK_FILE="${RECOVERY_LOCK_FILE:-${STATE_DIR}/recovery.lock}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
PF_CAPABLE_PROFILES_FILE="${PF_CAPABLE_PROFILES_FILE:-/etc/proton/pf-capable-profiles.tsv}"
CURRENT_WG_PROFILE="$WG_PROFILE"

log() {
	echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOG_TAG"
}

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

for cmd in awk cat chmod cut date flock grep ip mkdir mktemp mv natpmpc rm sleep systemd-cat timeout; do
	require_command "$cmd"
done

ensure_directory() {
	local dir="$1"
	local mode="${2:-}"
	local created=0

	if [[ ! -d "$dir" ]]; then
		mkdir -p "$dir"
		created=1
	fi

	if ((created)) && [[ -n "$mode" ]]; then
		chmod "$mode" "$dir"
	fi
}

ensure_directory "$STATE_DIR" 700

case "$MODE" in
loop | once) ;;
*)
	log "ERROR: Unsupported mode '$MODE' (expected 'loop' or 'once')"
	exit 1
	;;
esac

server_pool_requested() {
	case "$SERVER_POOL_ENABLED" in
	1 | true | yes | on)
		return 0
		;;
	auto)
		compgen -G "$WG_POOL_DIR/*.conf" >/dev/null
		;;
	*)
		return 1
		;;
	esac
}

load_selected_server() {
	if ! server_pool_requested; then
		CURRENT_WG_PROFILE="$WG_PROFILE"
		return 0
	fi

	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$SERVER_SELECTION_FILE"
		# CURRENT_WG_PROFILE tracks the selected SERVER for pool health
		# reporting (mark-bad/mark-capable). VPN_INTERFACE stays the
		# per-instance interface name from proton.env so get_ip and the
		# per-instance NAT-PMP gateway route resolve to this instance's tunnel
		# even when two instances pick the same Proton server.
		CURRENT_WG_PROFILE="${SELECTED_WG_PROFILE:-$WG_PROFILE}"
	else
		CURRENT_WG_PROFILE="$WG_PROFILE"
	fi
}

profile_in_state_file() {
	local file="$1"
	local profile="$2"

	[[ -f "$file" ]] || return 1

	awk -F '\t' -v profile="$profile" '
        $1 == profile { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$file"
}

profile_is_known_capable() {
	local profile="$1"

	[[ -n "$profile" ]] || return 1
	profile_in_state_file "$PF_CAPABLE_PROFILES_FILE" "$profile"
}

get_ip() {
	ip -4 addr show "$VPN_INTERFACE" 2>/dev/null |
		awk '/inet / {print $2}' | cut -d/ -f1 || true
}

request_port() {
	refresh_port 0
}

refresh_port() (
	local port="$1"
	local udp_output tcp_output udp_port tcp_port generation started udp_lifetime tcp_lifetime lifetime
	exec 203>"${STATE_DIR}/lifecycle.lock" || return 1
	flock -w "$NATPMP_LOCK_WAIT_SECONDS" 203 || return 1
	exec 202>"${STATE_DIR}/natpmp.lock" || return 1
	flock -w "$NATPMP_LOCK_WAIT_SECONDS" 202 || return 1
	generation="$(cat "${STATE_DIR}/tunnel-generation")" || return 1
	started="$(date +%s)" || return 1
	udp_output="$(timeout --kill-after="${NATPMP_KILL_AFTER_SECONDS}s" "${NATPMP_TIMEOUT_SECONDS}s" natpmpc -a 1 "$port" udp "$PORT_LEASE_SECONDS" -g "$NATPMP_GATEWAY")" || return 1
	udp_port="$(extract_port <<<"$udp_output")"
	[[ "$udp_port" =~ ^[1-9][0-9]{0,4}$ ]] && ((udp_port <= 65535)) || return 1
	udp_lifetime="$(extract_lifetime <<<"$udp_output")" || return 1
	tcp_output="$(timeout --kill-after="${NATPMP_KILL_AFTER_SECONDS}s" "${NATPMP_TIMEOUT_SECONDS}s" natpmpc -a 1 "$udp_port" tcp "$PORT_LEASE_SECONDS" -g "$NATPMP_GATEWAY")" || return 1
	tcp_port="$(extract_port <<<"$tcp_output")"
	[[ "$tcp_port" == "$udp_port" && "$generation" == "$(cat "${STATE_DIR}/tunnel-generation")" ]] || return 1
	tcp_lifetime="$(extract_lifetime <<<"$tcp_output")" || return 1
	lifetime="$PORT_LEASE_SECONDS"
	if ((udp_lifetime < lifetime)); then lifetime="$udp_lifetime"; fi
	if ((tcp_lifetime < lifetime)); then lifetime="$tcp_lifetime"; fi
	save_state "$tcp_port" "$(get_ip)" "$generation" "$started" "$lifetime" || return 1
	printf '%s\n' "$tcp_output"
)

extract_port() {
	awk '/Mapped public port/ {print $4; exit}' || true
}

extract_lifetime() {
	local lifetime
	lifetime="$(awk '/Mapped public port/ { for (field = 1; field < NF; field++) if ($field == "lifetime") { print $(field + 1); exit } }')" || return 1
	[[ "$lifetime" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
	printf '%s\n' "$lifetime"
}

save_state() {
	local new_port="$1"
	local new_ip="$2"
	local generation="$3" started="$4" lifetime="$5"
	local current_port current_ip changed temporary boot now

	now="$(date +%s)" || return 1
	((started + lifetime > now + LEASE_RENEW_MARGIN_SECONDS)) || return 1
	[[ -n "$new_ip" && "$new_ip" == "${WG_TUNNEL_ADDRESS%%/*}" ]] || return 1
	boot="$(cat /proc/sys/kernel/random/boot_id)" || return 1

	current_port="$(load_state_port)"
	current_ip="$(load_state_ip)"

	changed="$(awk -F= '$1 == "PORT_CHANGED_AT" { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)"
	if [[ "$current_port" != "$new_port" || "$current_ip" != "$new_ip" || -z "$changed" ]]; then changed="$started"; fi

	umask 077
	temporary="$(mktemp "${STATE_FILE}.XXXXXX")" || return 1
	{
		echo "CURRENT_PORT=$new_port"
		echo "CURRENT_IP=$new_ip"
		echo "LEASE_EXPIRES_AT=$((started + lifetime))"
		echo "LEASE_BOOT_ID=$boot"
		echo "LEASE_GENERATION=$generation"
		echo "PORT_CHANGED_AT=$changed"
	} >"$temporary" || { rm -f "$temporary"; return 1; }
	mv -f "$temporary" "$STATE_FILE" || { rm -f "$temporary"; return 1; }
}

load_state_port() {
	awk -F= '/^CURRENT_PORT=/ {print $2; exit}' "$STATE_FILE" 2>/dev/null || true
}

load_state_ip() {
	awk -F= '/^CURRENT_IP=/ {print $2; exit}' "$STATE_FILE" 2>/dev/null || true
}

reconnect() {
	local failed_profile="${1:-$CURRENT_WG_PROFILE}"

	(
		flock -n 200 || {
			log "Recovery lock busy, skipping reconnect"
			exit 0
		}

		log "Recycling WireGuard tunnel..."

		if [[ -z "$failed_profile" ]]; then
			load_selected_server
			failed_profile="$CURRENT_WG_PROFILE"
		fi

		if server_pool_requested && [[ -x "$SERVER_MANAGER_SCRIPT" ]]; then
			timeout --kill-after=2s 3s "$SERVER_MANAGER_SCRIPT" mark-bad "$failed_profile" "port-forward-failures" >/dev/null 2>&1 || true
		fi

		PROTON_FORCE_RECONNECT=1 timeout --kill-after=5s 120s "$WG_UP_SCRIPT" "$INSTANCE"
		sleep 5
	) 200>"$RECOVERY_LOCK_FILE"
}

if [[ "$MODE" == "once" ]]; then
	log "Starting one-shot NAT-PMP refresh..."
else
	log "Starting WireGuard port forward loop..."
fi

LAST_IP="$(load_state_ip)"
CURRENT_PORT="$(proton_lease_read || true)"
FAILURES=0
TRANSIENT_KEEPS=0

load_selected_server

if [[ "$MODE" == "once" ]]; then
	load_selected_server
	IP="$(get_ip)"

	if [[ -z "$IP" ]]; then
		log "No VPN IP; one-shot NAT-PMP refresh cannot run"
		exit 1
	fi

	if [[ "$IP" != "$LAST_IP" ]]; then
		log "VPN IP changed: ${LAST_IP:-unknown} -> $IP"
		LAST_IP="$IP"
		CURRENT_PORT=""
	fi

	if [[ -n "$CURRENT_PORT" ]]; then
		log "Refreshing port $CURRENT_PORT..."
		OUT="$(refresh_port "$CURRENT_PORT" || true)"
	else
		log "Requesting new port..."
		OUT="$(request_port || true)"
	fi

	PORT="$(echo "$OUT" | extract_port)"

	if [[ -z "$PORT" ]]; then
		log "One-shot NAT-PMP refresh failed"
		if [[ -n "$OUT" ]]; then
			log "Last NAT-PMP output: ${OUT//$'\n'/; }"
		fi
		exit 1
	fi

	log "Got port: $PORT"
	if ! timeout --kill-after=2s "${QBT_SYNC_TIMEOUT_SECONDS}s" "$QBITTORRENT_SYNC_SCRIPT" "$INSTANCE"; then
		log "ERROR: qBittorrent port sync failed during one-shot NAT-PMP refresh"
		exit 1
	fi

	exit 0
fi

SYNC_PID=""
cleanup_loop() {
	if [[ -n "$SYNC_PID" ]]; then
		kill -TERM "$SYNC_PID" 2>/dev/null || true
		wait "$SYNC_PID" 2>/dev/null || true
	fi
}
trap cleanup_loop EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

while true; do
	ITERATION_STARTED="$SECONDS"
	load_selected_server
	IP="$(get_ip)"

	if [[ -z "$IP" ]]; then
		log "No VPN IP, reconnecting..."
		reconnect "$CURRENT_WG_PROFILE"
		sleep "$CHECK_INTERVAL"
		continue
	fi

	if [[ "$IP" != "$LAST_IP" ]]; then
		log "VPN IP changed: ${LAST_IP:-unknown} -> $IP"
		LAST_IP="$IP"
		CURRENT_PORT=""
		FAILURES=0
		TRANSIENT_KEEPS=0
	fi

	if [[ -n "$CURRENT_PORT" ]]; then
		log "Refreshing port $CURRENT_PORT..."
		OUT="$(refresh_port "$CURRENT_PORT" || true)"
	else
		log "Requesting new port..."
		OUT="$(request_port || true)"
	fi

	PORT="$(echo "$OUT" | extract_port)"

	if [[ -n "$PORT" ]]; then
		log "Got port: $PORT"
		CURRENT_PORT="$PORT"
		if server_pool_requested && [[ -x "$SERVER_MANAGER_SCRIPT" ]]; then
			timeout --kill-after=2s 3s "$SERVER_MANAGER_SCRIPT" mark-capable "$CURRENT_WG_PROFILE" "$PORT" >/dev/null 2>&1 || true
		fi
		if [[ -z "$SYNC_PID" ]] || ! kill -0 "$SYNC_PID" 2>/dev/null; then
			if [[ -n "$SYNC_PID" ]]; then wait "$SYNC_PID" || log "WARNING: qBittorrent port sync failed"; fi
			timeout --kill-after=2s "${QBT_SYNC_TIMEOUT_SECONDS}s" "$QBITTORRENT_SYNC_SCRIPT" "$INSTANCE" &
			SYNC_PID=$!
		fi
		FAILURES=0
		TRANSIENT_KEEPS=0
	else
		FAILURES=$((FAILURES + 1))
		log "Port request failed ($FAILURES/$MAX_FAILURES)"
		if [[ -n "$OUT" ]]; then
			log "Last NAT-PMP output: ${OUT//$'\n'/; }"
		fi
		CURRENT_PORT=""

		if ((FAILURES >= MAX_FAILURES)); then
			if server_pool_requested && [[ -x "$SERVER_MANAGER_SCRIPT" ]] &&
				profile_is_known_capable "$CURRENT_WG_PROFILE" &&
				((TRANSIENT_KEEPS < PROVEN_TRANSIENT_MAX_KEEPS)); then
				# Fix A: this server has already proven it can forward a port.
				# Intermittent NAT-PMP timeouts here are almost always a
				# transient Proton hiccup rather than a dead tunnel (the
				# WireGuard interface stays up). Reselecting a different server
				# would change the forwarded port and force qBittorrent's
				# published port -- and therefore its container -- to be
				# recreated. Keep the tunnel and retry in place so the port
				# stays stable.
				TRANSIENT_KEEPS=$((TRANSIENT_KEEPS + 1))
				log "Profile $CURRENT_WG_PROFILE previously forwarded successfully; keeping tunnel and retrying in place (transient NAT-PMP failure ${TRANSIENT_KEEPS}/${PROVEN_TRANSIENT_MAX_KEEPS})"
				CURRENT_PORT="$(proton_lease_read || true)"
				FAILURES=0
			else
				if server_pool_requested && [[ -x "$SERVER_MANAGER_SCRIPT" ]]; then
					# Record a consecutive port-forward incapability strike.
					# The server manager evicts a profile from the pool once it
					# accumulates PF_INCAPABLE_STRIKE_THRESHOLD consecutive
					# strikes (adds it to the incapable list and deletes its
					# pool config). Proven-good servers are never evicted this
					# way; the server manager cools them down instead.
					timeout --kill-after=2s 3s "$SERVER_MANAGER_SCRIPT" mark-incapable-attempt "$CURRENT_WG_PROFILE" "natpmp-timeout" >/dev/null 2>&1 || true
				fi
				log "Too many failures on ${CURRENT_WG_PROFILE:-$WG_PROFILE} -> reconnecting tunnel"
				reconnect "$CURRENT_WG_PROFILE"
				FAILURES=0
				LAST_IP=""
				TRANSIENT_KEEPS=0
			fi
		fi
	fi

	RENEW_DELAY=$((ITERATION_STARTED + RENEW_INTERVAL_SECONDS - SECONDS))
	if proton_lease_read >/dev/null; then
		LEASE_DELAY=$((PROTON_LEASE_EXPIRES_AT - $(date +%s) - RENEW_BUDGET_SECONDS))
		if ((LEASE_DELAY < RENEW_DELAY)); then RENEW_DELAY="$LEASE_DELAY"; fi
	fi
	if ((RENEW_DELAY > 0)); then sleep "$RENEW_DELAY"; fi
done
