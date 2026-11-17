#!/usr/bin/env bats

# proton-qbittorrent-sync-safe.sh: manual stops, self-heal, and zombie/D-state recreation refusal.

load proton-qbittorrent-sync-helper

@test "compose-recreate mode skips self-heal when qBittorrent is manually stopped" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_LOGIN_FAIL=1 QBT_TEST_CONTAINER_STATUS=exited bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  run grep -F 'CMD=compose up ' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "a container that exited during a Docker restart is restored, not treated as a manual stop" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"
  printf 'exited' > "${DOCKER_LOG}.status"
  finished="$(date -d 2026-09-12T00:00:00Z +%s)"

  # Docker began stopping 60 s before the container finished and was active
  # again 30 s after, as when systemd killed dockerd mid-shutdown.
  run env QBT_TEST_LOGIN_FAIL=while-stopped QBT_TEST_DOCKER_STOP_BEGAN=$((finished - 60)) \
    QBT_TEST_DOCKER_STARTED=$((finished + 30)) bash ./proton-qbittorrent-sync-safe.sh sonarr

  [ "$status" -eq 0 ]
  [ "$(cat "${DOCKER_LOG}.compose-40001.count")" -eq 1 ]
  [ "$(cat "${DOCKER_LOG}.status")" = running ]
  grep -Fxq 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
}

@test "an exit outside the Docker restart window is still respected as a manual stop" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"
  finished="$(date -d 2026-09-12T00:00:00Z +%s)"

  # Stopped before Docker began restarting; stopped after Docker was back
  # (beyond the 10 s slack); and a restart window that is still open.
  for window in "$((finished + 60)) $((finished + 120))" "$((finished - 120)) $((finished - 11))" \
    "$((finished - 60)) $((finished - 120))"; do
    printf 'exited' > "${DOCKER_LOG}.status"
    run env QBT_TEST_LOGIN_FAIL=while-stopped QBT_TEST_DOCKER_STOP_BEGAN="${window% *}" \
      QBT_TEST_DOCKER_STARTED="${window#* }" bash ./proton-qbittorrent-sync-safe.sh sonarr
    [ "$status" -eq 0 ]
    [ ! -e "${DOCKER_LOG}.compose-40001.count" ]
    [ "$(cat "${DOCKER_LOG}.status")" = exited ]
  done
  grep -Fxq 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "compose-recreate mode skips self-heal when qBittorrent stop is still in progress" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_LOGIN_FAIL=1 QBT_TEST_CONTAINER_STATUS=running QBT_TEST_RECENT_MANUAL_STOP_EVENT=network bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  run grep -F 'CMD=compose up ' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "compose-recreate mode still self-heals a running container with unreachable Web UI" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_LOGIN_FAIL=1 QBT_TEST_CONTAINER_STATUS=running bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
}

@test "self-heal leaves a recently started container alone during its startup grace" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"
  stub_systemd_cat "$TEST_TMPDIR/journal.log"

  run env QBT_TEST_LOGIN_FAIL=1 QBT_TEST_CONTAINER_STATUS=running \
    QBT_TEST_STARTED_AT="$(date -u -d '-240 seconds' +%FT%T.000000000Z)" bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  run grep -E 'CMD=(top|compose (stop|up))' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  grep -E 'Web UI unreachable 2[0-9]{2}s after container start; within the 600s startup grace' "$TEST_TMPDIR/journal.log"
  grep -Fx 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "self-heal resumes once the startup grace has elapsed or is disabled" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"
  started="$(date -u -d '-240 seconds' +%FT%T.000000000Z)"

  for grace in 120 0; do
    rm -f "$DOCKER_LOG" "${DOCKER_LOG}".*
    run env QBT_TEST_LOGIN_FAIL=until-compose QBT_TEST_CONTAINER_STATUS=running QBT_TEST_STARTED_AT="$started" \
      QBT_SELF_HEAL_STARTUP_GRACE_SECONDS="$grace" bash ./proton-qbittorrent-sync-safe.sh sonarr
    [ "$status" -eq 0 ]
    grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
  done
}

