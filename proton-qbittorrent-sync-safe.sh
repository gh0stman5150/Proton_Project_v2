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
REQUESTED_FORCE_RECREATE="${QBT_FORCE_RECREATE:-}"
proton_instance_init "${1:-}"

QBT_COMMON_SCRIPT="${QBT_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-qbittorrent-common.sh}"
LOG_TAG="${LOG_TAG:-proton-qbt}"
CACHE_DIR="${CACHE_FILE%/*}"

if [[ "$CACHE_DIR" == "$CACHE_FILE" ]]; then
	CACHE_DIR="."
fi

log() {
	echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOG_TAG"
}

require_command() {
	local cmd="$1"

	if ! type -P "$cmd" >/dev/null 2>&1; then
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

for cmd in awk chmod curl flock grep mkdir mktemp mv readlink rm sleep stat systemd-cat tr; do
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

if [[ ! -f "$QBT_COMMON_SCRIPT" ]]; then
	log "ERROR: qBittorrent helper script not found: $QBT_COMMON_SCRIPT"
	exit 1
fi

# shellcheck disable=SC1090
source "$QBT_COMMON_SCRIPT"
# proton_instance_init already checked and sourced the qBittorrent env file.
QBITTORRENT_URL="${QBITTORRENT_URL:+${QBITTORRENT_URL%/}}"
if [[ -n "$REQUESTED_FORCE_RECREATE" ]]; then QBT_FORCE_RECREATE="$REQUESTED_FORCE_RECREATE"; fi

QBT_PORT_APPLY_MODE="${QBT_PORT_APPLY_MODE:-compose-recreate}"
QBT_PORT_ENV_FILE="${QBT_PORT_ENV_FILE:-/etc/proton/qbittorrent-port.env}"
QBT_COMPOSE_PROJECT_DIR="${QBT_COMPOSE_PROJECT_DIR:-}"
QBT_COMPOSE_SERVICE="${QBT_COMPOSE_SERVICE:-qbittorrent}"
QBT_CONFIG_DIR="${QBT_CONFIG_DIR:-${QBT_COMPOSE_PROJECT_DIR:+${QBT_COMPOSE_PROJECT_DIR%/}/config}}"
QBT_RECREATE_PENDING_FILE="${CACHE_DIR}/qbt-recreate.pending"
QBT_COMPOSE_RECREATE_RETRIES="${QBT_COMPOSE_RECREATE_RETRIES:-3}"
QBT_COMPOSE_RECREATE_RETRY_DELAY="${QBT_COMPOSE_RECREATE_RETRY_DELAY:-5}"
QBT_RESPECT_MANUAL_STOP="${QBT_RESPECT_MANUAL_STOP:-1}"
QBT_MANUAL_STOP_EVENT_GRACE_SECONDS="${QBT_MANUAL_STOP_EVENT_GRACE_SECONDS:-180}"
QBT_FORCE_RECREATE="${QBT_FORCE_RECREATE:-0}"
QBT_SYNC_LOCK_WAIT_SECONDS="${QBT_SYNC_LOCK_WAIT_SECONDS:-30}"
QBT_DSTATE_SAMPLES="${QBT_DSTATE_SAMPLES:-3}"
QBT_DSTATE_DELAY="${QBT_DSTATE_DELAY:-1}"
QBT_ROUTE_RECONCILE_SCRIPT="${QBT_ROUTE_RECONCILE_SCRIPT:-${SCRIPT_DIR}/proton-docker-network-watcher.sh}"

reconcile_container_routes() {
	timeout --foreground --kill-after=5s 60s bash "$QBT_ROUTE_RECONCILE_SCRIPT" "$INSTANCE" --once
}

case "$QBT_PORT_APPLY_MODE" in
compose-recreate) ;;
legacy-dnat)
	log "ERROR: QBT_PORT_APPLY_MODE=legacy-dnat was removed; set QBT_PORT_APPLY_MODE=compose-recreate"
	exit 1
	;;
