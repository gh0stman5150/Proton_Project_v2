#!/usr/bin/env bats

load common-stubs

export BATS_TEST_TIMEOUT=15

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export STATE_DIR="$TEST_TMPDIR/state"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export PROTON_PORT_FORWARD_ENV="$TEST_TMPDIR/proton-port-forward.env"
  export STATE_FILE="$STATE_DIR/proton-port.state"
  export SERVER_SELECTION_FILE="$STATE_DIR/current-server.env"
  export RECOVERY_LOCK_FILE="$STATE_DIR/recovery.lock"
  export PF_CAPABLE_PROFILES_FILE="$TEST_TMPDIR/pf-capable.tsv"
  export PF_INCAPABLE_PROFILES_FILE="$TEST_TMPDIR/pf-incapable.tsv"
  export WG_POOL_DIR="$TEST_TMPDIR/pool"
  export SERVER_POOL_ENABLED=on
  export CHECK_INTERVAL=45
  export MAX_FAILURES=1
  export NATPMP_TIMEOUT_SECONDS=1
  export PATH="$TMPBIN:$PATH"
  export SERVER_MANAGER_LOG="$TEST_TMPDIR/server-manager.log"
  export WG_UP_SCRIPT="$TEST_TMPDIR/wg-up.sh"
  export SERVER_MANAGER_SCRIPT="$TEST_TMPDIR/server-manager.sh"

  mkdir -p "$TMPBIN" "$STATE_DIR" "$WG_POOL_DIR" "$PROTON_INSTANCE_ROOT/sonarr"
  : > "$PROTON_COMMON_ENV"
  : > "$PROTON_PORT_FORWARD_ENV"
  printf 'fixture-generation\n' > "$STATE_DIR/tunnel-generation"

  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<EOF
STATE_DIR=$STATE_DIR
STATE_FILE=$STATE_FILE
SERVER_SELECTION_FILE=$SERVER_SELECTION_FILE
RECOVERY_LOCK_FILE=$RECOVERY_LOCK_FILE
WG_POOL_DIR=$WG_POOL_DIR
WG_ADDRESS_SUBNET=2
EOF

  cat > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env" <<'EOF'
QBITTORRENT_URL=http://127.0.0.1:8083
QBITTORRENT_USER=test
QBITTORRENT_PASS=test
EOF

  cat > "$SERVER_SELECTION_FILE" <<EOF
SELECTED_WG_PROFILE=wg-good
SELECTED_CONFIG=$TEST_TMPDIR/wg-good.conf
EOF

  stub_systemd_cat

  stub_command flock 'exit 0'

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-4" && "$2" == "addr" && "$3" == "show" ]]; then
  printf '3: %s\n    inet 10.2.0.2/32 scope global %s\n' "$4" "$4"
  exit 0
fi
exit 1
EOF
  chmod +x "$TMPBIN/ip"

  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${SELECTION_REWRITE_FILE:-}" && -n "${SELECTION_REWRITE_PROFILE:-}" && -n "${SELECTION_REWRITE_DONE_FILE:-}" && ! -f "$SELECTION_REWRITE_DONE_FILE" ]]; then
  cat > "$SELECTION_REWRITE_FILE" <<EOF2
SELECTED_WG_PROFILE=$SELECTION_REWRITE_PROFILE
SELECTED_CONFIG=$SELECTION_REWRITE_PROFILE.conf
EOF2
  touch "$SELECTION_REWRITE_DONE_FILE"
fi
exit 1
EOF
  chmod +x "$TMPBIN/natpmpc"

  cat > "$TMPBIN/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"
EOF
  chmod +x "$TMPBIN/timeout"

  cat > "$SERVER_MANAGER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SERVER_MANAGER_LOG"
EOF
  chmod +x "$SERVER_MANAGER_SCRIPT"

  cat > "$WG_UP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
  chmod +x "$WG_UP_SCRIPT"

  export QBITTORRENT_SYNC_SCRIPT="$TEST_TMPDIR/qb-sync.sh"
  cat > "$QBITTORRENT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$QBITTORRENT_SYNC_SCRIPT"
}

