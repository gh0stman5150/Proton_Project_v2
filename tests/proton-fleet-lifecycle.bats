#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/common.env"
  export SYNC_SCRIPT="$TEST_TMPDIR/sync"
  export FLEET_LOG="$TEST_TMPDIR/fleet.log"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export HEALTH_TRIES=1 HEALTH_DELAY=0 PORT_TRIES=1 PORT_DELAY=0 START_TIMEOUT=5
  mkdir -p "$TEST_TMPDIR/bin"
  : > "$PROTON_COMMON_ENV"
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    mkdir -p "$PROTON_INSTANCE_ROOT/$instance" "$TEST_TMPDIR/state/$instance"
    printf 'STATE_DIR=%s/state/%s\nSTATE_FILE=%s/state/%s/proton-port.state\nWG_ADDRESS_SUBNET=4\n' "$TEST_TMPDIR" "$instance" "$TEST_TMPDIR" "$instance" > "$PROTON_INSTANCE_ROOT/$instance/proton.env"
    printf 'QBT_CONTAINER_NAME=qbittorrent-%s\n' "$instance" > "$PROTON_INSTANCE_ROOT/$instance/qbittorrent.env"
    printf 'generation-%s\n' "$instance" > "$TEST_TMPDIR/state/$instance/tunnel-generation"
    cat > "$TEST_TMPDIR/state/$instance/proton-port.state" <<EOF
CURRENT_PORT=45678
CURRENT_IP=10.4.0.2
LEASE_EXPIRES_AT=$(( $(date +%s) + 600 ))
LEASE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LEASE_GENERATION=generation-$instance
EOF
  done
  cat > "$SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
source "$QBITTORRENT_ENV_FILE"
printf '%s|%s|%s\n' "$1" "$QBT_CONTAINER_NAME" "$STATE_FILE" >> "$FLEET_LOG"
exit "${TEST_SYNC_FAILURE:-0}"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/systemctl"
  printf '#!/usr/bin/env bash\nprintf "healthy\\n"\n' > "$TEST_TMPDIR/bin/docker"
  chmod +x "$SYNC_SCRIPT" "$TEST_TMPDIR/bin/"*
}

@test "bootstrap loads independent configuration and lease paths for all five instances" {
  run bash -c '
    source ./proton-instance-common.sh
    source <(sed -n "/^recreate_instance()/,/^)/p" tools/recreate-qbittorrent-fleet.sh)
    for instance in lidarr prowlarr radarr sonarr whisparr; do
      recreate_instance "$instance" || exit 1
    done
  '
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$FLEET_LOG")" -eq 5 ]
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    grep -Fx "$instance|qbittorrent-$instance|$TEST_TMPDIR/state/$instance/proton-port.state" "$FLEET_LOG"
  done
}

@test "bootstrap propagates sync failure despite a healthy old container" {
  run env TEST_SYNC_FAILURE=17 bash -c '
    source ./proton-instance-common.sh
    source <(sed -n "/^recreate_instance()/,/^)/p" tools/recreate-qbittorrent-fleet.sh)
    recreate_instance lidarr || exit 1
    recreate_instance radarr
  '
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$FLEET_LOG")" -eq 1 ]
}

@test "bootstrap rejects expired leases before invoking sync" {
  sed -i 's/^LEASE_EXPIRES_AT=.*/LEASE_EXPIRES_AT=1/' "$TEST_TMPDIR/state/lidarr/proton-port.state"
  run bash -c '
    source ./proton-instance-common.sh
    source <(sed -n "/^recreate_instance()/,/^)/p" tools/recreate-qbittorrent-fleet.sh)
    recreate_instance lidarr || exit 1
  '
  [ "$status" -ne 0 ]
  [ ! -f "$FLEET_LOG" ]
}