*)
	log "ERROR: Unsupported QBT_PORT_APPLY_MODE '$QBT_PORT_APPLY_MODE'"
	exit 1
	;;
esac

if [[ -n "$QBT_COMPOSE_PROJECT_DIR" &&
	"$(readlink -m "$QBT_PORT_ENV_FILE")" == "$(readlink -m "${QBT_COMPOSE_PROJECT_DIR%/}/.env")" ]]; then
	log "ERROR: QBT_PORT_ENV_FILE must not be the Compose project's static .env file"
	exit 1
fi

case "${QBT_FORCE_RECREATE,,}" in
0 | false | no | off | 1 | true | yes | on) ;;
*)
	log "ERROR: Invalid QBT_FORCE_RECREATE value: $QBT_FORCE_RECREATE"
	exit 1
	;;
esac

force_recreate_enabled() {
	case "${QBT_FORCE_RECREATE,,}" in
	1 | true | yes | on)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

if [[ ! "$QBT_SYNC_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
	log "ERROR: Invalid QBT_SYNC_LOCK_WAIT_SECONDS value: $QBT_SYNC_LOCK_WAIT_SECONDS"
	exit 1
fi
if [[ ! "$QBT_DSTATE_SAMPLES" =~ ^[0-9]+$ ]] || ((QBT_DSTATE_SAMPLES < 2)); then
	log "ERROR: QBT_DSTATE_SAMPLES must be at least 2"
	exit 1
fi
if [[ ! "$QBT_DSTATE_DELAY" =~ ^[0-9]+$ ]]; then
	log "ERROR: Invalid QBT_DSTATE_DELAY value: $QBT_DSTATE_DELAY"
	exit 1
fi

ensure_directory "$CACHE_DIR" 700

acquire_sync_lock() {
	exec 200>"$QBT_SYNC_LOCK_FILE"
	if force_recreate_enabled; then
		if ! flock -w "$QBT_SYNC_LOCK_WAIT_SECONDS" 200; then
			log "ERROR: Timed out waiting for the qBittorrent sync lock during forced recreation"
			exit 1
		fi
	elif ! flock -n 200; then
		log "Another qBittorrent sync is already running; skipping"
		exit 0
	fi
}

acquire_sync_lock

PORT="$(proton_lease_read)" || {
	log "ERROR: Missing, stale, or invalid Proton lease"
	exit 1
}

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
	log "ERROR: Invalid port value: $PORT"
	exit 1
fi

if [[ ! "$QBT_COMPOSE_RECREATE_RETRIES" =~ ^[0-9]+$ ]] || ((QBT_COMPOSE_RECREATE_RETRIES < 1)); then
	log "ERROR: Invalid QBT_COMPOSE_RECREATE_RETRIES value: $QBT_COMPOSE_RECREATE_RETRIES"
	exit 1
fi

if [[ ! "$QBT_COMPOSE_RECREATE_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
	log "ERROR: Invalid QBT_COMPOSE_RECREATE_RETRY_DELAY value: $QBT_COMPOSE_RECREATE_RETRY_DELAY"
	exit 1
fi

COOKIE_JAR="$(mktemp)"
cleanup() {
	rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

write_cache() {
	umask 077
	echo "$PORT" >"$CACHE_FILE"
}

write_cache_value() {
	local value="$1"

	umask 077
	echo "$value" >"$CACHE_FILE"
}

read_published_port() {
	awk -F= '/^QBT_PUBLISHED_PORT=/ {print $2; exit}' "$QBT_PORT_ENV_FILE" 2>/dev/null || true
}

published_port_artifact_is_canonical() {
	[[ -f "$QBT_PORT_ENV_FILE" ]] || return 1
	[[ "$(awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { count++ } END { print count + 0 }' "$QBT_PORT_ENV_FILE")" -eq 1 ]] || return 1
	grep -Eq "^QBT_PUBLISHED_PORT=${PORT}$" "$QBT_PORT_ENV_FILE"
}

write_published_port_value() {
	local value="$1"
	local port_dir="${QBT_PORT_ENV_FILE%/*}"
	local tmp_file=""

	if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < 1 || value > 65535)); then
		log "ERROR: Refusing to write invalid QBT_PUBLISHED_PORT value: $value"
		return 1
	fi

	if [[ "$port_dir" == "$QBT_PORT_ENV_FILE" ]]; then
		port_dir="."
	fi

	ensure_directory "$port_dir" 700
	umask 077
	tmp_file="$(mktemp "${port_dir%/}/.qbittorrent-port.env.XXXXXX")"
	{
		echo "# Managed by proton-qbittorrent-sync-safe.sh"
		echo "QBT_PUBLISHED_PORT=$value"
	} >"$tmp_file"
	chmod 600 "$tmp_file"
	if ! mv -f "$tmp_file" "$QBT_PORT_ENV_FILE"; then
		rm -f "$tmp_file"
		return 1
	fi
}

write_published_port() {
	write_published_port_value "$PORT"
}

disable_random_port() {
	curl -fsS -b "$COOKIE_JAR" -X POST \
		--data 'json={"random_port":false}' \
		"$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null
}

set_qbt_listen_port_value() {
	local target_port="$1"

	curl -fsS -b "$COOKIE_JAR" -X POST \
		--data "json={\"listen_port\":$target_port}" \
		"$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null
}

ensure_qbt_listen_port_value() {
	local target_port="$1"
	local applied_port

	applied_port="$(qbt_get_listen_port "$COOKIE_JAR" || true)"
	if [[ "$applied_port" == "$target_port" ]]; then
		return 0
	fi

	log "Updating qBittorrent listen port -> $target_port"
	disable_random_port
	set_qbt_listen_port_value "$target_port"

	applied_port="$(qbt_get_listen_port "$COOKIE_JAR" || true)"
	if [[ "$applied_port" != "$target_port" ]]; then
		log "ERROR: qBittorrent did not apply port $target_port (reported: ${applied_port:-unknown})"
		exit 1
	fi
}

apply_qbt_listen_port() {
	if [[ "$CURRENT_QBT_PORT" == "$PORT" ]]; then
		return 0
	fi

	ensure_qbt_listen_port_value "$PORT"
	LISTEN_PORT_CHANGED=1
}

require_compose_mode_ready() {
	require_command docker

	if [[ -z "$QBT_COMPOSE_PROJECT_DIR" ]]; then
		log "ERROR: QBT_COMPOSE_PROJECT_DIR is required in compose-recreate mode"
		return 1
	fi

	if [[ ! -d "$QBT_COMPOSE_PROJECT_DIR" ]]; then
		log "ERROR: Compose project directory not found: $QBT_COMPOSE_PROJECT_DIR"
		return 1
	fi

	if [[ -z "$QBT_COMPOSE_SERVICE" ]]; then
		log "ERROR: QBT_COMPOSE_SERVICE is required in compose-recreate mode"
		return 1
	fi
}

respect_manual_stop_enabled() {
	case "${QBT_RESPECT_MANUAL_STOP,,}" in
	1 | true | yes | on)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Prints the newest Compose container ID for the service; pass --all to
# include stopped containers.
compose_service_container_id() {
	(
		cd "$QBT_COMPOSE_PROJECT_DIR"
		QBT_PUBLISHED_PORT="$PORT" DOCKER_CONFIG="$DOCKER_CONFIG_DIR" docker compose ps "$@" -q "$QBT_COMPOSE_SERVICE" 2>/dev/null |
			awk 'NF { last = $0 } END { print last }'
	)
}

compose_container_ref_all() {
	local container_id

	if [[ -n "${QBT_CONTAINER_NAME:-}" ]] && docker inspect "$QBT_CONTAINER_NAME" >/dev/null 2>&1; then
		printf '%s\n' "$QBT_CONTAINER_NAME"
		return 0
	fi

	container_id="$(compose_service_container_id --all)"
	[[ -n "$container_id" ]] || return 1
	printf '%s\n' "$container_id"
}

# Renders TEMPLATE for the service container in one inspect when
# QBT_CONTAINER_NAME resolves, falling back to a Compose lookup (extra
# arguments go to compose_service_container_id).
compose_container_inspect() {
	local template="$1" container_id
	shift

	if [[ -n "${QBT_CONTAINER_NAME:-}" ]] && docker inspect -f "$template" "$QBT_CONTAINER_NAME" 2>/dev/null; then
		return 0
	fi

	container_id="$(compose_service_container_id "$@")"
	[[ -n "$container_id" ]] || return 1
	docker inspect -f "$template" "$container_id" 2>/dev/null || true
}

compose_container_status() {
	compose_container_inspect '{{.State.Status}}' --all
}

recent_manual_stop_event() {
	local container_ref
	local container_id
	local container_id_short
	local since
	local until

	[[ "$QBT_MANUAL_STOP_EVENT_GRACE_SECONDS" =~ ^[0-9]+$ ]] || return 1
	((QBT_MANUAL_STOP_EVENT_GRACE_SECONDS > 0)) || return 1

	container_ref="$(compose_container_ref_all)" || return 1
	container_id="$(docker inspect -f '{{.Id}}' "$container_ref" 2>/dev/null || true)"
	[[ -n "$container_id" ]] || return 1
	container_id_short="${container_id:0:12}"
	until="$(date +%s)"
	since=$((until - QBT_MANUAL_STOP_EVENT_GRACE_SECONDS))

	if docker events \
		--since "$since" \
		--until "$until" \
		--filter container="$container_ref" \
		--format '{{.Action}}' 2>/dev/null |
		awk '$1 == "stop" || $1 == "die" || $1 == "destroy" || $1 == "kill" { found = 1 } END { exit found ? 0 : 1 }'; then
		return 0
	fi

	docker events \
		--since "$since" \
		--until "$until" \
		--filter type=network \
		--filter event=disconnect \
		--format '{{.Actor.Attributes.container}}' 2>/dev/null |
		awk -v id="$container_id" -v short_id="$container_id_short" '
            $1 == id || $1 == short_id { found = 1 }
            END { exit found ? 0 : 1 }
        '
}

pending_recreate_identity() {
	local container_id finished_at
	container_id="$(docker inspect -f '{{.Id}}' "${QBT_CONTAINER_NAME:-$QBT_COMPOSE_SERVICE}")" || return 1
	finished_at="$(docker inspect -f '{{.State.FinishedAt}}' "${QBT_CONTAINER_NAME:-$QBT_COMPOSE_SERVICE}")" || return 1
	[[ "$container_id" =~ ^[a-f0-9]{64}$ && -n "$finished_at" && "$finished_at" != 0001-* ]] || return 1
	printf '%s|%s\n' "$container_id" "$finished_at"
}

record_pending_recreate() {
	local identity temporary
	identity="$(pending_recreate_identity)" || return 1
	temporary="$(mktemp "${QBT_RECREATE_PENDING_FILE}.XXXXXX")" || return 1
	if ! { printf '%s\n' "$identity" >"$temporary" && mv -f "$temporary" "$QBT_RECREATE_PENDING_FILE"; }; then
		rm -f "$temporary"
		return 1
	fi
}

skip_sync_for_manual_stop() {
	local status identity recorded_identity
	local container_label="${QBT_CONTAINER_NAME:-$QBT_COMPOSE_SERVICE}"

	respect_manual_stop_enabled || return 1
	require_compose_mode_ready || return 1

	status="$(compose_container_status || true)"
	if [[ -f "$QBT_RECREATE_PENDING_FILE" ]]; then
		if [[ "$status" == exited || "$status" == created ]] &&
			identity="$(pending_recreate_identity)" &&
			recorded_identity="$(cat "$QBT_RECREATE_PENDING_FILE")" &&
			[[ -n "$identity" && "$identity" == "$recorded_identity" ]]; then
			log "Retrying the stopped container from an unfinished automated recreation"
			return 1
		fi
		rm -f "$QBT_RECREATE_PENDING_FILE"
	fi
	case "$status" in
	created | exited | dead | removing)
		log "qBittorrent container $container_label is $status; skipping sync because QBT_RESPECT_MANUAL_STOP=$QBT_RESPECT_MANUAL_STOP"
		return 0
		;;
	"")
		log "qBittorrent container $container_label is absent; skipping sync because QBT_RESPECT_MANUAL_STOP=$QBT_RESPECT_MANUAL_STOP"
		return 0
		;;
	*)
		if recent_manual_stop_event; then
			log "qBittorrent container $container_label has a recent stop/disconnect event; skipping sync because QBT_RESPECT_MANUAL_STOP=$QBT_RESPECT_MANUAL_STOP"
			return 0
		fi
		return 1
		;;
	esac
}