@test "proven port-forward profiles are retried in place without reselect after transient failures" {
  printf 'wg-good\t1\t45678\n' > "$PF_CAPABLE_PROFILES_FILE"

  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
count_file="${NATPMP_COUNT_FILE:?}"
n=0
[[ -f "$count_file" ]] && n="$(cat "$count_file")"
n=$((n + 1))
echo "$n" > "$count_file"
# Fail the first NAT-PMP window (udp+tcp), then forward successfully.
if (( n <= 1 )); then
  exit 1
fi
if [[ "${4:-}" == "udp" ]]; then
  printf 'Mapped public port 45678 protocol udp lifetime 60\n'
  exit 0
fi
printf 'Mapped public port 45678 protocol tcp lifetime 60\n'
exit 0
EOF
  chmod +x "$TMPBIN/natpmpc"

  cat > "$QBITTORRENT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
kill -TERM "$PPID"
exit 0
EOF
  chmod +x "$QBITTORRENT_SYNC_SCRIPT"

  run env \
    STATE_DIR="$STATE_DIR" \
    STATE_FILE="$STATE_FILE" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    RECOVERY_LOCK_FILE="$RECOVERY_LOCK_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    CHECK_INTERVAL=0 \
    MAX_FAILURES="$MAX_FAILURES" \
    NATPMP_TIMEOUT_SECONDS="$NATPMP_TIMEOUT_SECONDS" \
    WG_UP_SCRIPT="$WG_UP_SCRIPT" \
    QBITTORRENT_SYNC_SCRIPT="$QBITTORRENT_SYNC_SCRIPT" \
    SERVER_MANAGER_SCRIPT="$SERVER_MANAGER_SCRIPT" \
    SERVER_MANAGER_LOG="$SERVER_MANAGER_LOG" \
    NATPMP_COUNT_FILE="$TEST_TMPDIR/natpmp.count" \
    bash ./proton-port-forward-safe.sh sonarr

  [ "$status" -eq 143 ]
  grep -F 'mark-capable wg-good 45678' "$SERVER_MANAGER_LOG"
  run grep -F 'mark-bad wg-good' "$SERVER_MANAGER_LOG"
  [ "$status" -ne 0 ]
  run grep -F 'mark-incapable-attempt wg-good' "$SERVER_MANAGER_LOG"
  [ "$status" -ne 0 ]
}

@test "unproven port-forward profiles are marked incapable after repeated failures" {
  run env \
    STATE_DIR="$STATE_DIR" \
    STATE_FILE="$STATE_FILE" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    RECOVERY_LOCK_FILE="$RECOVERY_LOCK_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    CHECK_INTERVAL="$CHECK_INTERVAL" \
    MAX_FAILURES="$MAX_FAILURES" \
    NATPMP_TIMEOUT_SECONDS="$NATPMP_TIMEOUT_SECONDS" \
    WG_UP_SCRIPT="$WG_UP_SCRIPT" \
    SERVER_MANAGER_SCRIPT="$SERVER_MANAGER_SCRIPT" \
    SERVER_MANAGER_LOG="$SERVER_MANAGER_LOG" \
    bash ./proton-port-forward-safe.sh sonarr

  [ "$status" -eq 42 ]
  grep -F 'mark-incapable-attempt wg-good natpmp-timeout' "$SERVER_MANAGER_LOG"
  grep -F 'mark-bad wg-good port-forward-failures' "$SERVER_MANAGER_LOG"
}

@test "reconnect cools down the profile that failed even if selection state changes mid-loop" {
  run env \
    STATE_DIR="$STATE_DIR" \
    STATE_FILE="$STATE_FILE" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    RECOVERY_LOCK_FILE="$RECOVERY_LOCK_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    CHECK_INTERVAL="$CHECK_INTERVAL" \
    MAX_FAILURES="$MAX_FAILURES" \
    NATPMP_TIMEOUT_SECONDS="$NATPMP_TIMEOUT_SECONDS" \
    WG_UP_SCRIPT="$WG_UP_SCRIPT" \
    SERVER_MANAGER_SCRIPT="$SERVER_MANAGER_SCRIPT" \
    SERVER_MANAGER_LOG="$SERVER_MANAGER_LOG" \
    SELECTION_REWRITE_FILE="$SERVER_SELECTION_FILE" \
    SELECTION_REWRITE_PROFILE=wg-stale \
    SELECTION_REWRITE_DONE_FILE="$TEST_TMPDIR/selection-rewrite.done" \
    bash ./proton-port-forward-safe.sh sonarr

  [ "$status" -eq 42 ]
  grep -F 'mark-bad wg-good port-forward-failures' "$SERVER_MANAGER_LOG"
  run grep -F 'mark-bad wg-stale port-forward-failures' "$SERVER_MANAGER_LOG"
  [ "$status" -ne 0 ]
}

