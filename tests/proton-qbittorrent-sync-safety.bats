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
    ! grep -F 'CMD=compose up ' "$DOCKER_LOG"
  done
}
