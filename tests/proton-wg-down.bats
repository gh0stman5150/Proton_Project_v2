#!/usr/bin/env bats

load common-stubs

export BATS_TEST_TIMEOUT=15

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export STATE_DIR="$TEST_TMPDIR/state"
  export WG_RUNTIME_DIR="$TEST_TMPDIR/runtime"
  export IP_LOG="$TEST_TMPDIR/ip.log"
  export WG_LOG="$TEST_TMPDIR/wg.log"
  export PROTON_ROUTE_LOCK_FILE="$TEST_TMPDIR/policy-routing.lock"
  export KILLSWITCH_LOCK_FILE="$TEST_TMPDIR/killswitch.lock"
  mkdir -p "$TMPBIN" "$STATE_DIR" "$WG_RUNTIME_DIR" "$PROTON_INSTANCE_ROOT/sonarr"
  : > "$IP_LOG"

  cat > "$PROTON_COMMON_ENV" <<EOF
WG_IPV6_ENABLED=on
DOCKER_NETWORK_CIDR=192.168.96.0/20
DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64
MANAGE_RESOLVED_DNS=off
EOF
  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<EOF
WG_ADDRESS_SUBNET=4
VPN_INTERFACE=pvsonarr
WG_PROFILE=pvsonarr
WG_CONFIG=$TEST_TMPDIR/pvsonarr.conf
STATE_DIR=$STATE_DIR
EOF
  append_manifest_routing sonarr "$PROTON_INSTANCE_ROOT/sonarr/proton.env"
  cat > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env" <<'EOF'
QBITTORRENT_URL=http://127.0.0.1:8083
QBT_CONTAINER_NAME=qbittorrent-sonarr
QBT_NETWORK_NAME=starr_network
EOF
  printf '[Interface]\nPrivateKey = test\n' > "$TEST_TMPDIR/pvsonarr.conf"
  printf '%s' 'fdca:6c19:2096::17' > "$STATE_DIR/qbt-container-ip6"

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$IP_LOG"
if [[ "$*" == *"rule del"* ]]; then
  if [[ "${FAIL_RULE_DELETE:-0}" == 1 ]]; then
    printf 'RTNETLINK answers: Operation not permitted\n' >&2
  else
    printf 'RTNETLINK answers: No such file or directory\n' >&2
  fi
  exit 2
fi
EOF
  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"GlobalIPv6Address"* ]]; then
  printf 'starr_network=fdca:6c19:2096::17\n'
elif [[ "$1" == inspect ]]; then
  printf 'starr_network=192.168.96.17\n'
fi
EOF
  cat > "$TMPBIN/wg-quick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WG_LOG"
if [[ "${FAIL_WG_DOWN:-0}" == 1 ]]; then exit 42; fi
touch "$WG_LOG.absent"
exit 0
EOF
  cat > "$TMPBIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAIL_WG_INSPECT:-0}" == 1 ]]; then exit 1; fi
if [[ ! -f "$WG_LOG.absent" ]]; then printf 'pvsonarr\n'; fi
EOF
  cat > "$TMPBIN/iptables" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *' -C '* ]]; then
  printf 'Bad rule (does a matching rule exist in that chain?).\n' >&2
  exit 1
fi
exit 0
EOF
  stub_systemd_cat
  chmod +x "$TMPBIN/ip" "$TMPBIN/docker" "$TMPBIN/wg" "$TMPBIN/wg-quick" "$TMPBIN/iptables"
}

