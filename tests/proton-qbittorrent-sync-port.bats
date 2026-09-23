#!/usr/bin/env bats

# proton-qbittorrent-sync-safe.sh: port changes, artifact schema, Docker mapping drift, and legacy DNAT.

load proton-qbittorrent-sync-helper

@test "fleet reconciliation repairs out-of-band Docker port drift for all five independent leases" {
  if ! command -v unshare >/dev/null || ! unshare --user --map-root-user true 2>/dev/null; then
    skip "user namespaces are required for the mocked root-only fleet entrypoint"
  fi
  local instance subnet port
  export FLEET_ORDER_LOG="$TEST_TMPDIR/fleet-order.log"
  export QBT_INSTANCE_MANIFEST="$PWD/qbittorrent-instances.tsv"
  export QBT_COMMON_SCRIPT="$PWD/proton-qbittorrent-common.sh"
  export QBT_FLEET_LOCK_FILE="$TEST_TMPDIR/fleet.lock"
  export QBT_FLEET_VERIFY_SCRIPT="$TEST_TMPDIR/verify.sh"
  export QBT_SYNC_SCRIPT="$TEST_TMPDIR/fleet-sync.sh"
  export TEST_SYNC_SOURCE="$PWD/proton-qbittorrent-sync-safe.sh"
  cat > "$QBT_FLEET_VERIFY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf 'verify %s\n' "$1" >> "$FLEET_ORDER_LOG"
EOF
  cat > "$QBT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf 'sync %s force=%s\n' "$1" "$QBT_FORCE_RECREATE" >> "$FLEET_ORDER_LOG"
exec bash "$TEST_SYNC_SOURCE" "$@"
EOF
  chmod +x "$QBT_FLEET_VERIFY_SCRIPT" "$QBT_SYNC_SCRIPT"
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    case "$instance" in
      lidarr) subnet=2 ;;
      prowlarr) subnet=6 ;;
      radarr) subnet=3 ;;
      sonarr) subnet=4 ;;
      whisparr) subnet=5 ;;
    esac
    port=$((40000 + subnet))
    ENV_FILE="$PROTON_INSTANCE_ROOT/$instance/qbittorrent.env"
    PORT_ENV_FILE="$PROTON_INSTANCE_ROOT/$instance/qbittorrent-port.env"
    PROJECT_DIR="$TEST_TMPDIR/project-$instance"
    STATE_FILE="$TEST_TMPDIR/state-$instance/proton-port.state"
    CACHE_FILE="$TEST_TMPDIR/state-$instance/cache"
    CURL_STATE="$TEST_TMPDIR/state-$instance/listen-port"
    DOCKER_PORT_FILE="$TEST_TMPDIR/state-$instance/docker-port"
    DOCKER_LOG="$TEST_TMPDIR/state-$instance/docker.log"
    mkdir -p "$PROTON_INSTANCE_ROOT/$instance" "$PROJECT_DIR" "${STATE_FILE%/*}"
    cat > "$PROTON_INSTANCE_ROOT/$instance/proton.env" <<EOF
