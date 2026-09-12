#!/usr/bin/env bash

docker() {
	command timeout --foreground --kill-after=5s "${PROTON_DOCKER_TIMEOUT_SECONDS:-10}s" docker "$@"
}

proton_docker_ready() {
	timeout 5s systemctl is-active --quiet docker.service
}

proton_lease_read() {
	local file="${1:-$STATE_FILE}" generation current_boot now
	local key value count=0 octet
	local -a octets
	PROTON_LEASE_EXPIRES_AT=""
	local port="" address="" expires="" boot="" lease_generation=""
	[[ -r "$file" ]] || return 1
	while IFS='=' read -r key value; do
		case "$key" in
		CURRENT_PORT) port="$value"; count=$((count + 1)) ;;
		CURRENT_IP) address="$value"; count=$((count + 1)) ;;
		LEASE_EXPIRES_AT) expires="$value"; count=$((count + 1)) ;;
		LEASE_BOOT_ID) boot="$value"; count=$((count + 1)) ;;
		LEASE_GENERATION) lease_generation="$value"; count=$((count + 1)) ;;
		esac
	done <"$file"
	[[ "$count" == 5 && "$port" =~ ^[1-9][0-9]{0,4}$ && "$expires" =~ ^[1-9][0-9]{0,10}$ ]] || return 1
	((port <= 65535)) || return 1
	[[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	IFS=. read -r -a octets <<<"$address"
	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((octet <= 255)) || return 1
	done
	if [[ -n "${WG_TUNNEL_ADDRESS:-}" && "$address" != "${WG_TUNNEL_ADDRESS%%/*}" ]]; then return 1; fi
	generation="$(cat "${file%/*}/tunnel-generation" 2>/dev/null)" || return 1
	current_boot="$(cat /proc/sys/kernel/random/boot_id)" || return 1
	now="$(date +%s)" || return 1
	[[ -n "$generation" && "$lease_generation" == "$generation" && "$boot" == "$current_boot" ]] || return 1
	((expires > now)) || return 1
	export PROTON_LEASE_EXPIRES_AT="$expires"
	printf '%s\n' "$port"
}

proton_with_firewall_lock() (
	local lock_file="${KILLSWITCH_LOCK_FILE:-/run/proton/killswitch.lock}"
	local wait_seconds="${PROTON_FIREWALL_LOCK_WAIT_SECONDS:-30}"
	[[ "$wait_seconds" =~ ^[0-9]+$ ]] || return 1
	mkdir -p "$(dirname "$lock_file")" || return 1
	exec 9>"$lock_file" || return 1
	flock -w "$wait_seconds" 9 || return 1
	"$@"
)

proton_iptables_rule_locked() {
	local action="$1" table="$2" chain="$3" error status attempt
	shift 3
	for ((attempt = 0; attempt < 64; attempt++)); do
		if error="$(LC_ALL=C timeout --kill-after=2s 10s iptables --wait 5 -t "$table" -C "$chain" "$@" 2>&1)"; then
			timeout --kill-after=2s 10s iptables --wait 5 -t "$table" -D "$chain" "$@" || return 1
		else
			status=$?
			if [[ "$status" != 1 || "$error" != *'Bad rule (does a matching rule exist in that chain?).'* ]]; then
				printf 'ERROR: Firewall rule inspection failed: %s\n' "$error" >&2
				return 1
			fi
			if [[ "$action" == ensure ]]; then
				timeout --kill-after=2s 10s iptables --wait 5 -t "$table" -I "$chain" 1 "$@" || return 1
			fi
			return 0
		fi
	done
	return 1
}

proton_iptables_rule() {
	[[ "$1" == ensure || "$1" == remove ]] || return 1
	proton_with_firewall_lock proton_iptables_rule_locked "$@"
}

proton_nft_chain_snapshot() {
	local family="$1" table="$2" chain="$3" tables table_rules
	export PROTON_NFT_TABLE_EXISTS=0
	export PROTON_NFT_CHAIN_EXISTS=0
	export PROTON_NFT_RULES=""
	tables="$(nft list tables)" || return 1
	if ! grep -Fxq "table $family $table" <<<"$tables"; then return 0; fi
	PROTON_NFT_TABLE_EXISTS=1
	table_rules="$(nft list table "$family" "$table")" || return 1
	if ! awk -v chain="$chain" '$1 == "chain" && $2 == chain && $3 == "{" {found=1} END {exit !found}' <<<"$table_rules"; then return 0; fi
	PROTON_NFT_CHAIN_EXISTS=1
	PROTON_NFT_RULES="$(nft -a list chain "$family" "$table" "$chain")" || return 1
}

proton_nft_delete_comment_rules() {
	local family="$1" table="$2" chain="$3" comment="$4" rules="$5"
	awk -v family="$family" -v table="$table" -v chain="$chain" -v comment="$comment" '
        index($0, "comment \"" comment "\"") {
            for (field=1; field<=NF; field++) {
                if ($field == "handle" && $(field+1) ~ /^[0-9]+$/)
                    printf "delete rule %s %s %s handle %s\n", family, table, chain, $(field+1)
            }
        }
    ' <<<"$rules"
}

proton_allowed_instances() {
	printf '%s\n' lidarr radarr sonarr whisparr prowlarr
}

proton_allowed_instances_csv() {
	printf '%s\n' "lidarr,radarr,sonarr,whisparr,prowlarr"
}

proton_instance_error() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# Policy rules at priorities 108/109 are shared by every Proton instance.
# WireGuard starts, stops, and Docker-event reconciliation must never perform
# their delete/add sequences concurrently or one instance can fail with
# RTNETLINK/EEXIST and leave a partially configured routing table.
proton_route_lock_acquire() {
	local lock_dir=""
	local wait_seconds="${PROTON_ROUTE_LOCK_WAIT_SECONDS:-60}"

	PROTON_ROUTE_LOCK_FILE="${PROTON_ROUTE_LOCK_FILE:-/run/proton/policy-routing.lock}"

	if [[ -n "${PROTON_ROUTE_LOCK_FD:-}" ]]; then
		printf 'ERROR: Proton policy-route lock is already held by this process.\n' >&2
		return 1
	fi
	if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]]; then
		printf 'ERROR: Invalid PROTON_ROUTE_LOCK_WAIT_SECONDS value: %s\n' "$wait_seconds" >&2
		return 1
	fi
	if ! command -v flock >/dev/null 2>&1; then
		printf 'ERROR: Required command '\''flock'\'' is not installed.\n' >&2
		return 1
	fi

	lock_dir="${PROTON_ROUTE_LOCK_FILE%/*}"
	if [[ "$lock_dir" == "$PROTON_ROUTE_LOCK_FILE" ]]; then
		lock_dir="."
	fi
	mkdir -p "$lock_dir" || return 1
	exec {PROTON_ROUTE_LOCK_FD}>"$PROTON_ROUTE_LOCK_FILE" || return 1
	if ! flock -w "$wait_seconds" "$PROTON_ROUTE_LOCK_FD"; then
		printf 'ERROR: Timed out after %s seconds waiting for Proton policy-route lock %s.\n' \
			"$wait_seconds" "$PROTON_ROUTE_LOCK_FILE" >&2
		exec {PROTON_ROUTE_LOCK_FD}>&-
		unset PROTON_ROUTE_LOCK_FD
		return 1
	fi
}

proton_route_lock_release() {
	if [[ -z "${PROTON_ROUTE_LOCK_FD:-}" ]]; then
		return 0
	fi

	flock -u "$PROTON_ROUTE_LOCK_FD" 2>/dev/null || true
	exec {PROTON_ROUTE_LOCK_FD}>&-
	unset PROTON_ROUTE_LOCK_FD
}

# Remove every exact copy of one policy rule. A prior interrupted lifecycle or
# older add-without-delete implementation may have left duplicates behind. The
# caller must hold the host-global policy-route lock while using this helper.
proton_delete_ip_rule_all() {
	local family="${1:-}"
	local attempt=0
	local deletion_error
	local -a ip_command=(ip)
	shift || true

	case "$family" in
	4) ;;
	6) ip_command+=(-6) ;;
	*)
		printf 'ERROR: Invalid IP family for policy rule deletion: %s\n' "$family" >&2
		return 1
		;;
	esac
	if (($# == 0)); then
		printf 'ERROR: Missing policy rule selector for deletion.\n' >&2
		return 1
	fi

	for ((attempt = 0; attempt < 64; attempt++)); do
		if ! deletion_error="$(LC_ALL=C "${ip_command[@]}" rule del "$@" 2>&1)"; then
			if [[ "$deletion_error" == "RTNETLINK answers: No such file or directory" ]]; then return 0; fi
			printf 'ERROR: Policy-rule deletion failed: %s\n' "$deletion_error" >&2
			return 1
		fi
	done

	printf 'ERROR: Refusing to delete more than 64 copies of one policy rule: %s\n' "$*" >&2
	return 1
}

# Canonicalize an exact rule to one copy. The final add is intentionally not
# suppressed: EEXIST or another kernel error must fail the lifecycle operation
# instead of leaving partially reconciled routing state.
proton_replace_ip_rule() {
	local family="${1:-}"
	local -a ip_command=(ip)
	shift || true

	case "$family" in
	4) ;;
	6) ip_command+=(-6) ;;
	*)
		printf 'ERROR: Invalid IP family for policy rule replacement: %s\n' "$family" >&2
		return 1
		;;
	esac

	proton_delete_ip_rule_all "$family" "$@" || return 1
	"${ip_command[@]}" rule add "$@"
}

proton_persist_route_state() (
	local file="$1" value="$2" temporary
	if [[ -z "$value" ]]; then rm -f "$file"; return; fi
	umask 077
	temporary="$(mktemp "${file}.XXXXXX")" || return 1
	trap 'rm -f "$temporary"' EXIT
	printf '%s' "$value" >"$temporary" || return 1
	mv -f "$temporary" "$file"
)

proton_flush_route_table() {
	local family="$1" table="$2" failure
	local -a ip_command=(ip)
	case "$family" in
	4) ;;
	6) ip_command+=(-6) ;;
	*) return 1 ;;
	esac
	if failure="$(LC_ALL=C "${ip_command[@]}" route flush table "$table" 2>&1)"; then return 0; fi
	case "$failure" in
	"Error: ipv${family}: FIB table does not exist." | "Error: ipv${family}: FIB table does not exist."$'\nFlush terminated') return 0 ;;
	esac
	printf 'ERROR: Route-table flush failed: %s\n' "$failure" >&2
	return 1
}

proton_validate_instance_name() {
	local instance="${1:-}"

	if [[ -z "$instance" ]]; then
		proton_instance_error "Instance name is required. Allowed instances: $(proton_allowed_instances_csv)"
	fi

	if [[ ! "$instance" =~ ^[a-z][a-z0-9_-]*$ ]]; then
		proton_instance_error "Unsafe instance name '$instance'."
	fi

	case "$instance" in
	lidarr | radarr | sonarr | whisparr | prowlarr)
		return 0
		;;
	*)
		proton_instance_error "Unsupported instance '$instance'. Allowed instances: $(proton_allowed_instances_csv)"
		;;
	esac
}

proton_source_env_if_present() {
	local env_file="$1"

	if [[ -f "$env_file" ]]; then
		# shellcheck disable=SC1090
		source "$env_file"
	fi
}

proton_require_env_file() {
	local env_file="$1"
	local label="$2"

	if [[ ! -f "$env_file" ]]; then
		proton_instance_error "${label} not found: ${env_file}"
	fi
}

proton_require_secure_real_env_file() {
	local env_file="$1"
	local mode owner

	case "$env_file" in
	/etc/proton/*) ;;
	*)
		return 0
		;;
	esac

	if ! command -v stat >/dev/null 2>&1; then
		proton_instance_error "Required command 'stat' is not installed."
	fi

	mode="$(stat -c '%a' "$env_file")"
	owner="$(stat -c '%u' "$env_file")"

	if [[ "$mode" != "600" ]]; then
		proton_instance_error "$env_file must have mode 600."
	fi

	if [[ "$owner" != "0" ]]; then
		proton_instance_error "$env_file must be owned by root."
	fi
}

proton_rebase_legacy_runtime_paths() {
	local default_state_dir="/run/proton/${INSTANCE}"
	local inferred_state_dir=""

	if [[ -z "${STATE_DIR:-}" || "${STATE_DIR}" == "/run/proton" ]]; then
		if [[ -n "${STATE_FILE:-}" && "${STATE_FILE}" != "/run/proton/proton-port.state" && "$STATE_FILE" == */* ]]; then
			inferred_state_dir="${STATE_FILE%/*}"
		elif [[ -n "${CACHE_FILE:-}" && "${CACHE_FILE}" != "/run/proton/qbt-port.cache" && "$CACHE_FILE" == */* ]]; then
			inferred_state_dir="${CACHE_FILE%/*}"
		fi
	fi

	if [[ -n "$inferred_state_dir" ]]; then
		STATE_DIR="$inferred_state_dir"
	elif [[ -z "${STATE_DIR:-}" || "${STATE_DIR}" == "/run/proton" ]]; then
		STATE_DIR="$default_state_dir"
	fi

	if [[ -z "${QBITTORRENT_ENV_FILE:-}" || "${QBITTORRENT_ENV_FILE}" == "/etc/proton/qbittorrent.env" ]]; then
		QBITTORRENT_ENV_FILE="${INSTANCE_DIR}/qbittorrent.env"
	fi

	if [[ -z "${STATE_FILE:-}" || "${STATE_FILE}" == "/run/proton/proton-port.state" ]]; then
		STATE_FILE="${STATE_DIR}/proton-port.state"
	fi

	if [[ -z "${CACHE_FILE:-}" || "${CACHE_FILE}" == "/run/proton/qbt-port.cache" ]]; then
		CACHE_FILE="${STATE_DIR}/qbt-port.cache"
	fi

	if [[ -z "${RECOVERY_LOCK_FILE:-}" || "${RECOVERY_LOCK_FILE}" == "/run/proton/recovery.lock" ]]; then
		RECOVERY_LOCK_FILE="${STATE_DIR}/recovery.lock"
	fi

	if [[ -z "${SERVER_SELECTION_FILE:-}" || "${SERVER_SELECTION_FILE}" == "/run/proton/current-server.env" ]]; then
		SERVER_SELECTION_FILE="${STATE_DIR}/current-server.env"
	fi

	if [[ -z "${SERVER_RESELECT_FILE:-}" || "${SERVER_RESELECT_FILE}" == "/run/proton/reselect-server.flag" ]]; then
		SERVER_RESELECT_FILE="${STATE_DIR}/reselect-server.flag"
	fi

	if [[ -z "${DOCKER_NETWORK_CIDR_STATE_FILE:-}" || "${DOCKER_NETWORK_CIDR_STATE_FILE}" == "/run/proton/docker-network-cidr" ]]; then
		DOCKER_NETWORK_CIDR_STATE_FILE="${STATE_DIR}/docker-network-cidr"
	fi

	if [[ -z "${DOCKER_CONFIG_DIR:-}" || "${DOCKER_CONFIG_DIR}" == "/run/proton/docker-config" ]]; then
		DOCKER_CONFIG_DIR="${STATE_DIR}/docker-config"
	fi

	if [[ -z "${LAST_FILE:-}" || "${LAST_FILE}" == "/run/proton/docker-network-watcher.last" ]]; then
		LAST_FILE="${STATE_DIR}/docker-network-watcher.last"
	fi

	if [[ -z "${QBT_SYNC_LOCK_FILE:-}" || "${QBT_SYNC_LOCK_FILE}" == "/run/proton/qbt-sync.lock" ]]; then
		QBT_SYNC_LOCK_FILE="${STATE_DIR}/qbt-sync.lock"
	fi

	export STATE_DIR QBITTORRENT_ENV_FILE STATE_FILE CACHE_FILE RECOVERY_LOCK_FILE
	export SERVER_SELECTION_FILE SERVER_RESELECT_FILE DOCKER_NETWORK_CIDR_STATE_FILE
	export DOCKER_CONFIG_DIR LAST_FILE QBT_SYNC_LOCK_FILE
}

# Derive per-instance WireGuard tunnel addressing and the NAT-PMP gateway from
# WG_ADDRESS_SUBNET. Proton supports multiple simultaneous tunnels on one
# account by giving each tunnel a distinct client address subnet
# (10.2.0.2, 10.3.0.2, ...), each with its own gateway/DNS (10.2.0.1, 10.3.0.1,
# ...). Each distinct address receives an independent NAT-PMP forwarded port,
# so concurrent instances no longer collide on a single shared port.
proton_apply_tunnel_subnet() {
	[[ -n "${WG_ADDRESS_SUBNET:-}" ]] || return 0

	if [[ ! "$WG_ADDRESS_SUBNET" =~ ^[0-9]+$ ]] || ((WG_ADDRESS_SUBNET < 1 || WG_ADDRESS_SUBNET > 254)); then
		proton_instance_error "Invalid WG_ADDRESS_SUBNET '$WG_ADDRESS_SUBNET' (expected an integer 1-254)."
	fi

	local subnet_number
	subnet_number=$((10#$WG_ADDRESS_SUBNET))

	# WG_ADDRESS_SUBNET is the single source of truth. Derive everything from it
	# so the tunnel address, DNS, and NAT-PMP gateway can never drift apart.
	WG_TUNNEL_ADDRESS="10.${WG_ADDRESS_SUBNET}.0.2/32"
	WG_TUNNEL_DNS="10.${WG_ADDRESS_SUBNET}.0.1"
	NATPMP_GATEWAY="10.${WG_ADDRESS_SUBNET}.0.1"

	# The shared common env keeps the legacy singleton table at 51820. Instance
	# services need a distinct table per tunnel so qBittorrent replies leave via
	# the same WireGuard interface that owns the forwarded port.
	if [[ -z "${VPN_TABLE:-}" || "$VPN_TABLE" == "51820" ]]; then
		VPN_TABLE="$((51800 + subnet_number))"
	fi

	if [[ -z "${QBT_VPN_RULE_PRIORITY:-}" ]]; then
		QBT_VPN_RULE_PRIORITY="$((110 + subnet_number))"
	fi

	export WG_ADDRESS_SUBNET WG_TUNNEL_ADDRESS WG_TUNNEL_DNS NATPMP_GATEWAY
	export VPN_TABLE QBT_VPN_RULE_PRIORITY
}

proton_instance_init() {
	local instance_arg="${1:-}"
	local role_env="${2:-}"

	proton_validate_instance_name "$instance_arg"

	INSTANCE="$instance_arg"
	PROTON_COMMON_ENV="${PROTON_COMMON_ENV:-/etc/proton/proton-common.env}"
	PROTON_INSTANCE_ROOT="${PROTON_INSTANCE_ROOT:-/etc/proton/instances}"
	INSTANCE_DIR="${PROTON_INSTANCE_ROOT}/${INSTANCE}"
	INSTANCE_PROTON_ENV="${INSTANCE_PROTON_ENV:-${INSTANCE_DIR}/proton.env}"

	export INSTANCE PROTON_INSTANCE_ROOT INSTANCE_DIR INSTANCE_PROTON_ENV

	proton_source_env_if_present "$PROTON_COMMON_ENV"
	if [[ -n "$role_env" ]]; then
		proton_source_env_if_present "$role_env"
	fi

	proton_rebase_legacy_runtime_paths

	proton_require_env_file "$INSTANCE_PROTON_ENV" "Instance Proton env"
	# shellcheck disable=SC1090
	source "$INSTANCE_PROTON_ENV"

	proton_rebase_legacy_runtime_paths
	proton_require_env_file "$QBITTORRENT_ENV_FILE" "Instance qBittorrent env"
	proton_require_secure_real_env_file "$QBITTORRENT_ENV_FILE"
	# shellcheck disable=SC1090
	source "$QBITTORRENT_ENV_FILE"

	proton_rebase_legacy_runtime_paths
	proton_apply_tunnel_subnet
}
