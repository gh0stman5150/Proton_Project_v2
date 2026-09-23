#!/usr/bin/env bats

export BATS_TEST_TIMEOUT=15

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export PROTON_HEALTHCHECK_ENV="$TEST_TMPDIR/proton-healthcheck.env"
  export QBITTORRENT_ENV_FILE="$TEST_TMPDIR/qb.env"
  export QBT_COMMON_SCRIPT="$TEST_TMPDIR/proton-qbittorrent-common.sh"

  mkdir -p "$TMPBIN" "$PROTON_INSTANCE_ROOT/sonarr"
  : > "$PROTON_COMMON_ENV"
  : > "$PROTON_HEALTHCHECK_ENV"

  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<EOF
QBITTORRENT_ENV_FILE=$QBITTORRENT_ENV_FILE
EOF

  cat > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env" <<'EOF'
QBITTORRENT_URL=http://qb.test:8080
EOF

  cat > "$QBITTORRENT_ENV_FILE" <<'EOF'
QBITTORRENT_URL=http://qb.test:8080
EOF

  cat > "$QBT_COMMON_SCRIPT" <<'EOF'
#!/usr/bin/env bash
qbt_webui_http_status() {
  echo 200
}

qbt_login() {
  if [[ -n "${QBT_TEST_LOGIN_ERROR:-}" ]]; then
    QBT_LOGIN_ERROR="$QBT_TEST_LOGIN_ERROR"
    return 1
  fi
  return 0
}
EOF
  chmod +x "$QBT_COMMON_SCRIPT"

  cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/api/v2/torrents/info?filter=active"*)
    printf '[{\"name\":\"active\"}]'
    ;;
  *"/api/v2/transfer/info"*)
    printf '{\"dl_info_speed\":1,\"ul_info_speed\":2}'
    ;;
esac
EOF
  chmod +x "$TMPBIN/curl"

  cat > "$TMPBIN/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMPBIN/flock"

  cat > "$TMPBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMPBIN/systemctl"

  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat -
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TEST_TMPDIR/qb-sync.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_TMPDIR/qb-sync.sh"

  cat > "$TEST_TMPDIR/port-forward-once-success.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_TMPDIR/port-forward-once-success.sh"

  cat > "$TMPBIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
  chmod +x "$TMPBIN/sleep"
}

write_health_lease() {
  printf 'fixture-generation\n' > "$TEST_TMPDIR/tunnel-generation"
  cat > "$TEST_TMPDIR/proton-port.state" <<EOF
CURRENT_PORT=45678
CURRENT_IP=10.2.0.2
LEASE_EXPIRES_AT=$(( $(date +%s) + 600 ))
LEASE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LEASE_GENERATION=fixture-generation
PORT_CHANGED_AT=$(( $(date +%s) - $1 ))
EOF
}

@test "recent forwarded-port changes suppress low-throughput recovery" {
  write_health_lease 0

  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    STATE_FILE="$TEST_TMPDIR/proton-port.state" \
    RECOVERY_LOCK_FILE="$TEST_TMPDIR/recovery.lock" \
    PORT_STABILITY_GRACE_SECONDS=300 \
    CHECK_INTERVAL=60 \
    MIN_COMBINED_SPEED_BPS=65536 \
    MAX_LOW_SPEED_CHECKS=1 \
    bash ./proton-healthcheck.sh sonarr

  [ "$status" -eq 42 ]
  [[ "$output" != *"Low throughput detected"* ]]
  [[ "$output" != *"Throughput stayed below threshold"* ]]
}

@test "stable forwarded-port state still allows low-throughput recovery" {
  write_health_lease 600

  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    STATE_FILE="$TEST_TMPDIR/proton-port.state" \
    RECOVERY_LOCK_FILE="$TEST_TMPDIR/recovery.lock" \
    QBITTORRENT_SYNC_SCRIPT="$TEST_TMPDIR/qb-sync.sh" \
    PORT_STABILITY_GRACE_SECONDS=300 \
    CHECK_INTERVAL=60 \
    MIN_COMBINED_SPEED_BPS=65536 \
    MAX_LOW_SPEED_CHECKS=1 \
    bash ./proton-healthcheck.sh sonarr

  [ "$status" -eq 42 ]
  [[ "$output" == *"Low throughput detected"* ]]
  [[ "$output" == *"refreshing qBittorrent port state"* ]]
}

