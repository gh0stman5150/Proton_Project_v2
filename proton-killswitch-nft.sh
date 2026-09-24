#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=proton-instance-common.sh
source "$SCRIPT_DIR/proton-instance-common.sh"

WG_PROFILE="${WG_PROFILE:-proton}"
VPN_IF="${VPN_IF:-${VPN_INTERFACE:-$WG_PROFILE}}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
DOCKER_NETWORK_CIDR6="${DOCKER_NETWORK_CIDR6:-}"
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

for cmd in awk cat chmod flock grep ip mkdir nft sort systemd-cat; do
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

require_value() {
	local name="$1"
	local value="$2"

	if [[ -z "$value" ]]; then
		log "ERROR: Missing required value for $name"
		exit 1
	fi
}

ensure_nat_postrouting_chain() {
	local family="$1" table="$2" networks="$3" comment="$4" iface cidr
	proton_nft_chain_snapshot "$family" "$table" postrouting || return 1
	if [[ "$PROTON_NFT_TABLE_EXISTS" == 0 ]]; then printf 'add table %s %s\n' "$family" "$table"; fi
	if [[ "$PROTON_NFT_CHAIN_EXISTS" == 0 ]]; then
		printf 'add chain %s %s postrouting { type nat hook postrouting priority srcnat; policy accept; }\n' "$family" "$table"
	fi
	proton_nft_delete_comment_rules "$family" "$table" postrouting "$comment" "$PROTON_NFT_RULES" || return 1
	for iface in $VPN_INTERFACES; do
		for cidr in ${networks//,/ }; do
			printf 'add rule %s %s postrouting %s saddr %s oifname "%s" masquerade comment "%s"\n' "$family" "$table" "$family" "$cidr" "$iface" "$comment"
		done
	done
}

render_docker_local_rules() {
	local source_cidr target_cidr

	for source_cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$source_cidr" ]] || continue

		for target_cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
			[[ -n "$target_cidr" ]] || continue
			printf '        ip saddr %s ip daddr %s accept\n' "$source_cidr" "$target_cidr"
		done
	done
}

render_lan_to_docker_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		printf '        iifname "%s" ip saddr %s ip daddr %s accept\n' "$LAN_IF" "$LAN_CIDR" "$cidr"
	done
}

render_vpn_to_docker_rules() {
	local cidr iface

	for iface in $VPN_INTERFACES; do
		[[ -n "$iface" ]] || continue
		for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
			[[ -n "$cidr" ]] || continue
			printf '        iifname "%s" ip daddr %s accept\n' "$iface" "$cidr"
		done
	done
}

render_docker_to_lan_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		printf '        oifname "%s" ip saddr %s ip daddr %s tcp dport 53 drop\n' "$LAN_IF" "$cidr" "$LAN_CIDR"
		printf '        oifname "%s" ip saddr %s ip daddr %s udp dport 53 drop\n' "$LAN_IF" "$cidr" "$LAN_CIDR"
		printf '        oifname "%s" ip saddr %s ip daddr %s accept\n' "$LAN_IF" "$cidr" "$LAN_CIDR"
	done
}

render_docker_to_vpn_rules() {
	local cidr iface

	for iface in $VPN_INTERFACES; do
		[[ -n "$iface" ]] || continue
		for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
			[[ -n "$cidr" ]] || continue
			printf '        oifname "%s" ip saddr %s accept\n' "$iface" "$cidr"
		done
	done
}

render_docker_drop_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		[[ -n "$cidr" ]] || continue
		printf '        ip saddr %s drop\n' "$cidr"
		printf '        ip daddr %s drop\n' "$cidr"
	done
}

render_docker6_local_rules() {
	local source_cidr target_cidr

	for source_cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
		[[ -n "$source_cidr" ]] || continue
		for target_cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
			[[ -n "$target_cidr" ]] || continue
			printf '        ip6 saddr %s ip6 daddr %s accept\n' "$source_cidr" "$target_cidr"
		done
	done
}

render_vpn_to_docker6_rules() {
	local cidr iface

	for iface in $VPN_INTERFACES; do
		[[ -n "$iface" ]] || continue
		for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
			[[ -n "$cidr" ]] || continue
			printf '        iifname "%s" ip6 daddr %s accept\n' "$iface" "$cidr"
		done
	done
}

render_docker6_to_vpn_rules() {
	local cidr iface

	for iface in $VPN_INTERFACES; do
		[[ -n "$iface" ]] || continue
		for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
			[[ -n "$cidr" ]] || continue
			printf '        oifname "%s" ip6 saddr %s accept\n' "$iface" "$cidr"
		done
	done
}

render_docker6_drop_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
		[[ -n "$cidr" ]] || continue
		printf '        ip6 saddr %s drop\n' "$cidr"
		printf '        ip6 daddr %s drop\n' "$cidr"
	done
}

if [[ -z "${DOCKER_NETWORK_CIDR//[[:space:],]/}" ]]; then
	log "ERROR: Docker CIDR is required; preserving the existing firewall"
	exit 1
fi

require_value "LAN_IF" "$LAN_IF"
require_value "LAN_CIDR" "$LAN_CIDR"

[[ "$VPN_IF" =~ ^[a-zA-Z0-9_-]{1,15}$ ]] || exit 1
mapfile -t PROTON_INSTANCES < <(proton_allowed_instances)
VPN_INTERFACES="$(printf '%s\n' "$VPN_IF" "${PROTON_INSTANCES[@]/#/pv}" | sort -u)"
NAT_BATCH="$(ensure_nat_postrouting_chain ip proton_nat "$DOCKER_NETWORK_CIDR" proton-wg-snat)"
NAT6_BATCH=""
if [[ -n "$DOCKER_NETWORK_CIDR6" ]]; then
	NAT6_BATCH="$(ensure_nat_postrouting_chain ip6 proton_nat6 "$DOCKER_NETWORK_CIDR6" proton-wg-snat6)"
fi

FILTER_TABLE_DELETE=""
TABLES="$(nft list tables)"
if grep -Fxq 'table inet proton' <<<"$TABLES"; then
	FILTER_TABLE_DELETE="delete table inet proton"
fi

nft -f - <<EOF
$NAT_BATCH
$NAT6_BATCH
$FILTER_TABLE_DELETE
table inet proton {
    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
$(render_docker_local_rules)
$(render_lan_to_docker_rules)
$(render_vpn_to_docker_rules)
$(render_docker_to_lan_rules)
$(render_docker_to_vpn_rules)
$(render_docker_drop_rules)
$(render_docker6_local_rules)
$(render_vpn_to_docker6_rules)
$(render_docker6_to_vpn_rules)
$(render_docker6_drop_rules)
    }
}
EOF

log "nftables Docker kill switch applied for IPv4 [$DOCKER_NETWORK_CIDR] IPv6 [$DOCKER_NETWORK_CIDR6] on $LAN_IF -> $VPN_IF; DNS to LAN is blocked and non-Docker host traffic is untouched"
