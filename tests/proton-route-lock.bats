#!/usr/bin/env bats

export BATS_TEST_TIMEOUT=15

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  export ROUTE_LOCK_FILE="$TEST_TMPDIR/policy-routing.lock"
  export ROUTE_LOCK_READY="$TEST_TMPDIR/holder.ready"
}

@test "the global policy-route lock excludes concurrent route mutation" {
  (
    export PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE"
    export PROTON_ROUTE_LOCK_WAIT_SECONDS=5
    source ./proton-instance-common.sh
    proton_route_lock_acquire
    : > "$ROUTE_LOCK_READY"
    sleep 1
    proton_route_lock_release
  ) &
  holder_pid=$!

  for _ in {1..50}; do
    [[ -f "$ROUTE_LOCK_READY" ]] && break
    sleep 0.02
  done
  [[ -f "$ROUTE_LOCK_READY" ]]

  run env \
    PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE" \
    PROTON_ROUTE_LOCK_WAIT_SECONDS=0 \
    bash -c 'source ./proton-instance-common.sh; proton_route_lock_acquire'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Timed out"* ]]

  wait "$holder_pid"

  run env \
    PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE" \
    PROTON_ROUTE_LOCK_WAIT_SECONDS=1 \
    bash -c 'source ./proton-instance-common.sh; proton_route_lock_acquire; proton_route_lock_release'
  [ "$status" -eq 0 ]
}

@test "five concurrent instances canonicalize one shared rule without EEXIST" {
  fake_bin="$TEST_TMPDIR/bin"
  rule_state="$TEST_TMPDIR/rule.state"
  ip_errors="$TEST_TMPDIR/ip.errors"
  mkdir -p "$fake_bin"
  : > "$ip_errors"

  cat > "$fake_bin/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "rule" && "$2" == "del" ]]; then
  if [[ -f "$IP_RULE_STATE" ]]; then
    rm -f "$IP_RULE_STATE"
    sleep 0.03
    exit 0
  fi
  sleep 0.03
  printf 'RTNETLINK answers: No such file or directory\n' >&2
  exit 2
fi
if [[ "$1" == "rule" && "$2" == "add" ]]; then
  if [[ -f "$IP_RULE_STATE" ]]; then
    printf 'RTNETLINK answers: File exists\n' >> "$IP_ERROR_LOG"
    exit 2
  fi
  printf '%s\n' "$*" > "$IP_RULE_STATE"
  exit 0
fi
printf 'unexpected ip invocation: %s\n' "$*" >> "$IP_ERROR_LOG"
exit 2
EOF
  chmod +x "$fake_bin/ip"

  pids=()
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    (
      export INSTANCE="$instance"
      export PATH="$fake_bin:$PATH"
      export IP_RULE_STATE="$rule_state"
      export IP_ERROR_LOG="$ip_errors"
      export PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE"
      export PROTON_ROUTE_LOCK_WAIT_SECONDS=5
      source ./proton-instance-common.sh
      proton_route_lock_acquire
      proton_replace_ip_rule 4 from 192.168.96.0/20 to 192.168.96.0/20 lookup main priority 108
      proton_route_lock_release
    ) &
    pids+=("$!")
  done

  combined_status=0
  for pid in "${pids[@]}"; do
    wait "$pid" || combined_status=1
  done

  [ "$combined_status" -eq 0 ]
  [ "$(cat "$rule_state")" = "rule add from 192.168.96.0/20 to 192.168.96.0/20 lookup main priority 108" ]
  [ ! -s "$ip_errors" ]
}

@test "every route-mutating lifecycle path uses the shared lock" {
  grep -Fq 'proton_route_lock_acquire' proton-wg-up-safe.sh
  grep -Fq 'proton_route_lock_release' proton-wg-up-safe.sh
  grep -Fq 'proton_route_lock_acquire' proton-wg-down-safe.sh
  grep -Fq 'proton_route_lock_release' proton-wg-down-safe.sh
  grep -Fq 'reapply_routes_serialized' proton-docker-network-watcher.sh
  grep -Fq 'proton_replace_ip_rule 4' proton-wg-up-safe.sh
  grep -Fq 'proton_replace_ip_rule 4' proton-docker-network-watcher.sh
}

@test "rule deletion distinguishes absence from permission or unexplained failure" {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${DELETE_ERROR:-}" >&2
exit 2
EOF
  chmod +x "$TEST_TMPDIR/bin/ip"
  run env PATH="$TEST_TMPDIR/bin:$PATH" DELETE_ERROR='RTNETLINK answers: No such file or directory' bash -c 'source ./proton-instance-common.sh; proton_delete_ip_rule_all 4 from 192.168.96.17/32 lookup 51804 priority 114'
  [ "$status" -eq 0 ]
  for message in 'RTNETLINK answers: Operation not permitted' ''; do
    run env PATH="$TEST_TMPDIR/bin:$PATH" DELETE_ERROR="$message" bash -c 'source ./proton-instance-common.sh; proton_delete_ip_rule_all 4 from 192.168.96.17/32 lookup 51804 priority 114'
    [ "$status" -ne 0 ]
  done
}