@test "low throughput no longer exits immediately on first increment" {
  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    CHECK_INTERVAL=60 \
    MIN_COMBINED_SPEED_BPS=65536 \
    MAX_LOW_SPEED_CHECKS=3 \
    bash ./proton-healthcheck.sh sonarr

  [ "$status" -eq 42 ]
  [[ "$output" == *"Low throughput detected"* ]]
}

@test "failed NAT-PMP recovery reports the real non-zero exit code" {
  cat > "$TEST_TMPDIR/port-forward-once.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$TEST_TMPDIR/port-forward-once.sh"

  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    PORT_FORWARD_SCRIPT="$TEST_TMPDIR/port-forward-once.sh" \
    RECOVERY_LOCK_FILE="$TEST_TMPDIR/recovery.lock" \
    CHECK_INTERVAL=60 \
    MIN_COMBINED_SPEED_BPS=65536 \
    MAX_LOW_SPEED_CHECKS=1 \
    bash ./proton-healthcheck.sh sonarr

  [ "$status" -eq 42 ]
  [[ "$output" == *"Recovery action 'NAT-PMP refresh' failed with exit 7"* ]]
}

@test "successful NAT-PMP refresh resets the recovery ladder instead of escalating to full restart" {
  write_health_lease 600

  cat > "$TMPBIN/sleep" <<EOF
#!/usr/bin/env bash
count_file="$TEST_TMPDIR/sleep-count"
count=0
if [[ -f "\$count_file" ]]; then
  count="\$(cat "\$count_file")"
fi
count=\$((count + 1))
printf '%s' "\$count" > "\$count_file"
if [[ "\$count" -ge 2 ]]; then
  exit 42
fi
exit 0
EOF
  chmod +x "$TMPBIN/sleep"

  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    STATE_FILE="$TEST_TMPDIR/proton-port.state" \
    RECOVERY_LOCK_FILE="$TEST_TMPDIR/recovery.lock" \
    QBITTORRENT_SYNC_SCRIPT="$TEST_TMPDIR/qb-sync.sh" \
    PORT_FORWARD_SCRIPT="$TEST_TMPDIR/port-forward-once-success.sh" \
    CHECK_INTERVAL=60 \
    MIN_COMBINED_SPEED_BPS=65536 \
    MAX_LOW_SPEED_CHECKS=1 \
    LOW_SPEED_COUNT=0 \
    RECOVERY_STAGE=1 \
    bash ./proton-healthcheck.sh sonarr

  [ "$status" -eq 42 ]
  [[ "$output" == *"forcing a one-shot NAT-PMP refresh"* ]]
  [[ "$output" == *"Low throughput detected (0 B/s, 1/1, stage 1)"* ]]
  [[ "$output" == *"Low throughput detected (0 B/s, 1/1, stage 0)"* ]]
  [[ "$output" == *"refreshing qBittorrent port state"* ]]
  [[ "$output" != *"restarting Proton services"* ]]
}

@test "healthcheck logs the shared qB login diagnostic when the Web UI is unreachable" {
  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    QBT_TEST_LOGIN_ERROR="qBittorrent Web UI unreachable at http://qb.test:8080" \
    CHECK_INTERVAL=60 \
    bash ./proton-healthcheck.sh sonarr

  [ "$status" -eq 42 ]
  [[ "$output" == *"qBittorrent Web UI unreachable at http://qb.test:8080; retrying later"* ]]
}