# Prints "<containerPort>/<proto> <hostPort>" lines. Callers read this once
# per phase and pass it to the helpers below; re-read after a recreate.
compose_published_ports() {
	# shellcheck disable=SC2016
	compose_container_inspect '{{range $containerPort, $bindings := .NetworkSettings.Ports}}{{if $bindings}}{{range $bindings}}{{printf "%s %s\n" $containerPort .HostPort}}{{end}}{{end}}{{end}}'
}

compose_published_ports_summary() {
	local ports="$1"

	if [[ -z "$ports" ]]; then
		printf 'none'
		return 0
	fi

	awk '
        {
            printf "%s%s->%s", sep, $1, $2
            sep = ", "
        }
        END {
            print ""
        }
    ' <<<"$ports"
}

compose_container_has_zombie_process() {
	local container_ref="$1"

	docker top "$container_ref" -eo pid,stat,cmd 2>/dev/null |
		awk 'NR > 1 && $2 ~ /^Z/ { found = 1 } END { exit found ? 0 : 1 }'
}

compose_container_dstate_lwps() {
	local container_ref="$1"

	docker top "$container_ref" -eLo pid,lwp,stat 2>/dev/null |
		awk 'NR > 1 && $3 ~ /^D/ { print $2 }' |
		sort -u
}

