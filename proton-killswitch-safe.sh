#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=proton-instance-common.sh
source "$SCRIPT_DIR/proton-instance-common.sh"

WG_PROFILE="${WG_PROFILE:-proton}"
VPN_IF="${VPN_IF:-${VPN_INTERFACE:-$WG_PROFILE}}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
DOCKER_NETWORK_CIDR6="${DOCKER_NETWORK_CIDR6:-}"
DOCKER_FORWARD_CHAIN="${DOCKER_FORWARD_CHAIN:-PROTON_DOCKER_FORWARD}"
NAT_CHAIN="${NAT_CHAIN:-PROTON_POSTROUTING}"
STATE_DIR="${STATE_DIR:-/run/proton}"
KILLSWITCH_LOCK_FILE="${KILLSWITCH_LOCK_FILE:-/run/proton/killswitch.lock}"
DOCKER_NETWORK_CIDR_STATE_FILE="${DOCKER_NETWORK_CIDR_STATE_FILE:-${STATE_DIR}/docker-network-cidr}"

log() {
	echo "$(date '+%F %T') | $*" | systemd-cat -t proton-killswitch
}

LAN_IF="${LAN_IF:-}"
LAN_CIDR="${LAN_CIDR:-}"
# Wait for BOTH the default-route interface and its connected subnet route.
# network-online.target can fire before DHCP has reinstalled the connected
# route (e.g. after a WAN IP change or reconnect), which previously left
# LAN_CIDR empty and failed the kill switch permanently. Retry both here.
if [[ -z "$LAN_IF" || -z "$LAN_CIDR" ]]; then
	for _i in 1 2 3 4 5 6 7 8 9 10; do
		if [[ -z "$LAN_IF" ]]; then
			LAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
		fi
		if [[ -n "$LAN_IF" && -z "$LAN_CIDR" ]]; then
			LAN_CIDR="$(ip -4 route show dev "$LAN_IF" | awk '$1 ~ /^[0-9]/ && $1 != "default" {print $1; exit}')"
		fi
		[[ -n "$LAN_IF" && -n "$LAN_CIDR" ]] && break
		log "Waiting for LAN interface/subnet route (attempt $_i/10)..."
		sleep 3
	done
fi

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

for cmd in awk cat chmod flock ip iptables iptables-save iptables-restore mkdir mktemp sort systemd-cat; do
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
ensure_directory "${KILLSWITCH_LOCK_FILE%/*}" 700

if ! proton_firewall_lock_acquire; then
	log "ERROR: Timed out waiting for kill-switch lock: $KILLSWITCH_LOCK_FILE"
	exit 1
fi

if [[ -z "$DOCKER_NETWORK_CIDR" && -f "$DOCKER_NETWORK_CIDR_STATE_FILE" ]]; then
	DOCKER_NETWORK_CIDR="$(cat "$DOCKER_NETWORK_CIDR_STATE_FILE" 2>/dev/null || true)"
fi

if [[ -n "$DOCKER_NETWORK_CIDR6" ]]; then
	log "ERROR: Docker IPv6 requires KILLSWITCH_BACKEND=nftables; the iptables backend refuses to continue"
	exit 1
fi

if [[ -z "${DOCKER_NETWORK_CIDR//[[:space:],]/}" ]]; then
	log "ERROR: Docker CIDR is required; preserving the existing firewall"
	exit 1
fi

require_value() {
	local name="$1"
	local value="$2"

	if [[ -z "$value" ]]; then
		log "ERROR: Missing required value for $name"
		exit 1
	fi
}

add_docker_local_rules() {
	local source_cidr target_cidr

	for source_cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$source_cidr" ]] || continue

		for target_cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
			[[ -n "$target_cidr" ]] || continue
			iptables -A "$DOCKER_FORWARD_CHAIN" -s "$source_cidr" -d "$target_cidr" -j ACCEPT
		done
	done
}

add_lan_to_docker_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		iptables -A "$DOCKER_FORWARD_CHAIN" -i "$LAN_IF" -s "$LAN_CIDR" -d "$cidr" -j ACCEPT
	done
}

add_vpn_to_docker_rules() {
	local cidr
	local interface

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		for interface in $VPN_INTERFACES; do
			iptables -A "$DOCKER_FORWARD_CHAIN" -i "$interface" -d "$cidr" -j ACCEPT
		done
	done
}

add_docker_to_lan_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -o "$LAN_IF" -d "$LAN_CIDR" -p tcp --dport 53 -j DROP
		iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -o "$LAN_IF" -d "$LAN_CIDR" -p udp --dport 53 -j DROP
		iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -o "$LAN_IF" -d "$LAN_CIDR" -j ACCEPT
	done
}

add_docker_to_vpn_rules() {
	local cidr
	local interface

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		for interface in $VPN_INTERFACES; do
			iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -o "$interface" -j ACCEPT
		done
	done
}

add_docker_drop_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -j DROP
		iptables -A "$DOCKER_FORWARD_CHAIN" -d "$cidr" -j DROP
	done
}

require_value "LAN_IF" "$LAN_IF"
require_value "LAN_CIDR" "$LAN_CIDR"

[[ "$VPN_IF" =~ ^[a-zA-Z0-9_-]{1,15}$ ]] || exit 1
mapfile -t PROTON_INSTANCES < <(proton_allowed_instances)
VPN_INTERFACES="$(printf '%s\n' "$VPN_IF" "${PROTON_INSTANCES[@]/#/pv}" | sort -u)"
FILTER_SNAPSHOT="$(iptables-save -t filter)"
NAT_SNAPSHOT="$(iptables-save -t nat)"
BATCH="$(mktemp)"
trap 'rm -f "$BATCH"' EXIT
iptables() { printf '%s\n' "$*"; }
{
	printf '*filter\n:%s - [0:0]\n-F %s\n' "$DOCKER_FORWARD_CHAIN" "$DOCKER_FORWARD_CHAIN"
	awk -v chain="$DOCKER_FORWARD_CHAIN" '$0 == "-A FORWARD -j " chain { print "-D FORWARD -j " chain }' <<<"$FILTER_SNAPSHOT"
	printf '%s\n' "-I FORWARD 1 -j $DOCKER_FORWARD_CHAIN"
	iptables -A "$DOCKER_FORWARD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	add_docker_local_rules
	add_lan_to_docker_rules
	add_vpn_to_docker_rules
	add_docker_to_lan_rules
	add_docker_to_vpn_rules
	add_docker_drop_rules
	iptables -A "$DOCKER_FORWARD_CHAIN" -j RETURN
	printf 'COMMIT\n*nat\n:%s - [0:0]\n-F %s\n' "$NAT_CHAIN" "$NAT_CHAIN"
	awk -v chain="$NAT_CHAIN" '$0 == "-A POSTROUTING -j " chain { print "-D POSTROUTING -j " chain }' <<<"$NAT_SNAPSHOT"
	printf '%s\n' "-I POSTROUTING 1 -j $NAT_CHAIN"
	for interface in $VPN_INTERFACES; do
		iptables -A "$NAT_CHAIN" -o "$interface" -j MASQUERADE
	done
	printf 'COMMIT\n'
} >"$BATCH"
iptables-restore --wait 30 --noflush --test <"$BATCH"
iptables-restore --wait 30 --noflush <"$BATCH"

log "iptables Docker kill switch applied for [$DOCKER_NETWORK_CIDR] on $LAN_IF -> $VPN_IF; DNS to LAN is blocked and non-Docker host traffic is untouched"