@test "full recovery queues restart instead of waiting for its own service group" {
  export SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
  cat > "$TMPBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
[[ "$1" == --no-block ]] || exit 99
exit "${RESTART_RESULT:-0}"
EOF
  for result in 0 7; do
    run env STATE_FILE="$TEST_TMPDIR/missing.state" \
      RECOVERY_LOCK_FILE="$TEST_TMPDIR/recovery.lock" \
      SERVER_MANAGER_SCRIPT="$TEST_TMPDIR/missing-selector" \
      RECOVERY_STAGE=2 MAX_LOW_SPEED_CHECKS=1 MIN_COMBINED_SPEED_BPS=65536 \
      CHECK_INTERVAL=60 RESTART_RESULT="$result" bash ./proton-healthcheck.sh sonarr
    [ "$status" -eq 42 ]
    if [[ "$result" == 7 ]]; then
      [[ "$output" == *"Recovery action 'healthcheck recovery' failed with exit 7"* ]]
    fi
  done
  grep -Fx -- '--no-block restart proton-wg@sonarr.service proton-port-forward@sonarr.service' "$SYSTEMCTL_LOG"
}

write_counting_session_stubs() {
  export LOGIN_LOG="$TEST_TMPDIR/login.log" CURL_LOG="$TEST_TMPDIR/curl.log" TEST_TMPDIR
  export RECOVERY_LOCK_FILE="$TEST_TMPDIR/recovery.lock" MAX_LOW_SPEED_CHECKS=5
  cat >> "$QBT_COMMON_SCRIPT" <<'STUB'
qbt_login() {
  printf 'login\n' >> "$LOGIN_LOG"
  return 0
}
STUB
  cat > "$TMPBIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
if [[ "$*" == *"/api/v2/torrents/info"* && -n "${EXPIRE_FIRST_REQUEST:-}" && ! -f "$TEST_TMPDIR/expired" ]]; then
  touch "$TEST_TMPDIR/expired"
  exit 22
fi
case "$*" in
  *"/api/v2/torrents/info?filter=active"*) printf '[{"name":"active"}]' ;;
  *"/api/v2/transfer/info"*) printf '{"connection_status":"connected","dl_info_speed":1,"up_info_speed":2}' ;;
esac
STUB
  cat > "$TMPBIN/sleep" <<'STUB'
#!/usr/bin/env bash
count="$(( $(cat "$TEST_TMPDIR/ticks" 2>/dev/null || echo 0) + 1 ))"
printf '%s\n' "$count" > "$TEST_TMPDIR/ticks"
if (( count >= 3 )); then exit 42; fi
STUB
  chmod +x "$TMPBIN/curl" "$TMPBIN/sleep"
}

@test "healthcheck reuses one qBittorrent session across checks" {
  write_counting_session_stubs
  run env CHECK_INTERVAL=60 MIN_COMBINED_SPEED_BPS=1 bash ./proton-healthcheck.sh sonarr
  [ "$status" -eq 42 ]
  [ "$(wc -l < "$LOGIN_LOG")" -eq 1 ]
  [ "$(grep -c '/api/v2/transfer/info' "$CURL_LOG")" -eq 3 ]
}

@test "healthcheck logs in again once when the session is rejected" {
  write_counting_session_stubs
  run env CHECK_INTERVAL=60 MIN_COMBINED_SPEED_BPS=65536 EXPIRE_FIRST_REQUEST=1 \
    bash ./proton-healthcheck.sh sonarr
  [ "$status" -eq 42 ]
  [ "$(wc -l < "$LOGIN_LOG")" -eq 2 ]
  [[ "$output" == *"Low throughput detected (3 B/s, 1/5, stage 0)"* ]]
}

@test "active-transfer probe requests a single torrent" {
  write_counting_session_stubs
  run env CHECK_INTERVAL=60 MIN_COMBINED_SPEED_BPS=1 bash ./proton-healthcheck.sh sonarr
  [ "$status" -eq 42 ]
  grep -F '/api/v2/torrents/info?filter=active&limit=1' "$CURL_LOG"
}