@test "a terminated route-lock holder releases ownership without unlinking the lock" {
  mkfifo "$TEST_TMPDIR/ready" "$TEST_TMPDIR/blocked"
  env PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE" TEST_ROOT="$TEST_TMPDIR" bash -c '
    source ./proton-instance-common.sh
    proton_route_lock_acquire || exit
    exec 7<>"$TEST_ROOT/blocked"
    printf "ready\n" > "$TEST_ROOT/ready"
    read -r -t 10 -u 7 ignored
  ' &
  holder_pid=$!
  read -r ready < "$TEST_TMPDIR/ready"
  [ "$ready" = ready ]
  inode="$(stat -c %i "$ROUTE_LOCK_FILE")"
  kill -KILL "$holder_pid"
  wait "$holder_pid" || true
  run env PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE" PROTON_ROUTE_LOCK_WAIT_SECONDS=0 bash -c 'source ./proton-instance-common.sh; proton_route_lock_acquire'
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$ROUTE_LOCK_FILE")" = "$inode" ]
}

@test "a killed firewall-lock holder permits reuse of the same lock inode" {
  export KILLSWITCH_LOCK_FILE="$TEST_TMPDIR/killswitch.lock"
  mkfifo "$TEST_TMPDIR/firewall-ready" "$TEST_TMPDIR/firewall-blocked"
  env TEST_ROOT="$TEST_TMPDIR" bash -c '
    source ./proton-instance-common.sh
    hold_firewall() {
      printf "%s\n" "$BASHPID" > "$TEST_ROOT/firewall-ready"
      exec 7<>"$TEST_ROOT/firewall-blocked"
      read -r -t 10 -u 7 ignored
    }
    proton_with_firewall_lock hold_firewall
  ' &
  parent_pid=$!
  read -r holder_pid < "$TEST_TMPDIR/firewall-ready"
  inode="$(stat -c %i "$KILLSWITCH_LOCK_FILE")"
  kill -KILL "$holder_pid"
  wait "$parent_pid" || true

  run env PROTON_FIREWALL_LOCK_WAIT_SECONDS=0 bash -c 'source ./proton-instance-common.sh; proton_with_firewall_lock true'
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$KILLSWITCH_LOCK_FILE")" = "$inode" ]
}

write_stateful_rule_stub() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/ip" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RULE_LOG"
if [[ "${1:-}" == -6 ]]; then shift; fi
if [[ "$1 $2" == "rule show" ]]; then
  [[ "${SHOW_FAIL:-0}" == 1 ]] && exit 1
  awk -v table="$4" '$NF == table' "$RULES"
  exit 0
fi
if [[ "$1 $2" == "rule del" && "$3" == lookup && "$5" == priority ]]; then
  match="$(awk -v table="$4" -v priority="$6" '$NF == table && $1 == priority ":" { print NR; exit }' "$RULES")"
  if [[ -z "$match" ]]; then
    printf 'RTNETLINK answers: No such file or directory' >&2
    exit 2
  fi
  sed -i "${match}d" "$RULES"
  exit 0
fi
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/ip"
}

@test "table sweep removes rules at unowned priorities for any source and keeps owned and foreign-table rules" {
  write_stateful_rule_stub
  export RULES="$TEST_TMPDIR/rules" RULE_LOG="$TEST_TMPDIR/rule.log"
  printf '%s\n' \
    $'100:\tfrom all fwmark 0xca6c lookup 51806' \
    $'110:\tfrom 192.168.96.8 lookup 51806' \
    $'110:\tfrom 192.168.96.0/20 lookup 51806' \
    $'115:\tfrom 192.168.96.8 lookup 51805' \
    $'116:\tfrom 192.168.96.7 lookup 51806' \
    $'117:\tfrom 192.168.111.250 lookup 51806' \
    $'130:\tfrom 192.168.96.0/20 lookup 51806' > "$RULES"
  run env PATH="$TEST_TMPDIR/bin:$PATH" bash -c 'source ./proton-instance-common.sh; proton_delete_unowned_table_rules 4 51806 116 130'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' $'115:\tfrom 192.168.96.8 lookup 51805' $'116:\tfrom 192.168.96.7 lookup 51806' $'130:\tfrom 192.168.96.0/20 lookup 51806')" = "$(cat "$RULES")" ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "$output" == *$'117:\tfrom 192.168.111.250 lookup 51806'* ]]
  grep -Fx 'rule show table 51806' "$RULE_LOG"
}

@test "table sweep fails closed on a failed listing or missing owned priorities" {
  write_stateful_rule_stub
  export RULES="$TEST_TMPDIR/rules" RULE_LOG="$TEST_TMPDIR/rule.log"
  printf '110:\tfrom 192.168.96.8 lookup 51806\n' > "$RULES"
  run env PATH="$TEST_TMPDIR/bin:$PATH" SHOW_FAIL=1 bash -c 'source ./proton-instance-common.sh; proton_delete_unowned_table_rules 4 51806 116 130'
  [ "$status" -ne 0 ]
  for args in '4 51806' '4 main 116' '5 51806 116'; do
    run env PATH="$TEST_TMPDIR/bin:$PATH" bash -c "source ./proton-instance-common.sh; proton_delete_unowned_table_rules $args"
    [ "$status" -ne 0 ]
  done
  [ "$(cat "$RULES")" = $'110:\tfrom 192.168.96.8 lookup 51806' ]
}
