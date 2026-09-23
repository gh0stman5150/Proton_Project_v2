#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/proton-instance-common.sh" ]]; then SCRIPT_DIR="$(dirname "$SCRIPT_DIR")"; fi
# shellcheck source=proton-instance-common.sh
source "$SCRIPT_DIR/proton-instance-common.sh"

KILLSWITCH_BACKEND="${KILLSWITCH_BACKEND:-auto}"

cleanup_iptables() {
	local filter_snapshot nat_snapshot batch
	filter_snapshot="$(iptables-save -t filter)" || return 1
	nat_snapshot="$(iptables-save -t nat)" || return 1
	batch="$(
		printf '*filter\n'
		render_chain_removal "$filter_snapshot" INPUT PROTON_INPUT
		render_chain_removal "$filter_snapshot" OUTPUT PROTON_OUTPUT
		render_chain_removal "$filter_snapshot" FORWARD PROTON_DOCKER_FORWARD
		printf 'COMMIT\n*nat\n'
		render_chain_removal "$nat_snapshot" POSTROUTING PROTON_POSTROUTING
		printf 'COMMIT\n'
	)" || return 1
	iptables-restore --wait 30 --noflush --test <<<"$batch" || return 1
	iptables-restore --wait 30 --noflush <<<"$batch"
}

render_chain_removal() {
	local snapshot="$1" parent="$2" chain="$3"
	awk -v parent="$parent" -v chain="$chain" '
        $0 == "-A " parent " -j " chain { print "-D " parent " -j " chain }
        $1 == ":" chain { found=1 }
        END { if (found) { print "-F " chain; print "-X " chain } }
    ' <<<"$snapshot"
}

cleanup_nft() {
	local tables batch="" rules
	tables="$(nft list tables)" || return 1
	if grep -Fxq 'table inet proton' <<<"$tables"; then batch='delete table inet proton'; fi
	proton_nft_chain_snapshot ip proton_nat postrouting || return 1
	rules="$(proton_nft_delete_comment_rules ip proton_nat postrouting proton-wg-snat "$PROTON_NFT_RULES")" || return 1
	batch+=$'\n'"$rules"
	proton_nft_chain_snapshot ip6 proton_nat6 postrouting || return 1
	rules="$(proton_nft_delete_comment_rules ip6 proton_nat6 postrouting proton-wg-snat6 "$PROTON_NFT_RULES")" || return 1
	batch+=$'\n'"$rules"
	if [[ -n "${batch//[$'\n\t ']/}" ]]; then nft -f - <<<"$batch" || return 1; fi
}

case "$KILLSWITCH_BACKEND" in
iptables)
	proton_with_firewall_lock cleanup_iptables
	;;
nft | nftables)
	proton_with_firewall_lock cleanup_nft
	;;
auto)
	if command -v nft >/dev/null 2>&1; then
		proton_with_firewall_lock cleanup_nft
	elif command -v iptables >/dev/null 2>&1; then
		proton_with_firewall_lock cleanup_iptables
	else
		exit 1
	fi
	;;
*)
	printf 'ERROR: Unknown kill-switch backend: %s\n' "$KILLSWITCH_BACKEND" >&2
	exit 1
	;;
esac