WG_ADDRESS_SUBNET=$subnet
STATE_DIR=${STATE_FILE%/*}
STATE_FILE=$STATE_FILE
CACHE_FILE=$CACHE_FILE
CURL_STATE=$CURL_STATE
DOCKER_PORT_FILE=$DOCKER_PORT_FILE
DOCKER_LOG=$DOCKER_LOG
PORT_ENV_FILE=$PORT_ENV_FILE
EOF
    write_qbt_env compose-recreate "qbittorrent-$instance"
    write_lease "$port" "10.$subnet.0.2"
    printf 'QBT_PUBLISHED_PORT=%s\n' "$port" > "$PORT_ENV_FILE"
    printf '%s\n' "$port" > "$CURL_STATE"
    printf '30000\n' > "$DOCKER_PORT_FILE"
  done

  run unshare --user --map-root-user env QBT_FLEET_DSTATE_DELAY=0 bash tools/reconcile-qbittorrent-fleet.sh --recreate
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$FLEET_ORDER_LOG")" = 'verify --config' ]
  [ "$(tail -n 1 "$FLEET_ORDER_LOG")" = 'verify --runtime' ]
  [ "$(awk '$1 == "sync" {print $2}' "$FLEET_ORDER_LOG" | paste -sd ' ')" = 'lidarr prowlarr radarr sonarr whisparr' ]
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    port="$(awk -F= '$1 == "CURRENT_PORT" {print $2}' "$TEST_TMPDIR/state-$instance/proton-port.state")"
    grep -Fx "sync $instance force=1" "$FLEET_ORDER_LOG"
    [ "$(cat "$TEST_TMPDIR/state-$instance/docker-port")" = "$port" ]
    grep -F "QBT_PUBLISHED_PORT=$port CMD=compose up -d --force-recreate --no-deps qbittorrent-$instance" "$TEST_TMPDIR/state-$instance/docker.log"
  done
}

@test "compose-recreate mode skips docker compose when forwarded port is unchanged" {
  write_qbt_env compose-recreate
  write_lease 40000
  echo 'QBT_PUBLISHED_PORT=40000' > "$PORT_ENV_FILE"
  printf '40000' > "$CURL_STATE"

  for ((attempt = 1; attempt <= 2; attempt++)); do
    run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh sonarr
    [ "$status" -eq 0 ]
  done
  run grep -F 'CMD=compose up ' "$DOCKER_LOG"
  [ "$status" -eq 1 ]
  grep -F 'QBT_PUBLISHED_PORT=40000' "$PORT_ENV_FILE"
}

@test "compose-recreate mode collapses a legacy two-key port artifact without restarting" {
  write_qbt_env compose-recreate
  write_lease 40000
  cat > "$PORT_ENV_FILE" <<'EOF'
QBT_PUBLISHED_PORT=40000
QBT_FORWARDED_PORT=40000
EOF
  printf '40000' > "$CURL_STATE"
  printf '40000' > "$DOCKER_PORT_FILE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  [ "$(awk '/^[A-Za-z_][A-Za-z0-9_]*=/ { count++ } END { print count + 0 }' "$PORT_ENV_FILE")" -eq 1 ]
  grep -Fxq 'QBT_PUBLISHED_PORT=40000' "$PORT_ENV_FILE"
  run grep -Fq 'QBT_FORWARDED_PORT=' "$PORT_ENV_FILE"
  [ "$status" -eq 1 ]
  ! grep -F 'CMD=compose up ' "$DOCKER_LOG"
}

@test "compose-recreate mode refuses the project static .env as its dynamic port artifact" {
  write_qbt_env compose-recreate
  echo "QBT_PORT_ENV_FILE=$PROJECT_DIR/.env" >> "$ENV_FILE"
  write_lease 40000

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -ne 0 ]
  ! grep -F 'CMD=compose up ' "$DOCKER_LOG"
}

@test "compose-recreate mode refuses a symlink that resolves to the project static .env" {
  write_qbt_env compose-recreate
  touch "$PROJECT_DIR/.env"
  ln -s "$PROJECT_DIR/.env" "$TEST_TMPDIR/port-alias.env"
  echo "QBT_PORT_ENV_FILE=$TEST_TMPDIR/port-alias.env" >> "$ENV_FILE"
  write_lease 40000

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -ne 0 ]
  ! grep -F 'CMD=compose up ' "$DOCKER_LOG"
}

@test "compose-recreate mode recreates when artifact matches but Docker still publishes the old port" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=40001' > "$PORT_ENV_FILE"
  printf '40001' > "$CURL_STATE"
  printf '30000' > "$DOCKER_PORT_FILE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  grep -F 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
  [[ "$(cat "$DOCKER_PORT_FILE")" == "40001" ]]
}

@test "compose-recreate mode updates the published-port artifact and recreates the service on port change" {
  write_qbt_env compose-recreate
  write_lease 40001
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  grep -F 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
  grep -F "PWD=$PROJECT_DIR" "$DOCKER_LOG"
  grep -F "DOCKER_CONFIG=$DOCKER_CONFIG_DIR" "$DOCKER_LOG"
  grep -F 'QBT_PUBLISHED_PORT=40001' "$DOCKER_LOG"
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
  [ "$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { count++ } END { print count + 0 }' "$PORT_ENV_FILE")" -eq 1 ]
  ! grep -Fq 'QBT_FORWARDED_PORT=' "$PORT_ENV_FILE"
}

@test "legacy-dnat mode refreshes nft DNAT rules without invoking docker compose" {
  write_qbt_env legacy-dnat
  write_lease 45000
  printf '45000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh sonarr
  [ "$status" -eq 0 ]
  grep -F 'add rule ip proton_nat prerouting iifname "pvsonarr" tcp dport 45000 dnat to 172.18.0.10:6881 comment "qbt-dnat-sonarr"' "$NFT_LOG"
  grep -F 'add rule ip proton_nat prerouting iifname "pvsonarr" udp dport 45000 dnat to 172.18.0.10:6881 comment "qbt-dnat-sonarr"' "$NFT_LOG"
  ! grep -F 'CMD=compose ' "$DOCKER_LOG"
}

@test "legacy DNAT read or transaction failure does not publish success cache" {
  write_qbt_env legacy-dnat
  write_lease 45000
  printf '45000' > "$CURL_STATE"
  for failure in QBT_TEST_NFT_READ_FAIL QBT_TEST_NFT_APPLY_FAIL; do
    run env "$failure=1" QBITTORRENT_ENV_FILE="$ENV_FILE" QBT_COMMON_SCRIPT=./proton-qbittorrent-common.sh bash ./proton-qbittorrent-sync-safe.sh sonarr
    [ "$status" -ne 0 ]
    [ ! -e "$CACHE_FILE" ]
  done
}