@test "forced fleet recreation is not delayed by the self-heal startup grace" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBT_TEST_LOGIN_FAIL=until-compose QBT_TEST_CONTAINER_STATUS=running QBT_FORCE_RECREATE=1 \
    QBT_TEST_STARTED_AT="$(date -u -d '-30 seconds' +%FT%T.000000000Z)" bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
}

@test "an invalid self-heal startup grace is rejected" {
  write_qbt_env compose-recreate
  write_lease 40001
  run env QBT_SELF_HEAL_STARTUP_GRACE_SECONDS=10m bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  run grep -F 'CMD=' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "compose-recreate mode refuses self-heal when running container has no published ports" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_LOGIN_FAIL=1 QBT_TEST_CONTAINER_STATUS=running QBT_TEST_DOCKER_NO_PORTS=1 QBT_TEST_DOCKER_ZOMBIE=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  run grep -F 'CMD=compose up ' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "forced fleet recreation repairs a safe running container with no published ports" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_LOGIN_FAIL=until-compose QBT_TEST_CONTAINER_STATUS=running QBT_TEST_DOCKER_NO_PORTS=until-compose QBT_FORCE_RECREATE=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
  grep -F 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
}

@test "compose-recreate mode refuses self-heal when running container has zombie process" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_LOGIN_FAIL=1 QBT_TEST_CONTAINER_STATUS=running QBT_TEST_DOCKER_ZOMBIE=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  run grep -F 'CMD=compose up ' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "compose-recreate mode identifies kernel D-state as a host recovery boundary" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_LOGIN_FAIL=1 QBT_TEST_CONTAINER_STATUS=running QBT_TEST_DOCKER_DSTATE=1 QBT_DSTATE_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  run grep -F 'CMD=compose up ' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "a D-state task that is never scheduled between samples blocks recreation" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBT_TEST_CONTAINER_STATUS=running QBT_TEST_DOCKER_DSTATE=1 QBT_TEST_DSTATE_RUNS=frozen QBT_DSTATE_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  run grep -E 'CMD=compose (stop|up)' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'CMD=top qbittorrent ' "$DOCKER_LOG")" -eq 3 ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "a D-state task that keeps being scheduled is slow I/O, not a wedge" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBT_TEST_CONTAINER_STATUS=running QBT_TEST_DOCKER_DSTATE=1 QBT_TEST_DSTATE_RUNS=advancing QBT_DSTATE_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  [ "$(grep -c 'CMD=top qbittorrent ' "$DOCKER_LOG")" -eq 2 ]
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
  grep -Fx 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
}

@test "compose-recreate mode allows a transient D-state I/O wait to clear" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_CONTAINER_STATUS=running QBT_TEST_DOCKER_DSTATE=transient QBT_DSTATE_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
}

@test "compose-recreate task probe includes Docker-required PID while tracking LWP state" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_CONTAINER_STATUS=running bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  grep -F 'CMD=top qbittorrent -eLo pid,lwp,stat' "$DOCKER_LOG"
  run grep -F -- '-eLo lwp,stat' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
}

@test "failed task inspection or stop prevents recreation and lock removal" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"
  mkdir -p "$PROJECT_DIR/config/qBittorrent"
  touch "$PROJECT_DIR/config/qBittorrent/lockfile"
  for failure in QBT_TEST_TOP_FAIL QBT_TEST_STOP_FAIL; do
    run env "$failure=1" QBITTORRENT_ENV_FILE="$ENV_FILE" QBT_COMMON_SCRIPT=./proton-qbittorrent-common.sh bash ./proton-qbittorrent-sync-safe.sh sonarr
    [ "$status" -ne 0 ]
    [ -f "$PROJECT_DIR/config/qBittorrent/lockfile" ]
    if grep -F 'CMD=compose up ' "$DOCKER_LOG"; then return 1; fi
  done
}