compose_container_has_uninterruptible_task() {
	local container_ref="$1"
	local persistent_lwps=""
	local current_lwps=""
	local retained_lwps=""
	local lwp=""
	local sample=0

	persistent_lwps="$(compose_container_dstate_lwps "$container_ref")"
	[[ -n "$persistent_lwps" ]] || return 1

	for ((sample = 2; sample <= QBT_DSTATE_SAMPLES; sample++)); do
		sleep "$QBT_DSTATE_DELAY"
		current_lwps="$(compose_container_dstate_lwps "$container_ref")"
		retained_lwps=""
		while IFS= read -r lwp; do
			if grep -Fxq "$lwp" <<<"$current_lwps"; then
				retained_lwps+="${lwp}"$'\n'
			fi
		done <<<"$persistent_lwps"
		persistent_lwps="${retained_lwps%$'\n'}"
		[[ -n "$persistent_lwps" ]] || return 1
	done

	return 0
}

compose_container_is_wedged_for_recreate() {
	local container_ref
	local status
	local ports

	if ! qbt_container_safe_for_recreate "${QBT_CONTAINER_NAME:-$QBT_COMPOSE_SERVICE}" 1; then
		log "ERROR: Unsafe or unknown container task state; refusing recreation. Follow the wedge-recovery runbook."
		return 0
	fi
	container_ref="$(compose_container_ref_all)" || return 1
	status="$(docker inspect -f '{{.State.Status}}' "$container_ref" 2>/dev/null || true)"
	[[ "$status" == "running" ]] || return 1

	if compose_container_has_uninterruptible_task "$container_ref"; then
		log "ERROR: qBittorrent container ${QBT_CONTAINER_NAME:-$container_ref} has an uninterruptible D-state task; refusing Compose recreation. Capture kernel/CIFS evidence and recover the host before retrying; signals and repeated Docker removal cannot release kernel-blocked I/O."
		return 0
	fi

	ports="$(compose_published_ports || true)"
	if compose_container_has_zombie_process "$container_ref"; then
		log "ERROR: qBittorrent container ${QBT_CONTAINER_NAME:-$container_ref} is running with a zombie process (published ports: $(compose_published_ports_summary "$ports")); refusing Compose recreate to avoid hanging on Docker stop. Capture every task state and follow the wedge-recovery runbook; do not force cgroup/shim cleanup if any task is in uninterruptible D state."
		return 0
	fi

	[[ -z "$ports" ]] || return 1
	if force_recreate_enabled; then
		log "Running qBittorrent container has no published ports; explicit forced recreation is authorized after lifecycle safety checks"
		return 1
	fi

	log "ERROR: Running container has no published ports; refusing self-heal. Capture evidence and follow the wedge-recovery runbook."
	return 0
}

