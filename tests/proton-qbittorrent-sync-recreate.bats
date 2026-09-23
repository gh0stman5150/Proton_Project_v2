#!/usr/bin/env bats

# proton-qbittorrent-sync-safe.sh: forced recreation, lease freshness during recreation, pending-recreation retry, busy ports, and sync locking.

load proton-qbittorrent-sync-helper

@test "compose-recreate mode can force a rolling fleet configuration refresh when the port is unchanged" {
  write_qbt_env compose-recreate
  write_lease 40000
  echo 'QBT_PUBLISHED_PORT=40000' > "$PORT_ENV_FILE"
  printf '40000' > "$CURL_STATE"
  printf '40000' > "$DOCKER_PORT_FILE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_FORCE_RECREATE=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
  [ "$(awk '/^[A-Za-z_][A-Za-z0-9_]*=/ { count++ } END { print count + 0 }' "$PORT_ENV_FILE")" -eq 1 ]
}

@test "recreation refuses a lease that expires while Docker stops the old container" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=40001' > "$PORT_ENV_FILE"
  printf '40001' > "$CURL_STATE"
  printf '40001' > "$DOCKER_PORT_FILE"

  run env QBT_FORCE_RECREATE=1 QBT_TEST_EXPIRE_LEASE_ON_STOP=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
  sync_status="$status"
  grep -F 'CMD=compose stop ' "$DOCKER_LOG"
  run grep -F 'CMD=compose up ' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  [ "$sync_status" -ne 0 ]
}

@test "recreation cannot report success when the lease expires during replacement startup" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"
  printf '30000' > "$DOCKER_PORT_FILE"

  run env QBT_TEST_EXPIRE_LEASE_ON_UP=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -ne 0 ]
  grep -F 'CMD=compose up ' "$DOCKER_LOG"
  grep -Fx 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
  [ "$(cat "$CACHE_FILE")" = 30000 ]
  [ ! -f "${CACHE_FILE%/*}/qbt-recreate.pending" ]
}

@test "failed forced same-port recreation preserves the published-port artifact and cache" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=40001' > "$PORT_ENV_FILE"
  printf '40001' > "$CACHE_FILE"
  printf '40001' > "$CURL_STATE"
  printf '40001' > "$DOCKER_PORT_FILE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_FORCE_RECREATE=1 QBT_TEST_COMPOSE_FAIL_PORT=40001 QBT_TEST_COMPOSE_FAIL_MODE=always QBT_COMPOSE_RECREATE_RETRIES=1 QBT_COMPOSE_RECREATE_RETRY_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  grep -Fxq 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
  [[ "$(cat "$CACHE_FILE")" == "40001" ]]
}

@test "sync retries its own failed recreation instead of treating it as a manual stop" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBT_TEST_COMPOSE_FAIL_PORT=40001 QBT_COMPOSE_RECREATE_RETRIES=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -ne 0 ]
  [ "$(cat "${DOCKER_LOG}.status")" = exited ]
  [ "$(cat "${DOCKER_LOG}.compose-40001.count")" -eq 1 ]
  [ -s "${CACHE_FILE%/*}/qbt-recreate.pending" ]
  [ "$("$REAL_STAT" -c %a "${CACHE_FILE%/*}/qbt-recreate.pending")" = 600 ]

  run env QBT_TEST_LOGIN_FAIL=while-stopped bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$(cat "${DOCKER_LOG}.compose-40001.count")" -eq 2 ]
  [ "$status" -eq 0 ]
  [ "$(cat "${DOCKER_LOG}.status")" = running ]
  [ ! -f "${CACHE_FILE%/*}/qbt-recreate.pending" ]
}

@test "pending recreation never overrides a later stop or a replacement container" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  for changed_identity in \
    QBT_TEST_FINISHED_AT=2026-09-12T00:01:00Z \
    QBT_TEST_CONTAINER_ID=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff; do
    rm -f "${DOCKER_LOG}.compose-40001.count"
    run env QBT_TEST_COMPOSE_FAIL_PORT=40001 QBT_COMPOSE_RECREATE_RETRIES=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
    [ "$status" -ne 0 ]
    [ -s "${CACHE_FILE%/*}/qbt-recreate.pending" ]

    run env "$changed_identity" QBT_TEST_LOGIN_FAIL=while-stopped bash ./proton-qbittorrent-sync-safe.sh sonarr
    [ "$status" -eq 0 ]
    [ "$(cat "${DOCKER_LOG}.compose-40001.count")" -eq 1 ]
    [ "$(cat "${DOCKER_LOG}.status")" = exited ]
    [ ! -f "${CACHE_FILE%/*}/qbt-recreate.pending" ]
  done
}

@test "compose-recreate mode retries a busy host port before succeeding" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_COMPOSE_FAIL_PORT=40001 QBT_TEST_COMPOSE_FAIL_MODE=once QBT_COMPOSE_RECREATE_RETRIES=2 QBT_COMPOSE_RECREATE_RETRY_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  [[ "$(grep -c 'QBT_PUBLISHED_PORT=40001 CMD=compose up' "$DOCKER_LOG")" -eq 2 ]]
  grep -F 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
}

@test "failed recreation retains metadata but never recreates using a historical lease" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_COMPOSE_FAIL_PORT=40001 QBT_TEST_COMPOSE_FAIL_MODE=always QBT_COMPOSE_RECREATE_RETRIES=2 QBT_COMPOSE_RECREATE_RETRY_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
  run grep -F 'QBT_PUBLISHED_PORT=30000 CMD=compose up' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  [[ "$(cat "$CURL_STATE")" == "40001" ]]
}

@test "compose-recreate mode skips when another sync instance already holds the lock" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_FLOCK_FAIL=1 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  [ ! -s "$DOCKER_LOG" ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "forced recreation fails when another sync instance keeps the lock" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_FLOCK_FAIL=1 QBT_FORCE_RECREATE=1 QBT_SYNC_LOCK_WAIT_SECONDS=0 bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 1 ]
  [ ! -s "$DOCKER_LOG" ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}