@test "post-reconnect port-forward success is attributed to the newly selected profile" {
  cat > "$SERVER_SELECTION_FILE" <<EOF
SELECTED_WG_PROFILE=wg-old
SELECTED_CONFIG=$TEST_TMPDIR/wg-old.conf
EOF

  printf 'wg-old\t1\t45678\n' > "$PF_CAPABLE_PROFILES_FILE"

  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
if [[ -f "${RECONNECTED_MARKER:-}" ]]; then
  if [[ "${4:-}" == "udp" ]]; then
    printf 'Mapped public port 45678 protocol udp lifetime 60\n'
    exit 0
  fi
  if [[ "${4:-}" == "tcp" ]]; then
    printf 'Mapped public port 45678 protocol tcp lifetime 60\n'
    exit 0
  fi
fi

exit 1
EOF
  chmod +x "$TMPBIN/natpmpc"

  cat > "$WG_UP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
cat > "$SERVER_SELECTION_FILE" <<EOF2
SELECTED_WG_PROFILE=wg-new
SELECTED_CONFIG=$TEST_TMPDIR/wg-new.conf
EOF2
touch "$RECONNECTED_MARKER"
exit 0
EOF
  chmod +x "$WG_UP_SCRIPT"

  cat > "$QBITTORRENT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
kill -TERM "$PPID"
exit 0
EOF
  chmod +x "$QBITTORRENT_SYNC_SCRIPT"

  run env \
    STATE_DIR="$STATE_DIR" \
    STATE_FILE="$STATE_FILE" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    RECOVERY_LOCK_FILE="$RECOVERY_LOCK_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    CHECK_INTERVAL=0 \
    MAX_FAILURES="$MAX_FAILURES" \
    NATPMP_TIMEOUT_SECONDS="$NATPMP_TIMEOUT_SECONDS" \
    WG_UP_SCRIPT="$WG_UP_SCRIPT" \
    QBITTORRENT_SYNC_SCRIPT="$QBITTORRENT_SYNC_SCRIPT" \
    SERVER_MANAGER_SCRIPT="$SERVER_MANAGER_SCRIPT" \
    SERVER_MANAGER_LOG="$SERVER_MANAGER_LOG" \
    RECONNECTED_MARKER="$TEST_TMPDIR/reconnected" \
    TEST_TMPDIR="$TEST_TMPDIR" \
    bash ./proton-port-forward-safe.sh sonarr

  [ "$status" -eq 143 ]
  grep -F 'mark-bad wg-old port-forward-failures' "$SERVER_MANAGER_LOG"
  grep -F 'mark-capable wg-new 45678' "$SERVER_MANAGER_LOG"
  run grep -F 'mark-capable wg-old 45678' "$SERVER_MANAGER_LOG"
  [ "$status" -ne 0 ]
}

@test "lease duration must leave time for both bounded renewal requests" {
  run env PORT_LEASE_SECONDS=10 bash ./proton-port-forward-safe.sh sonarr once
  [ "$status" -eq 1 ]
  [[ "$output" == *"renewal budget"* ]]
  [ ! -f "$STATE_FILE" ]
}

@test "loop schedules the next attempt within the default lease renewal budget" {
  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
printf 'Mapped public port 45678 protocol %s lifetime 60\n' "$4"
EOF
  cat > "$TMPBIN/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$STATE_DIR/delay"
exit 42
EOF
  chmod +x "$TMPBIN/sleep"
  run env NATPMP_TIMEOUT_SECONDS=15 bash ./proton-port-forward-safe.sh sonarr loop
  [ "$status" -eq 42 ]
  [ "$(cat "$STATE_DIR/delay")" -le 16 ]
  [ -f "$STATE_FILE" ]
}

@test "one-shot publication requires matching protocols and a usable granted lifetime" {
  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$4" >> "$STATE_DIR/requests"
if [[ "$4" == udp && "${REPLY_CASE:-}" == udp-failure ]]; then exit 1; fi
port=45678
lifetime=60
if [[ "$4" == tcp ]]; then
  case "${REPLY_CASE:-}" in
    mismatch) port=45679 ;;
    expired) lifetime=1 ;;
    malformed) lifetime=invalid ;;
    generation) printf 'new-generation\n' > "$STATE_DIR/tunnel-generation" ;;
    shorter) lifetime=30 ;;
  esac