compose_current_published_port() {
	local ports="$1"

	[[ -n "$ports" ]] || return 1

	awk '
        $1 ~ /\/tcp$/ && $2 ~ /^[0-9]+$/ { tcp[$2] = 1 }
        $1 ~ /\/udp$/ && $2 ~ /^[0-9]+$/ { udp[$2] = 1 }
        END {
            for (port in tcp) {
                if (udp[port]) {
                    print port
                    exit
                }
            }
            exit 1
        }
    ' <<<"$ports"
}

compose_service_publishes_port() {
	local target_port="$1"
	local ports="$2"

	[[ -n "$ports" ]] || return 1

	awk -v target_port="$target_port" '
        $1 ~ /\/tcp$/ && $2 == target_port { tcp = 1 }
        $1 ~ /\/udp$/ && $2 == target_port { udp = 1 }
        END { exit (tcp && udp) ? 0 : 1 }
    ' <<<"$ports"
}

clean_stale_qbt_lock() {
	# qBittorrent uses a single-instance lock (lockfile + ipc-socket) under its
	# config dir. When a recreate hits stop_grace_period and Docker SIGKILLs the
	# container, these artifacts are left behind and the next qBittorrent refuses
	# to bind its Web UI, which makes every port sync fail and the container loop
	# unhealthy. Remove them while the service is being recreated (it is stopped
	# at this point) so the fresh container can start cleanly.
	local config_dir="$QBT_CONFIG_DIR"
	local artifact

	[[ -n "$config_dir" ]] || return 0

	for artifact in "${config_dir%/}/qBittorrent/lockfile" "${config_dir%/}/qBittorrent/ipc-socket"; do
		if [[ -e "$artifact" ]]; then
			log "Removing stale qBittorrent artifact before recreate: $artifact"
			rm -f "$artifact"
		fi
	done
}

