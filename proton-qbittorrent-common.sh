#!/usr/bin/env bash

docker() {
	command timeout --foreground --kill-after=5s "${QBT_DOCKER_TIMEOUT_SECONDS:-120}s" docker "$@"
}

curl() {
	command curl --connect-timeout 5 --max-time "${QBT_HTTP_TIMEOUT_SECONDS:-15}" "$@"
}

qbt_container_safe_for_recreate() {
	local container="$1" allow_absent="${2:-0}"
	local status listing tasks current persistent="" sample task
	local samples="${QBT_DSTATE_SAMPLES:-3}" delay="${QBT_DSTATE_DELAY:-1}"
	[[ "$samples" =~ ^[0-9]+$ && "$delay" =~ ^[0-9]+$ ]] && ((samples >= 2)) || return 1
	if ! status="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)"; then
		listing="$(docker container ls -a --filter "name=^/${container}$" --format '{{.ID}}')" || return 1
		[[ -z "$listing" && "$allow_absent" == 1 ]]
		return $?
	fi
	case "$status" in
	exited | created) return 0 ;;
	running) ;;
	*) return 1 ;;
	esac
	for ((sample = 1; sample <= samples; sample++)); do
		tasks="$(docker top "$container" -eLo pid,lwp,stat)" || return 1
		awk 'NR > 1 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[SRIDTZtWX]/ { found=1 } END { exit !found }' <<<"$tasks" || return 1
		if awk 'NR > 1 && $3 ~ /^Z/ { found=1 } END { exit !found }' <<<"$tasks"; then
			return 1
		fi
		current="$(awk 'NR > 1 && $3 ~ /^D/ { print $2 }' <<<"$tasks")"
		if ((sample == 1)); then
			persistent="$current"
		else
			listing=""
			while IFS= read -r task; do
				if [[ -n "$task" ]] && grep -Fxq "$task" <<<"$current"; then
					listing+="$task"$'\n'
				fi
			done <<<"$persistent"
			persistent="${listing%$'\n'}"
		fi
		[[ -n "$persistent" ]] || return 0
		((sample == samples)) || sleep "$delay"
	done
	return 1
}

qbt_storage_ready() {
	local mount_info
	mount_info="$(timeout 10s findmnt -rn -M "${QBT_DATA_MOUNT:-/mnt/data}" -o FSTYPE,OPTIONS)" || return 1
	awk '$1 == "cifs" { count=split($2, options, ","); for (option_index=1; option_index<=count; option_index++) { if (options[option_index]=="rw") writable=1; if (options[option_index]=="cache=none") uncached=1 } } END { exit !(writable && uncached) }' <<<"$mount_info"
}