fi
printf 'Mapped public port %s protocol %s to local port 1 lifetime %s\n' "$port" "$4" "$lifetime"
EOF
  cat > "$QBITTORRENT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
touch "$STATE_DIR/synced"
EOF
  for reply in udp-failure mismatch expired malformed generation; do
    printf 'previous-state\n' > "$STATE_FILE"
    : > "$STATE_DIR/requests"
    run env REPLY_CASE="$reply" bash ./proton-port-forward-safe.sh sonarr once
    [ "$status" -eq 1 ]
    [ "$(cat "$STATE_FILE")" = previous-state ]
    [ ! -f "$STATE_DIR/synced" ]
    if [[ "$reply" == udp-failure ]]; then
      [ "$(cat "$STATE_DIR/requests")" = udp ]
    fi
  done
  before="$(date +%s)"
  run env REPLY_CASE=shorter bash ./proton-port-forward-safe.sh sonarr once
  [ "$status" -eq 0 ]
  expiry="$(awk -F= '$1 == "LEASE_EXPIRES_AT" {print $2}' "$STATE_FILE")"
  [ "$expiry" -ge "$((before + 30))" ]
  [ "$expiry" -le "$(( $(date +%s) + 30 ))" ]
  [ "$(stat -c %a "$STATE_FILE")" = 600 ]
  [ -f "$STATE_DIR/synced" ]
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -eq 0 ]
  [ "$output" = 45678 ]
}

@test "one-shot renewal loads the selected server once" {
  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
printf 'Mapped public port 45678 protocol %s lifetime 60\n' "$4"
EOF
  cat > "$SERVER_SELECTION_FILE" <<EOF
printf 'loaded\n' >> "$TEST_TMPDIR/selection-loads"
SELECTED_WG_PROFILE=wg-good
EOF

  run bash ./proton-port-forward-safe.sh sonarr once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_TMPDIR/selection-loads")" -eq 1 ]
}

@test "repeated one-shot renewal preserves generation port and change timestamp" {
  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
printf 'Mapped public port 45678 protocol %s lifetime 60\n' "$4"
EOF
  run bash ./proton-port-forward-safe.sh sonarr once
  [ "$status" -eq 0 ]
  sed -i 's/^PORT_CHANGED_AT=.*/PORT_CHANGED_AT=100/' "$STATE_FILE"

  run bash ./proton-port-forward-safe.sh sonarr once
  [ "$status" -eq 0 ]
  grep -Fx 'CURRENT_PORT=45678' "$STATE_FILE"
  grep -Fx 'LEASE_GENERATION=fixture-generation' "$STATE_FILE"
  grep -Fx 'PORT_CHANGED_AT=100' "$STATE_FILE"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -eq 0 ]
  [ "$output" = 45678 ]
}

@test "a busy lifecycle or NAT-PMP writer lock prevents publication" {
  rm "$TMPBIN/flock"
  for lock in lifecycle natpmp; do
    exec {lock_fd}>"$STATE_DIR/$lock.lock"
    flock "$lock_fd"
    run env NATPMP_LOCK_WAIT_SECONDS=0 bash ./proton-port-forward-safe.sh sonarr once
    [ "$status" -eq 1 ]
    [ ! -f "$STATE_FILE" ]
    flock -u "$lock_fd"
    exec {lock_fd}>&-
  done
}

@test "renewals continue during slow sync and shutdown terminates the owned sync group" {
  rm "$TMPBIN/timeout" "$TMPBIN/flock"
  mkfifo "$STATE_DIR/ready" "$STATE_DIR/blocked"
  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$4" >> "$STATE_DIR/requests"
printf 'Mapped public port 45678 protocol %s lifetime 60\n' "$4"
EOF
  cat > "$QBITTORRENT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf 'sync\n' >> "$STATE_DIR/sync-count"
trap 'touch "$STATE_DIR/terminated"; exit 0' TERM
exec 7<>"$STATE_DIR/blocked"
printf 'ready\n' > "$STATE_DIR/ready"
read -r -t 10 -u 7 ignored
EOF
  cat > "$TMPBIN/sleep" <<'EOF'
#!/usr/bin/env bash
if [[ ! -f "$STATE_DIR/started" ]]; then
  read -r ready < "$STATE_DIR/ready"
  touch "$STATE_DIR/started"
fi
count="$(wc -l < "$STATE_DIR/requests")"
if ((count >= 6)); then exit 42; fi
EOF
  chmod +x "$TMPBIN/sleep"
  run bash ./proton-port-forward-safe.sh sonarr loop
  [ "$status" -eq 42 ]
  [ "$(wc -l < "$STATE_DIR/sync-count")" -eq 1 ]
  [ -f "$STATE_DIR/terminated" ]
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -eq 0 ]
}