run_compose_recreate() {
	local target_port="$1"
	local attempt=1
	local exit_code=0
	local output_file

	qbt_storage_ready || {
		log "ERROR: Required writable CIFS leaf is unavailable; refusing recreation"
		return 1
	}
	output_file="$(mktemp)"
	while ((attempt <= QBT_COMPOSE_RECREATE_RETRIES)); do
		[[ "$(proton_lease_read)" == "$target_port" ]] || {
			rm -f "$output_file"
			return 1
		}
		(
			cd "$QBT_COMPOSE_PROJECT_DIR"
			QBT_PUBLISHED_PORT="$target_port" DOCKER_CONFIG="$DOCKER_CONFIG_DIR" docker compose stop "$QBT_COMPOSE_SERVICE"
		) >/dev/null 2>&1 || {
			rm -f "$output_file"
			return 1
		}
		local stopped_status
		stopped_status="$(docker inspect -f '{{.State.Status}}' "${QBT_CONTAINER_NAME:-$QBT_COMPOSE_SERVICE}" 2>/dev/null)" || {
			qbt_container_safe_for_recreate "${QBT_CONTAINER_NAME:-$QBT_COMPOSE_SERVICE}" 1 || {
				rm -f "$output_file"
				return 1
			}
			stopped_status=absent
		}
		case "$stopped_status" in
		exited | created | absent) ;;
		*)
			rm -f "$output_file"
			return 1
			;;
		esac
		if [[ "$stopped_status" != absent ]]; then
			record_pending_recreate || {
				rm -f "$output_file"
				return 1
			}
		fi
		clean_stale_qbt_lock || {
			rm -f "$output_file"
			return 1
		}
		if (
			cd "$QBT_COMPOSE_PROJECT_DIR"
			[[ "$(proton_lease_read)" == "$target_port" ]] || exit 1
			DOCKER_CONFIG="$DOCKER_CONFIG_DIR" \
				QBT_PUBLISHED_PORT="$target_port" \
				docker compose up -d --force-recreate --no-deps "$QBT_COMPOSE_SERVICE"
		) >"$output_file" 2>&1; then
			rm -f "$QBT_RECREATE_PENDING_FILE"
			if [[ -s "$output_file" ]]; then
				cat "$output_file"
			fi
			rm -f "$output_file"
			return 0
		else
			exit_code=$?
		fi

		if [[ -s "$output_file" ]]; then
			cat "$output_file"
		fi

		if ((attempt < QBT_COMPOSE_RECREATE_RETRIES)) && grep -Eq "address already in use|port is already allocated" "$output_file"; then
			log "Compose recreate hit a busy host port for $target_port (attempt $attempt/$QBT_COMPOSE_RECREATE_RETRIES); retrying in ${QBT_COMPOSE_RECREATE_RETRY_DELAY}s"
			sleep "$QBT_COMPOSE_RECREATE_RETRY_DELAY"
			attempt=$((attempt + 1))
			continue
		fi

		rm -f "$output_file"
		return "$exit_code"
	done

	rm -f "$output_file"
	return "$exit_code"
}