qbt_fleet_preflight() {
	local manifest="$1" allow_absent="${2:-0}" instance
	local lock_file="${QBT_FLEET_LOCK_FILE:-/run/proton/qbt-fleet.lock}"
	mkdir -p "${lock_file%/*}" || return 1
	exec {QBT_FLEET_LOCK_FD}>"$lock_file" || return 1
	flock -w "${QBT_FLEET_LOCK_WAIT_SECONDS:-30}" "$QBT_FLEET_LOCK_FD" || return 1
	qbt_storage_ready || {
		printf 'ERROR: Expected writable cache=none CIFS leaf is unavailable.\n' >&2
		return 1
	}
	[[ "$(awk -F '\t' '!/^#/ && NF { print $1 }' "$manifest" | sort)" == "$(printf '%s\n' lidarr prowlarr radarr sonarr whisparr | sort)" ]] || return 1
	while IFS=$'\t' read -r instance _; do
		[[ -n "$instance" && "$instance" != \#* ]] || continue
		qbt_container_safe_for_recreate "qbittorrent-$instance" "$allow_absent" || {
			printf 'ERROR: Unsafe or unknown task state for %s; refusing the entire rollout.\n' "$instance" >&2
			return 1
		}
	done <"$manifest"
}

export QBT_LOGIN_ERROR=""
export QBT_LOGIN_HTTP_STATUS=""

qbt_login() {
	local cookie_jar="$1"
	local login_body
	local http_status curl_exit curl_error
	local response_file error_file

	: "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"
	: "${QBITTORRENT_USER:?Missing QBITTORRENT_USER}"
	: "${QBITTORRENT_PASS:?Missing QBITTORRENT_PASS}"

	QBT_LOGIN_ERROR=""
	QBT_LOGIN_HTTP_STATUS=""

	: >"$cookie_jar"
	response_file="$(mktemp)"
	error_file="$(mktemp)"

	http_status="$(curl -sS \
		-o "$response_file" \
		-w '%{http_code}' \
		-c "$cookie_jar" \
		--data-urlencode "username=$QBITTORRENT_USER" \
		--data-urlencode "password=$QBITTORRENT_PASS" \
		"$QBITTORRENT_URL/api/v2/auth/login" 2>"$error_file")"
	curl_exit=$?
	login_body="$(cat "$response_file" 2>/dev/null || true)"

	rm -f "$response_file"

	if [[ "$curl_exit" -ne 0 ]]; then
		curl_error="$(tr '\n' ' ' <"$error_file")"
		rm -f "$error_file"
		if [[ -n "$curl_error" ]]; then
			QBT_LOGIN_ERROR="qBittorrent Web UI unreachable at $QBITTORRENT_URL (${curl_error})"
		else
			QBT_LOGIN_ERROR="qBittorrent Web UI unreachable at $QBITTORRENT_URL (curl exit $curl_exit)"
		fi
		return 1
	fi

	rm -f "$error_file"
	QBT_LOGIN_HTTP_STATUS="${http_status:-000}"

	# qBittorrent Web UI variants may return an empty body with HTTP 204 on
	# successful login while still setting the session cookie (QBT_SID_*).
	# Accept either the legacy "Ok." body or HTTP 200/204 or presence of the
	# session cookie as a successful login.
	if [[ "$login_body" == "Ok." ]] || [[ "$QBT_LOGIN_HTTP_STATUS" == "200" ]] || [[ "$QBT_LOGIN_HTTP_STATUS" == "204" ]] || grep -q 'QBT_SID' "$cookie_jar" 2>/dev/null; then
		return 0
	fi

	if [[ -n "$login_body" ]]; then
		QBT_LOGIN_ERROR="qBittorrent rejected login at $QBITTORRENT_URL (HTTP ${QBT_LOGIN_HTTP_STATUS}: ${login_body})"
	else
		QBT_LOGIN_ERROR="qBittorrent rejected login at $QBITTORRENT_URL (HTTP ${QBT_LOGIN_HTTP_STATUS})"
	fi

	return 1
}

qbt_get_listen_port() {
	local cookie_jar="$1"

	curl -fsS -b "$cookie_jar" \
		"$QBITTORRENT_URL/api/v2/app/preferences" |
		tr ',{}' '\n' |
		awk -F: '/"listen_port"/ {gsub(/[^0-9]/, "", $2); print $2; exit}'
}

qbt_webui_http_status() {
	local max_time="${1:-5}"

	curl -sS -o /dev/null -w '%{http_code}' --max-time "$max_time" \
		"$QBITTORRENT_URL/api/v2/app/version" || true
}

qbt_webui_reachable() {
	local max_time="${1:-5}"
	local http_status

	http_status="$(qbt_webui_http_status "$max_time")"

	case "$http_status" in
	200 | 204 | 301 | 302 | 303 | 307 | 308 | 401 | 403)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

qbt_wait_for_webui() {
	local max_attempts="${1:-12}"
	local sleep_seconds="${2:-5}"
	local attempt

	: "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"

	for ((attempt = 1; attempt <= max_attempts; attempt++)); do
		if qbt_webui_reachable 5; then
			return 0
		fi
		sleep "$sleep_seconds"
	done

	return 1
}