write_renewal_loop_stubs() {
  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
port=45678
if [[ -n "${PORT_CHANGE_AFTER:-}" && -f "$STATE_DIR/iterations" ]] && (( $(cat "$STATE_DIR/iterations") >= PORT_CHANGE_AFTER )); then
  port=45679
fi
printf 'Mapped public port %s protocol %s lifetime 60\n' "$port" "$4"
EOF
  cat > "$QBITTORRENT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
count="$(( $(wc -l < "$STATE_DIR/sync-count" 2>/dev/null || echo 0) + 1 ))"
printf 'sync\n' >> "$STATE_DIR/sync-count"
touch "$STATE_DIR/sync-done"
if (( count <= ${SYNC_FAILURES:-0} )); then exit 1; fi
exit 0
EOF
  # Each renewal ends in sleep: wait for any started sync to finish, then stop
  # the loop after ITERATIONS renewals.
  cat > "$TMPBIN/sleep" <<'EOF'
#!/usr/bin/env bash
n="$(( $(cat "$STATE_DIR/iterations" 2>/dev/null || echo 0) + 1 ))"
printf '%s\n' "$n" > "$STATE_DIR/iterations"
if [[ -f "$STATE_DIR/sync-count" ]]; then
  for _ in $(seq 100); do
    [[ -f "$STATE_DIR/sync-done" ]] && break
    command -p sleep 0.05
  done
fi
if (( n >= ITERATIONS )); then exit 42; fi
EOF
  chmod +x "$TMPBIN/sleep" "$TMPBIN/natpmpc" "$QBITTORRENT_SYNC_SCRIPT"
}

@test "unchanged renewals sync qBittorrent and mark capability once" {
  write_renewal_loop_stubs
  run env ITERATIONS=5 bash ./proton-port-forward-safe.sh sonarr loop
  [ "$status" -eq 42 ]
  [ "$(wc -l < "$STATE_DIR/sync-count")" -eq 1 ]
  [ "$(grep -c '^mark-capable wg-good 45678$' "$SERVER_MANAGER_LOG")" -eq 1 ]
}

@test "a changed port syncs qBittorrent and marks the new port capable" {
  write_renewal_loop_stubs
  run env ITERATIONS=5 PORT_CHANGE_AFTER=2 bash ./proton-port-forward-safe.sh sonarr loop
  [ "$status" -eq 42 ]
  [ "$(wc -l < "$STATE_DIR/sync-count")" -eq 2 ]
  grep -Fx 'mark-capable wg-good 45678' "$SERVER_MANAGER_LOG"
  grep -Fx 'mark-capable wg-good 45679' "$SERVER_MANAGER_LOG"
}

@test "a failed sync is retried on a later renewal with the same port" {
  write_renewal_loop_stubs
  run env ITERATIONS=5 SYNC_FAILURES=1 bash ./proton-port-forward-safe.sh sonarr loop
  [ "$status" -eq 42 ]
  [ "$(wc -l < "$STATE_DIR/sync-count")" -eq 2 ]
}

@test "unchanged renewals still re-run the sync after the drift interval" {
  write_renewal_loop_stubs
  run env ITERATIONS=6 QBT_SYNC_DRIFT_INTERVAL_SECONDS=0 bash ./proton-port-forward-safe.sh sonarr loop
  [ "$status" -eq 42 ]
  [ "$(wc -l < "$STATE_DIR/sync-count")" -ge 2 ]
}

@test "a dropped mark-capable call is retried on the next renewal" {
  write_renewal_loop_stubs
  cat > "$SERVER_MANAGER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SERVER_MANAGER_LOG"
[[ "$(grep -c mark-capable "$SERVER_MANAGER_LOG")" -gt 1 ]]
EOF
  run env ITERATIONS=5 bash ./proton-port-forward-safe.sh sonarr loop
  [ "$status" -eq 42 ]
  [ "$(grep -c '^mark-capable wg-good 45678$' "$SERVER_MANAGER_LOG")" -eq 2 ]
}