recreate_qbt_service_compose() {
	local target_port="$1"
	local ports

	log "Recreating Compose service $QBT_COMPOSE_SERVICE in $QBT_COMPOSE_PROJECT_DIR for published port $target_port"
	ensure_directory "$DOCKER_CONFIG_DIR" 700
	if compose_container_is_wedged_for_recreate; then
		return 1
	fi

	if ! run_compose_recreate "$target_port"; then
		return 1
	fi
	reconcile_container_routes || return 1

	if ! qbt_wait_for_webui 12 5; then
		log "ERROR: qBittorrent Web UI did not become reachable after recreating $QBT_COMPOSE_SERVICE"
		return 1
	fi

	if ! qbt_login "$COOKIE_JAR"; then
		log "ERROR: ${QBT_LOGIN_ERROR:-qBittorrent login failed after recreating $QBT_COMPOSE_SERVICE}"
		return 1
	fi

	if ! ensure_qbt_listen_port_value "$target_port"; then
		log "ERROR: qBittorrent reported a different port after recreating $QBT_COMPOSE_SERVICE"
		return 1
	fi

	ports="$(compose_published_ports || true)"
	if ! compose_service_publishes_port "$target_port" "$ports"; then
		log "ERROR: Docker did not publish qBittorrent TCP/UDP port $target_port after recreating $QBT_COMPOSE_SERVICE (actual: $(compose_published_ports_summary "$ports"))"
		return 1
	fi
	if [[ "$(proton_lease_read)" != "$target_port" ]]; then
		log "ERROR: Proton lease changed or expired during recreation; synchronization must retry"
		return 1
	fi
}

if [[ "$(compose_container_status || true)" == running ]]; then
	reconcile_container_routes || exit 1
fi

if ! qbt_login "$COOKIE_JAR"; then
	if skip_sync_for_manual_stop; then
		exit 0
	fi

	# A container that is wedged on a stale single-instance lock never binds its
	# Web UI, so the very first login fails and the normal recreate path below is
	# never reached. Attempt one lock-clearing recreate so the loop can
	# self-heal instead of looping on "Web UI unreachable".
	if require_compose_mode_ready; then
		log "qBittorrent Web UI unreachable on startup; attempting self-heal recreate on port $PORT"
		if compose_container_is_wedged_for_recreate; then
			log "ERROR: ${QBT_LOGIN_ERROR:-qBittorrent login failed}"
			exit 1
		fi

		write_published_port
		if recreate_qbt_service_compose "$PORT"; then
			write_cache
			log "qBittorrent recovered via self-heal recreate on port $PORT"
			exit 0
		fi
	fi
	log "ERROR: ${QBT_LOGIN_ERROR:-qBittorrent login failed}"
	exit 1
