#!/usr/bin/env bash

proton_allowed_instances() {
	printf '%s\n' lidarr radarr sonarr whisparr
}

proton_allowed_instances_csv() {
	printf '%s\n' "lidarr,radarr,sonarr,whisparr"
}

proton_instance_error() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
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
	lidarr | radarr | sonarr | whisparr)
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
	/etc/proton/*)
		;;
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

	if [[ -z "${STATE_DIR:-}" || "${STATE_DIR}" == "/run/proton" ]]; then
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
}