@test "wg down removes Docker IPv6 owner rules before flushing the tunnel table" {
  run bash ./proton-wg-down-safe.sh sonarr

  [ "$status" -eq 0 ]
  qbt_line="$(grep -nF -- '-6 rule del from fdca:6c19:2096::17/128 lookup 51804 priority 114' "$IP_LOG" | head -n1 | cut -d: -f1)"
  fallback_line="$(grep -nF -- '-6 rule del from fdca:6c19:2096::/64 lookup 51804 priority 130' "$IP_LOG" | head -n1 | cut -d: -f1)"
  flush_line="$(grep -nF -- '-6 route flush table 51804' "$IP_LOG" | head -n1 | cut -d: -f1)"
  [ -n "$qbt_line" ]
  [ -n "$fallback_line" ]
  [ -n "$flush_line" ]
  [ "$qbt_line" -lt "$flush_line" ]
  [ "$fallback_line" -lt "$flush_line" ]
  # Rules nothing creates (fwmark at 100, Docker subnet at 110) are not touched.
  if grep -E 'fwmark|priority (100|110)$' "$IP_LOG"; then return 1; fi
  [ ! -e "$STATE_DIR/qbt-container-ip6" ]
}

@test "wg down reverts only its own link in systemd-resolved" {
  export RESOLVECTL_LOG="$TEST_TMPDIR/resolvectl.log"
  stub_command resolvectl 'printf "%s\n" "$*" >> "$RESOLVECTL_LOG"'
  sed -i 's/^MANAGE_RESOLVED_DNS=off$/MANAGE_RESOLVED_DNS=on/' "$PROTON_COMMON_ENV"

  run bash ./proton-wg-down-safe.sh sonarr

  [ "$status" -eq 0 ]
  [ "$(cat "$RESOLVECTL_LOG")" = 'revert pvsonarr' ]
  [ "$(wc -l < "$WG_LOG")" -eq 1 ]
}

@test "repeated teardown preserves shared rules and does not stop an absent tunnel twice" {
  run bash ./proton-wg-down-safe.sh sonarr
  [ "$status" -eq 0 ]
  run bash ./proton-wg-down-safe.sh sonarr
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WG_LOG")" -eq 1 ]
  ! grep -E 'rule del.*priority (98|99|108|109)$|flush table 51820' "$IP_LOG"
}

@test "failed teardown retains retry caches and reports the real failure" {
  run env FAIL_WG_DOWN=1 bash ./proton-wg-down-safe.sh sonarr
  [ "$status" -eq 42 ]
  [ -f "$STATE_DIR/qbt-container-ip6" ]
  run env FAIL_WG_INSPECT=1 bash ./proton-wg-down-safe.sh sonarr
  [ "$status" -ne 0 ]
  [ -f "$STATE_DIR/qbt-container-ip6" ]
}

@test "unexpected route deletion failure stops teardown before interface mutation" {
  run env FAIL_RULE_DELETE=1 bash ./proton-wg-down-safe.sh sonarr
  [ "$status" -ne 0 ]
  [ ! -f "$WG_LOG" ]
  [ -f "$STATE_DIR/qbt-container-ip6" ]
}

@test "the total stop deadline bounds stalled cleanup and preserves retry state" {
  mkfifo "$TEST_TMPDIR/blocked"
  export STOP_BLOCKED_FIFO="$TEST_TMPDIR/blocked"
  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
exec 7<>"$STOP_BLOCKED_FIFO"
read -r -t 10 -u 7 ignored
EOF
  before="$SECONDS"
  run env PROTON_WG_STOP_TIMEOUT_SECONDS=1 bash ./proton-wg-down-safe.sh sonarr
  [ "$status" -eq 124 ]
  [ "$((SECONDS - before))" -lt 8 ]
  [ ! -f "$WG_LOG" ]
  [ -f "$STATE_DIR/qbt-container-ip6" ]
  run flock -n "$PROTON_ROUTE_LOCK_FILE" true
  [ "$status" -eq 0 ]
  run flock -n "$STATE_DIR/lifecycle.lock" true
  [ "$status" -eq 0 ]
}

@test "stop deadline cannot exceed the systemd and partial-start cleanup budgets" {
  run env PROTON_WG_STOP_TIMEOUT_SECONDS=46 bash ./proton-wg-down-safe.sh sonarr
  [ "$status" -eq 1 ]
  [[ "$output" == *'must be between 1 and 45'* ]]
  [ ! -s "$IP_LOG" ]
  grep -Fx 'TimeoutStopSec=60' proton-wg@.service
}
