# shellcheck shell=bash
# Shared fixtures for proton-qbittorrent-sync-*.bats. Loaded with `load`.

load common-stubs

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  REAL_STAT="$(command -v stat)"
  export REAL_STAT
  export PATH="$TMPBIN:$PATH"
  export STATE_FILE="$TEST_TMPDIR/proton-port.state"
  export CACHE_FILE="$TEST_TMPDIR/qbt-port.cache"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export ENV_FILE="$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env"
  export PORT_ENV_FILE="$PROTON_INSTANCE_ROOT/sonarr/qbittorrent-port.env"
  export CURL_STATE="$TEST_TMPDIR/current-qbt-port"
  export DOCKER_LOG="$TEST_TMPDIR/docker.log"
  export DOCKER_PORT_FILE="$TEST_TMPDIR/docker-published-port"
  export NFT_LOG="$TEST_TMPDIR/nft.log"
  export KILLSWITCH_LOCK_FILE="$TEST_TMPDIR/killswitch.lock"
  export CURL_LOG="$TEST_TMPDIR/curl.log"
  export PROJECT_DIR="$TEST_TMPDIR/project"
  export QBT_ROUTE_RECONCILE_SCRIPT="$TEST_TMPDIR/routes.sh"
  export DOCKER_CONFIG_DIR="$TEST_TMPDIR/docker-config"
  mkdir -p "$PROJECT_DIR" "$PROTON_INSTANCE_ROOT/sonarr"
  : > "$PROTON_COMMON_ENV"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$QBT_ROUTE_RECONCILE_SCRIPT"

  cat > "$TMPBIN/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'cifs rw,cache=none\n'
EOF
  chmod +x "$TMPBIN/findmnt"

  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<EOF
STATE_DIR=$TEST_TMPDIR
STATE_FILE=$STATE_FILE
CACHE_FILE=$CACHE_FILE
DOCKER_CONFIG_DIR=$DOCKER_CONFIG_DIR
EOF
  append_manifest_routing sonarr "$PROTON_INSTANCE_ROOT/sonarr/proton.env"

  stub_systemd_cat

  # docker.service stop/start times for the Docker-restart window; unset means
  # Docker has not restarted since boot.
  stub_command systemctl <<'EOF'
case "$*" in
  *ActiveExitTimestamp*) [[ -z "${QBT_TEST_DOCKER_STOP_BEGAN:-}" ]] || printf '@%s\n' "$QBT_TEST_DOCKER_STOP_BEGAN" ;;
  *ActiveEnterTimestamp*) [[ -z "${QBT_TEST_DOCKER_STARTED:-}" ]] || printf '@%s\n' "$QBT_TEST_DOCKER_STARTED" ;;
esac
exit 0
EOF

  cat > "$TMPBIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == '-c' && "$2" == '%a' ]]; then
  echo 600
  exit 0
fi
if [[ "$1" == '-c' && "$2" == '%u' ]]; then
  echo 0
  exit 0