@test "allocator queues startup and requires a fresh lease from an active producer" {
  cat > "$TMPBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE_DIR/systemctl.log"
case "$1" in
  --no-block) exit "${START_RESULT:-0}" ;;
  is-active) exit "${ACTIVE_RESULT:-0}" ;;
  *) exit 0 ;;
esac
EOF
  stub_command journalctl 'exit 0'
  cat > "$QBITTORRENT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
touch "$STATE_DIR/synced"
EOF
  chmod +x "$TMPBIN/systemctl" "$TMPBIN/journalctl"
  export WAIT_TRIES=2 WAIT_INTERVAL_SECONDS=0
  run bash ./proton-qbt-allocate-and-sync.sh sonarr
  [ "$status" -eq 1 ]
  [ ! -f "$STATE_DIR/synced" ]
  cat > "$STATE_FILE" <<EOF
CURRENT_PORT=45678
CURRENT_IP=10.2.0.2
LEASE_EXPIRES_AT=1
LEASE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LEASE_GENERATION=fixture-generation
EOF
  run bash ./proton-qbt-allocate-and-sync.sh sonarr
  [ "$status" -eq 1 ]
  [ ! -f "$STATE_DIR/synced" ]
  sed -i "s/^LEASE_EXPIRES_AT=.*/LEASE_EXPIRES_AT=$(( $(date +%s) + 60 ))/" "$STATE_FILE"
  run env ACTIVE_RESULT=1 bash ./proton-qbt-allocate-and-sync.sh sonarr
  [ "$status" -eq 1 ]
  [ ! -f "$STATE_DIR/synced" ]
  run env START_RESULT=1 bash ./proton-qbt-allocate-and-sync.sh sonarr
  [ "$status" -eq 1 ]
  [[ "$output" == *"not canceled"* ]]
  [ ! -f "$STATE_DIR/synced" ]
  run bash ./proton-qbt-allocate-and-sync.sh sonarr
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/synced" ]
  grep -Fx -- '--no-block start proton-port-forward@sonarr.service' "$STATE_DIR/systemctl.log"
}

@test "allocator enforces its overall deadline even when the systemctl client stalls" {
  rm "$TMPBIN/timeout"
  mkfifo "$STATE_DIR/blocked"
  cat > "$TMPBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exec 7<>"$STATE_DIR/blocked"
read -r -t 10 -u 7 ignored
EOF
  chmod +x "$TMPBIN/systemctl"
  before="$SECONDS"
  run env ALLOCATION_TIMEOUT_SECONDS=1 bash ./proton-qbt-allocate-and-sync.sh sonarr
  [ "$status" -eq 1 ]
  [[ "$output" == *"not canceled"* ]]
  [ "$((SECONDS - before))" -lt 5 ]
}

@test "elapsed replies and failed atomic rename never publish partial lease state" {
  export REAL_DATE
  REAL_DATE="$(command -v date)"
  cat > "$TMPBIN/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == +%s ]]; then cat "$STATE_DIR/clock"; else exec "$REAL_DATE" "$@"; fi
EOF
  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
if [[ "$4" == tcp && "${EXPIRE_DURING_REQUEST:-0}" == 1 ]]; then
  printf '170\n' > "$STATE_DIR/clock"
fi
printf 'Mapped public port 45678 protocol %s lifetime 60\n' "$4"
EOF
  cat > "$QBITTORRENT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
touch "$STATE_DIR/synced"
EOF
  chmod +x "$TMPBIN/date"
  printf '100\n' > "$STATE_DIR/clock"
  printf 'previous-state\n' > "$STATE_FILE"
  run env EXPIRE_DURING_REQUEST=1 bash ./proton-port-forward-safe.sh sonarr once
  [ "$status" -eq 1 ]
  [ "$(cat "$STATE_FILE")" = previous-state ]
  [ ! -f "$STATE_DIR/synced" ]
  cat > "$TMPBIN/mv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TMPBIN/mv"
  printf '100\n' > "$STATE_DIR/clock"
  run bash ./proton-port-forward-safe.sh sonarr once
  [ "$status" -eq 1 ]
  [ "$(cat "$STATE_FILE")" = previous-state ]
  [ ! -f "$STATE_DIR/synced" ]
  run compgen -G "$STATE_FILE.*"
  [ "$status" -eq 1 ]
}
