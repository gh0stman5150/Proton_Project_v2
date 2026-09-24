#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
  export PROBE_LOG="$TEST_TMPDIR/probe.log"
  export NC_COUNT="$TEST_TMPDIR/nc-count"
  export NAS_HOST=192.0.2.40 NAS_PORT=445

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >> "$PROBE_LOG"
[[ -z "${NO_ROUTE:-}" ]]
EOF

  # nc succeeds from the NC_SUCCEEDS_ON-th probe onward.
  cat > "$TMPBIN/nc" <<'EOF'
#!/usr/bin/env bash
printf 'nc %s\n' "$*" >> "$PROBE_LOG"
count=$(( $(cat "$NC_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$NC_COUNT"
(( count >= ${NC_SUCCEEDS_ON:-1000000} ))
EOF

  cat > "$TMPBIN/sleep" <<'EOF'
#!/usr/bin/env bash
exec /bin/sleep 0.1
EOF
  chmod +x "$TMPBIN/ip" "$TMPBIN/nc" "$TMPBIN/sleep"
}

@test "waits until the NAS has a route and accepts SMB connections" {
  run env NC_SUCCEEDS_ON=3 NAS_WAIT_SECONDS=30 bash ./nas-network-online.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAS SMB endpoint 192.0.2.40:445 is reachable"* ]]
  [ "$(cat "$NC_COUNT")" -eq 3 ]
  grep -Fx 'ip route get 192.0.2.40' "$PROBE_LOG"
  grep -Fx 'nc -z -w 2 192.0.2.40 445' "$PROBE_LOG"
}

@test "a missing route fails after the wait budget without probing SMB" {
  run env NO_ROUTE=1 NAS_WAIT_SECONDS=1 bash ./nas-network-online.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"was not reachable within 1 seconds"* ]]
  grep -Fx 'ip route get 192.0.2.40' "$PROBE_LOG"
  ! grep -q '^nc ' "$PROBE_LOG"
}

@test "an unreachable SMB port fails after the wait budget" {
  run env NAS_WAIT_SECONDS=1 bash ./nas-network-online.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"NAS SMB endpoint 192.0.2.40:445 was not reachable"* ]]
  [ "$(cat "$NC_COUNT")" -ge 1 ]
}

@test "invalid port or wait settings are rejected before probing" {
  for setting in NAS_PORT=0 NAS_PORT=65536 NAS_PORT=smb NAS_WAIT_SECONDS=0 NAS_WAIT_SECONDS=-5; do
    run env "$setting" bash ./nas-network-online.sh
    [ "$status" -eq 2 ]
  done
  [ ! -e "$PROBE_LOG" ]
}