fi
exec "$REAL_STAT" "$@"
EOF
  chmod +x "$TMPBIN/stat"

  stub_curl <<'EOF'
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *'/api/v2/auth/login'*)
    if [[ "${QBT_TEST_LOGIN_FAIL:-}" == "1" ]] ||
      { [[ "${QBT_TEST_LOGIN_FAIL:-}" == "while-stopped" ]] && [[ "$(cat "${DOCKER_LOG}.status" 2>/dev/null)" == exited ]]; } ||
      { [[ "${QBT_TEST_LOGIN_FAIL:-}" == "until-compose" ]] && ! compgen -G "${DOCKER_LOG}.compose-*.count" >/dev/null; }; then
      printf 'connection refused\n' >&2
      exit 7
    fi
    write_body 'Ok.'
    if [[ "$*" == *'%{http_code}'* ]]; then
      printf '200'
    fi
    ;;
  *'/api/v2/app/preferences'*)
    write_body "{\"listen_port\":$(cat "$CURL_STATE")}"
    ;;
  *'/api/v2/app/setPreferences'*)
    for arg in "$@"; do
      if [[ "$arg" =~ ^json=\{\"listen_port\":([0-9]+)\}$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}" > "$CURL_STATE"
      fi
    done
    ;;
  *'/api/v2/app/version'*)
    if [[ "$*" == *'%{http_code}'* ]]; then
      printf '200'
    fi
    ;;
  *)
    echo "unexpected curl invocation: $*" >&2
    exit 1
    ;;
esac
exit 0
EOF
  chmod +x "$TMPBIN/curl"

  cat > "$TMPBIN/flock" <<'EOF'
#!/usr/bin/env bash
if [[ "${QBT_TEST_FLOCK_FAIL:-}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$TMPBIN/flock"

  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'PWD=%s DOCKER_CONFIG=%s QBT_PUBLISHED_PORT=%s CMD=%s\n' "$PWD" "${DOCKER_CONFIG:-}" "${QBT_PUBLISHED_PORT:-}" "$*" >> "$DOCKER_LOG"
current_published_port() {
  local port="${QBT_TEST_DOCKER_PUBLISHED_PORT:-}"

  if [[ -z "$port" && -n "${DOCKER_PORT_FILE:-}" && -f "$DOCKER_PORT_FILE" ]]; then
    port="$(cat "$DOCKER_PORT_FILE")"
  fi

  if [[ -z "$port" && -n "${PORT_ENV_FILE:-}" && -f "$PORT_ENV_FILE" ]]; then
    port="$(awk -F= '/^QBT_PUBLISHED_PORT=/ {print $2; exit}' "$PORT_ENV_FILE" 2>/dev/null || true)"
  fi

  printf '%s\n' "${port:-6881}"
}

if [[ "$1" == 'compose' ]]; then
  if [[ "$2" == 'ps' ]]; then
    echo 'qbittorrent'
    exit 0
  fi
  if [[ "$2" == 'stop' ]]; then
	if [[ "${QBT_TEST_STOP_FAIL:-}" == 1 ]]; then exit 1; fi
	printf 'exited' > "${DOCKER_LOG}.status"
    if [[ "${QBT_TEST_EXPIRE_LEASE_ON_STOP:-0}" == 1 ]]; then
      sed -i 's/^LEASE_EXPIRES_AT=.*/LEASE_EXPIRES_AT=1/' "$STATE_FILE"
    fi
    exit 0
  fi

  counter_file="${DOCKER_LOG}.compose-${QBT_PUBLISHED_PORT:-unset}.count"
  attempt=0
  if [[ -f "$counter_file" ]]; then
    attempt="$(cat "$counter_file")"
  fi
  attempt=$((attempt + 1))
  printf '%s' "$attempt" > "$counter_file"

  if [[ "${QBT_TEST_COMPOSE_FAIL_PORT:-}" == "${QBT_PUBLISHED_PORT:-}" ]]; then
    case "${QBT_TEST_COMPOSE_FAIL_MODE:-always}" in
      once)
        if [[ "$attempt" -eq 1 ]]; then
          printf '%s\n' "Error response from daemon: driver failed programming external connectivity on endpoint qbittorrent: Bind for 0.0.0.0:${QBT_PUBLISHED_PORT} failed: port is already allocated" >&2
          exit 1
        fi
        ;;
      always)
        printf '%s\n' "Error response from daemon: driver failed programming external connectivity on endpoint qbittorrent: Bind for 0.0.0.0:${QBT_PUBLISHED_PORT} failed: port is already allocated" >&2
        exit 1
        ;;
    esac
  fi

  if [[ -n "${DOCKER_PORT_FILE:-}" && -n "${QBT_PUBLISHED_PORT:-}" ]]; then
    printf '%s' "$QBT_PUBLISHED_PORT" > "$DOCKER_PORT_FILE"
  fi
	printf 'running' > "${DOCKER_LOG}.status"
  if [[ "${QBT_TEST_EXPIRE_LEASE_ON_UP:-0}" == 1 ]]; then
    sed -i 's/^LEASE_EXPIRES_AT=.*/LEASE_EXPIRES_AT=1/' "$STATE_FILE"
  fi
  exit 0
fi
if [[ "$1" == 'restart' ]]; then
  exit 0
fi
if [[ "$1" == 'inspect' && "$2" == '-f' ]]; then
  if [[ "$3" == '{{.State.Status}}' ]]; then
	if [[ -f "${DOCKER_LOG}.status" ]]; then cat "${DOCKER_LOG}.status"; exit 0; fi
    echo "${QBT_TEST_CONTAINER_STATUS:-running}"
    exit 0
  fi
  if [[ "$3" == '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ]]; then
    printf 'healthy\n'
    exit 0
  fi
  if [[ "$3" == '{{.Id}}' ]]; then
    echo "${QBT_TEST_CONTAINER_ID:-123456789abc0000000000000000000000000000000000000000000000000000}"
    exit 0
  fi
  if [[ "$3" == '{{.State.FinishedAt}}' ]]; then
    printf '%s\n' "${QBT_TEST_FINISHED_AT:-2026-09-12T00:00:00Z}"
    exit 0
  fi
  if [[ "$3" == *'.NetworkSettings.Ports'* ]]; then
    if [[ "${QBT_TEST_DOCKER_NO_PORTS:-}" == "1" ]] ||
      { [[ "${QBT_TEST_DOCKER_NO_PORTS:-}" == "until-compose" ]] && ! compgen -G "${DOCKER_LOG}.compose-*.count" >/dev/null; }; then
      exit 0
    fi
    port="$(current_published_port)"
    printf '%s/tcp %s\n' "$port" "$port"
    printf '%s/udp %s\n' "$port" "$port"
    printf '8081/tcp 8081\n'
    exit 0
  fi
  if [[ "$3" == *'.NetworkSettings.Networks'* ]]; then
    echo 'starr=172.18.0.10'
    exit 0
  fi
  echo 'starr=172.18.0.10'
  exit 0
fi
if [[ "$1" == 'top' ]]; then
  if [[ "${QBT_TEST_TOP_FAIL:-}" == 1 ]]; then exit 1; fi
  if [[ "$*" == *'-eLo lwp,stat'* ]]; then
    printf '%s\n' "Error response from daemon: Couldn't find PID field in ps output" >&2
    exit 1
  fi
  if [[ "${QBT_TEST_DOCKER_DSTATE:-}" == "1" ]]; then
    printf 'PID LWP STAT\n'
    printf '2 22 Dsl\n'
  elif [[ "${QBT_TEST_DOCKER_DSTATE:-}" == "transient" ]]; then
    counter_file="${DOCKER_LOG}.dstate.count"
    count=0
    [[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$counter_file"
    printf 'PID LWP STAT\n'
    if [[ "$count" -eq 1 ]]; then
      printf '2 22 Dsl\n'
    else
      printf '2 22 Ssl\n'
    fi
  elif [[ "${QBT_TEST_DOCKER_ZOMBIE:-}" == "1" ]]; then
    printf 'PID LWP STAT\n'
    printf '1 11 Ss\n'
    printf '2 22 Zsl\n'
  elif [[ "$*" == *'-eLo pid,lwp,stat'* ]]; then
    printf 'PID LWP STAT\n'
    printf '1 11 Ssl\n'
  else
    printf 'PID STAT CMD\n'
    printf '1 Ssl qbittorrent-nox\n'
  fi
  exit 0
fi
if [[ "$1" == 'events' ]]; then
  if [[ "${QBT_TEST_RECENT_MANUAL_STOP_EVENT:-}" == "container" && "$*" == *"--filter container="* ]]; then
    echo 'stop'
  fi
  if [[ "${QBT_TEST_RECENT_MANUAL_STOP_EVENT:-}" == "network" && "$*" == *"--filter type=network"* ]]; then
    echo "${QBT_TEST_CONTAINER_ID:-123456789abc0000000000000000000000000000000000000000000000000000}"
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPBIN/docker"

  cat > "$TMPBIN/nft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NFT_LOG"
if [[ "$*" == '-f -' ]]; then
  cat >> "$NFT_LOG"
  exit "${QBT_TEST_NFT_APPLY_FAIL:-0}"
fi
if [[ "$*" == 'list tables' ]]; then exit "${QBT_TEST_NFT_READ_FAIL:-0}"; fi
case "$1" in
  list)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$TMPBIN/nft"
}

write_lease() {
  write_lease_fixture "$STATE_FILE" "$@"
}

write_qbt_env() {
  local mode="$1"
  local container="${2:-qbittorrent}"
  cat > "$ENV_FILE" <<EOF
QBITTORRENT_URL=http://127.0.0.1:8081
QBITTORRENT_USER=test-user
QBITTORRENT_PASS=test-pass
QBT_PORT_APPLY_MODE=$mode
QBT_COMPOSE_PROJECT_DIR=$PROJECT_DIR
QBT_COMPOSE_SERVICE=$container
QBT_PORT_ENV_FILE=$PORT_ENV_FILE
QBT_CONTAINER_NAME=$container
QBT_NETWORK_NAME=starr
EOF
}
