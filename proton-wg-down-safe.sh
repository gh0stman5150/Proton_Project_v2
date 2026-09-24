#!/usr/bin/env bash
set -euo pipefail

if [[ "${2:-}" != --bounded-stop ]]; then
	STOP_TIMEOUT_SECONDS="${PROTON_WG_STOP_TIMEOUT_SECONDS:-45}"
	if [[ ! "$STOP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]?$ ]] || ((STOP_TIMEOUT_SECONDS > 45)); then
		echo "ERROR: PROTON_WG_STOP_TIMEOUT_SECONDS must be between 1 and 45." >&2
		exit 1
	fi
	exec timeout --kill-after=5s "${STOP_TIMEOUT_SECONDS}s" bash "${BASH_SOURCE[0]}" "${1:-}" --bounded-stop
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_COMMON_SCRIPT="${PROTON_INSTANCE_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-instance-common.sh}"
if [[ ! -f "$INSTANCE_COMMON_SCRIPT" ]]; then
	echo "ERROR: Proton instance helper not found: $INSTANCE_COMMON_SCRIPT" >&2
	exit 1
fi
# shellcheck disable=SC1090
source "$INSTANCE_COMMON_SCRIPT"
proton_instance_init "${1:-}"

LOG_TAG="${LOG_TAG:-proton-wg}"
WG_PROFILE="${WG_PROFILE:-proton}"
VPN_INTERFACE="${VPN_INTERFACE:-$WG_PROFILE}"
WG_RUNTIME_DIR="${WG_RUNTIME_DIR:-/etc/wireguard/proton-runtime}"
# run_wg_quick in proton-instance-common.sh reads this.
# shellcheck disable=SC2034
WG_QUICK_TIMEOUT_SECONDS=90
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/${WG_PROFILE}.conf}"
FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
VPN_FWMARK="${VPN_FWMARK:-0xca6c}"
VPN_TABLE="${VPN_TABLE:-51820}"
WG_IPV6_ENABLED="${WG_IPV6_ENABLED:-off}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
DOCKER_NETWORK_CIDR6="${DOCKER_NETWORK_CIDR6:-}"
QBT_CONTAINER_NAME="${QBT_CONTAINER_NAME:-}"
QBT_NETWORK_NAME="${QBT_NETWORK_NAME:-}"
QBT_CONTAINER_IP_STATE_FILE="${QBT_CONTAINER_IP_STATE_FILE:-${STATE_DIR}/qbt-container-ip}"
QBT_CONTAINER_IP6_STATE_FILE="${QBT_CONTAINER_IP6_STATE_FILE:-${STATE_DIR}/qbt-container-ip6}"
DOCKER_VPN_RULE_PRIORITY="${DOCKER_VPN_RULE_PRIORITY:-110}"
QBT_VPN_RULE_PRIORITY="${QBT_VPN_RULE_PRIORITY:-$DOCKER_VPN_RULE_PRIORITY}"
DOCKER_FALLBACK_VPN_RULE_PRIORITY="${DOCKER_FALLBACK_VPN_RULE_PRIORITY:-130}"
MANAGE_RESOLVED_DNS="${MANAGE_RESOLVED_DNS:-auto}"

mkdir -p "$STATE_DIR"
if [[ "${PROTON_LIFECYCLE_LOCK_FD:-}" != 205 || ! /proc/self/fd/205 -ef "${STATE_DIR}/lifecycle.lock" ]]; then
	exec 205>"${STATE_DIR}/lifecycle.lock"
fi
flock -w "${PROTON_LIFECYCLE_WAIT_SECONDS:-30}" 205
rm -f "$STATE_FILE" "${STATE_DIR}/tunnel-generation"
trap proton_route_lock_release EXIT

log() {
	local message
	message="$(date '+%F %T') | $*"

	if command -v systemd-cat >/dev/null 2>&1; then
		echo "$message" | systemd-cat -t "$LOG_TAG"
	else
		echo "$message" >&2
	fi
}

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

ipv6_enabled() {
	case "$WG_IPV6_ENABLED" in
	1 | true | yes | on)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

teardown_resolved_dns() {
	local ifname="$1"

	resolved_dns_enabled || return 0
	[[ -n "$ifname" ]] || return 0

	# resolved drops this link's cache on revert. A global flush-caches would
	# also empty the other tunnels' caches, so there is none.
	timeout --kill-after=2s 5s resolvectl revert "$ifname" >/dev/null 2>&1
}

for cmd in cat chmod flock ip mktemp rm timeout wg wg-quick; do
	require_command "$cmd"
done

if [[ -z "$DOCKER_NETWORK_CIDR" && -f "$DOCKER_NETWORK_CIDR_STATE_FILE" ]]; then
	DOCKER_NETWORK_CIDR="$(cat "$DOCKER_NETWORK_CIDR_STATE_FILE" 2>/dev/null || true)"
fi

if [[ -f "$SERVER_SELECTION_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$SERVER_SELECTION_FILE"
	WG_CONFIG="${SELECTED_CONFIG:-$WG_CONFIG}"
	FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
fi

# Remove Docker policy routing before tearing down the interface so
# forwarded container traffic cannot fall back to stale routes. Shared
# Docker<->Docker and Docker<->LAN main-table rules are intentionally left in
# place because other Proton instances may still be active on the same bridge.
QBT_CONTAINER_IP="$(resolve_qbt_container_ip || true)"
QBT_CONTAINER_IPV6="$(resolve_qbt_container_ipv6 || true)"
if ! proton_route_lock_acquire; then
	log "ERROR: Could not acquire the shared policy-route lock for $INSTANCE"
	exit 1
fi
CACHED_QBT_CONTAINER_IP="$(read_cached_qbt_container_ip || true)"
for source_ip in "$QBT_CONTAINER_IP" "$CACHED_QBT_CONTAINER_IP"; do
	source_rule="$(normalize_ipv4_rule_source "$source_ip" || true)"
	[[ -n "$source_rule" ]] || continue
	proton_delete_ip_rule_all 4 from "$source_rule" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY"
done

proton_delete_ip_rule_all 4 fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100
proton_delete_ip_rule_all 4 not fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100
proton_flush_route_table 4 "$VPN_TABLE"
if ipv6_enabled; then
	CACHED_QBT_CONTAINER_IPV6="$(read_cached_qbt_container_ipv6 || true)"
	for source_ip in "$QBT_CONTAINER_IPV6" "$CACHED_QBT_CONTAINER_IPV6"; do
		source_rule="$(normalize_ipv6_rule_source "$source_ip" || true)"
		[[ -n "$source_rule" ]] || continue
		proton_delete_ip_rule_all 6 from "$source_rule" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY"
	done
	for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
		[[ -n "$cidr" ]] || continue
		proton_delete_ip_rule_all 6 from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY"
	done
	proton_delete_ip_rule_all 6 oif "$VPN_INTERFACE" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY"
	proton_flush_route_table 6 "$VPN_TABLE"
fi
if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		proton_delete_ip_rule_all 4 from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_VPN_RULE_PRIORITY"
		proton_delete_ip_rule_all 4 from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY"

		if command -v iptables >/dev/null 2>&1; then
			proton_iptables_rule remove raw PREROUTING -i "$VPN_INTERFACE" -d "$cidr" -j ACCEPT
		fi
	done
fi

if command -v iptables >/dev/null 2>&1; then
	proton_iptables_rule remove mangle FORWARD -o "$VPN_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	proton_iptables_rule remove mangle FORWARD -i "$VPN_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi

proton_route_lock_release

interfaces="$(timeout --kill-after=2s 5s wg show interfaces)"
if [[ " $interfaces " == *" $VPN_INTERFACE "* ]]; then
	teardown_resolved_dns "$VPN_INTERFACE"
	if [[ -f "$FILTERED_CONFIG_PATH" ]]; then
		run_wg_quick down "$FILTERED_CONFIG_PATH"
	elif [[ -f "$WG_CONFIG" ]]; then
		run_wg_quick down "$WG_CONFIG"
	else
		run_wg_quick down "$WG_PROFILE"
	fi
fi
rm -f "$DOCKER_NETWORK_CIDR_STATE_FILE" "$QBT_CONTAINER_IP_STATE_FILE" "$QBT_CONTAINER_IP6_STATE_FILE"