fi

CURRENT_QBT_PORT="$(qbt_get_listen_port "$COOKIE_JAR" || true)"
CURRENT_PUBLISHED_PORT="$(read_published_port || true)"
LISTEN_PORT_CHANGED=0
COMPOSE_RECREATED=0
PORT_ARTIFACT_NORMALIZED=0

if [[ -n "$CURRENT_PUBLISHED_PORT" ]] &&
	{ [[ ! "$CURRENT_PUBLISHED_PORT" =~ ^[0-9]+$ ]] || ((CURRENT_PUBLISHED_PORT < 1 || CURRENT_PUBLISHED_PORT > 65535)); }; then
	log "ERROR: Invalid QBT_PUBLISHED_PORT value in $QBT_PORT_ENV_FILE: $CURRENT_PUBLISHED_PORT"
	exit 1
fi

apply_qbt_listen_port

require_compose_mode_ready || exit 1
COMPOSE_PORTS="$(compose_published_ports || true)"
CURRENT_DOCKER_PUBLISHED_PORT="$(compose_current_published_port "$COMPOSE_PORTS" || true)"
COMPOSE_PORTS_MATCH=0
if compose_service_publishes_port "$PORT" "$COMPOSE_PORTS"; then
	COMPOSE_PORTS_MATCH=1
fi
if [[ "$CURRENT_PUBLISHED_PORT" == "$PORT" ]] && ! published_port_artifact_is_canonical; then
	log "Normalizing qBittorrent published-port artifact to its one-key schema"
	write_published_port
	PORT_ARTIFACT_NORMALIZED=1
fi

if [[ "$CURRENT_PUBLISHED_PORT" != "$PORT" ]] || ((!COMPOSE_PORTS_MATCH)) || force_recreate_enabled; then
	rollback_port=""

	if [[ "$CURRENT_PUBLISHED_PORT" != "$PORT" ]]; then
		log "Updating qBittorrent published port artifact -> $PORT"
		rollback_port="$CURRENT_PUBLISHED_PORT"
	elif ((!COMPOSE_PORTS_MATCH)); then
		log "Docker published ports are stale for qBittorrent; expected TCP/UDP $PORT, actual: $(compose_published_ports_summary "$COMPOSE_PORTS")"
		rollback_port="$CURRENT_DOCKER_PUBLISHED_PORT"
	else
		log "Forcing qBittorrent Compose recreation for a fleet-controlled configuration rollout"
		rollback_port="$CURRENT_PUBLISHED_PORT"
	fi

	write_published_port
	if ! recreate_qbt_service_compose "$PORT"; then
		if [[ -n "$rollback_port" ]]; then
			log "Restoring qBittorrent published port artifact -> $rollback_port"
			write_published_port_value "$rollback_port"
			log "Previous artifact retained as last-applied metadata only; refusing recreation on a historical lease"
		else
			log "Removing qBittorrent published port artifact after failed recreate for $PORT"
			rm -f "$QBT_PORT_ENV_FILE"
		fi

		if [[ -n "$rollback_port" ]]; then
			write_cache_value "$rollback_port"
		else
			rm -f "$CACHE_FILE"
		fi
		exit 1
	fi
	COMPOSE_RECREATED=1
fi

write_cache

if ((COMPOSE_RECREATED)); then
	log "qBittorrent updated successfully with Compose recreation"
elif ((LISTEN_PORT_CHANGED)); then
	log "qBittorrent updated successfully"
elif ((PORT_ARTIFACT_NORMALIZED)); then
	log "qBittorrent port artifact normalized successfully"
else
	log "qBittorrent already using port $PORT"
fi
