#!/usr/bin/env bats

export BATS_TEST_TIMEOUT=20

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export STATE_DIR="$TEST_TMPDIR/state"
  export WG_RUNTIME_DIR="$TEST_TMPDIR/runtime"
  export WG_PROFILE="wg-test"
  export VPN_INTERFACE="$WG_PROFILE"
  export WG_CONFIG="$TEST_TMPDIR/$WG_PROFILE.conf"
  export DOCKER_NETWORK_CIDR="192.168.96.0/20"
  export IP_LOG="$TEST_TMPDIR/ip.log"
  export WG_LOG="$TEST_TMPDIR/wg.log"
  export LAN_IF="enp86s0"
  export LAN_CIDR="192.168.1.0/24"
  export SERVER_POOL_ENABLED="off"
  export MANAGE_RESOLVED_DNS="off"
  export KILLSWITCH_SCRIPT="$TEST_TMPDIR/killswitch.sh"
  export PROTON_ROUTE_LOCK_FILE="$TEST_TMPDIR/policy-routing.lock"
  export KILLSWITCH_LOCK_FILE="$TEST_TMPDIR/killswitch.lock"

  mkdir -p "$TMPBIN" "$STATE_DIR" "$WG_RUNTIME_DIR" "$PROTON_INSTANCE_ROOT/sonarr"
  : > "$PROTON_COMMON_ENV"
  printf '#!/usr/bin/env bash\nexit "${FAIL_KILLSWITCH:-0}"\n' > "$KILLSWITCH_SCRIPT"
  chmod +x "$KILLSWITCH_SCRIPT"

  cat > "$TMPBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit "${TEST_DOCKER_INACTIVE:-0}"
EOF
  chmod +x "$TMPBIN/systemctl"

  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<EOF
STATE_DIR=$STATE_DIR
WG_RUNTIME_DIR=$WG_RUNTIME_DIR
WG_ADDRESS_SUBNET=4
EOF

  cat > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env" <<'EOF'
QBITTORRENT_URL=http://127.0.0.1:8083
QBT_CONTAINER_NAME=qbittorrent-sonarr
QBT_NETWORK_NAME=starr_network
EOF

  cat > "$WG_CONFIG" <<'EOF'
[Interface]
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
AllowedIPs = 0.0.0.0/0
EOF

  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat -
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TMPBIN/wg-quick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WG_LOG"
if [[ "$1" == "up" ]]; then
  touch "$WG_LOG.present"
  if [[ "${INTERRUPT_UP:-0}" == 1 ]]; then kill -TERM "$TEST_UP_PID"; fi
  if [[ "${FAIL_WG_UP:-0}" == 1 ]]; then exit 42; fi
  printf '%s\n' 'stat: cannot read table of mounted file systems: Permission denied' >&2
  printf '%s\n' '/usr/bin/wg-quick: line 47: ((: ( &  & 0007) == 0: syntax error: operand expected (error token is "&  & 0007) == 0")' >&2
  printf "Warning: \`%s' is world accessible\n" "$2" >&2
  printf '[#] ip link add %s type wireguard\n' "${WG_PROFILE:-wg-test}" >&2
fi
if [[ "$1" == down ]]; then
  if [[ -f "$2" ]]; then cp "$2" "$WG_LOG.down-config"; fi
  rm -f "$WG_LOG.present"
fi
exit 0
EOF
  chmod +x "$TMPBIN/wg-quick"

  cat > "$TMPBIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == 'show interfaces' ]]; then
  if [[ -f "$WG_LOG.present" ]]; then printf '%s\n' "$VPN_INTERFACE"; fi
elif [[ "$*" == *latest-handshakes* && -f "$WG_LOG.present" ]]; then
  printf 'fixture-peer\t%s\n' "$(date +%s)"
else
  exit 1
fi
EOF
  chmod +x "$TMPBIN/wg"

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-4" && "$2" == "addr" && "$3" == "show" ]]; then
  printf '3: %s: <POINTOPOINT,UP,LOWER_UP> mtu 1420\n' "$4"
  printf '    inet 10.4.0.2/32 scope global %s\n' "$4"
  exit 0
fi
printf '%s\n' "$*" >> "$IP_LOG"
if [[ "$*" == *"rule add from 192.168.96.44/32"* && "${FAIL_OWNER_RULE:-0}" == 1 ]]; then exit 1; fi
if [[ "$*" == *"rule del"* || "$*" == *"rule del "* ]]; then
  printf 'RTNETLINK answers: No such file or directory\n' >&2
  exit 2
fi
exit 0
EOF
  chmod +x "$TMPBIN/ip"

  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "inspect" ]]; then
  if [[ "$*" == *"GlobalIPv6Address"* ]]; then
    printf 'starr_network=fdca:6c19:2096::44\n'
  else
    printf 'starr_network=192.168.96.44\n'
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPBIN/docker"

  cat > "$TMPBIN/iptables" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *' -C '* ]]; then
  printf 'Bad rule (does a matching rule exist in that chain?).\n' >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$TMPBIN/iptables"

  cat > "$TMPBIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMPBIN/sleep"
}

@test "wg up filters the known false world-accessible warning noise for runtime configs" {
  run env \
    PATH="$PATH" \
    STATE_DIR="$STATE_DIR" \
    WG_RUNTIME_DIR="$WG_RUNTIME_DIR" \
    WG_PROFILE="$WG_PROFILE" \
    VPN_INTERFACE="$VPN_INTERFACE" \
    WG_CONFIG="$WG_CONFIG" \
    DOCKER_NETWORK_CIDR="$DOCKER_NETWORK_CIDR" \
    LAN_IF="$LAN_IF" \
    LAN_CIDR="$LAN_CIDR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    MANAGE_RESOLVED_DNS="$MANAGE_RESOLVED_DNS" \
    KILLSWITCH_SCRIPT="$KILLSWITCH_SCRIPT" \
    bash ./proton-wg-up-safe.sh sonarr

  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot read table of mounted file systems"* ]]
  [[ "$output" != *"world accessible"* ]]
  [[ "$output" != *"syntax error: operand expected"* ]]
  [[ "$output" == *"[#] ip link add wg-test type wireguard"* ]]
  [[ "$output" == *"qBittorrent policy routing: source 192.168.96.44/32 -> table 51804 via wg-test"* ]]
  [[ "$output" == *"WireGuard up on wg-test with IP: 10.4.0.2"* ]]
  grep -F 'route replace default dev wg-test table 51804' "$IP_LOG"
  grep -F 'rule add from 192.168.96.44/32 lookup 51804 priority 114' "$IP_LOG"
  grep -F 'rule add from 192.168.96.0/20 lookup 51804 priority 130' "$IP_LOG"
}

@test "repeated healthy bring-up preserves the tunnel generation and lease" {
  run bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -eq 0 ]
  generation="$(cat "$STATE_DIR/tunnel-generation")"
  printf 'existing-lease\n' > "$STATE_DIR/proton-port.state"
  run bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -eq 0 ]
  [ "$(grep -c '^up ' "$WG_LOG")" -eq 1 ]
  run grep -q '^down ' "$WG_LOG"
  [ "$status" -eq 1 ]
  [ "$(cat "$STATE_DIR/tunnel-generation")" = "$generation" ]
  [ "$(cat "$STATE_DIR/proton-port.state")" = existing-lease ]
}

@test "bring-up replaces a missing generation and discards the previous lease" {
  run bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -eq 0 ]
  previous_generation="$(cat "$STATE_DIR/tunnel-generation")"
  printf 'stale-lease\n' > "$STATE_DIR/proton-port.state"
  rm "$STATE_DIR/tunnel-generation"

  run bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -eq 0 ]
  [ "$(grep -c '^up ' "$WG_LOG")" -eq 2 ]
  [ "$(grep -c '^down ' "$WG_LOG")" -eq 1 ]
  [ -s "$STATE_DIR/tunnel-generation" ]
  [ "$(cat "$STATE_DIR/tunnel-generation")" != "$previous_generation" ]
  [ ! -f "$STATE_DIR/proton-port.state" ]
}

@test "bring-up refuses missing or failed kill switch before tunnel mutation" {
  run env FAIL_KILLSWITCH=1 bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -ne 0 ]
  [ ! -s "$WG_LOG" ]
  rm "$KILLSWITCH_SCRIPT"
  run bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -ne 0 ]
  [ ! -s "$WG_LOG" ]
}

@test "changed configuration tears down using the old runtime config" {
  run bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -eq 0 ]
  cp "$WG_RUNTIME_DIR/$WG_PROFILE.conf" "$TEST_TMPDIR/previous.conf"
  printf 'Endpoint = 198.51.100.10:51820\n' >> "$WG_CONFIG"
  run bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -eq 0 ]
  cmp "$TEST_TMPDIR/previous.conf" "$WG_LOG.down-config"
  grep -F 'Endpoint = 198.51.100.10:51820' "$WG_RUNTIME_DIR/$WG_PROFILE.conf"
}

@test "partial interface creation is cleaned up without publishing a generation" {
  run env FAIL_WG_UP=1 bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -eq 42 ]
  [ ! -f "$WG_LOG.present" ]
  [ ! -f "$STATE_DIR/tunnel-generation" ]
  grep -q '^down ' "$WG_LOG"
  run compgen -G "$WG_RUNTIME_DIR/.prepare.*"
  [ "$status" -eq 1 ]
}

@test "failed owner route rolls back a new tunnel and never deletes shared legacy rules" {
  run env FAIL_OWNER_RULE=1 bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -ne 0 ]
  [ ! -f "$STATE_DIR/tunnel-generation" ]
  [ ! -f "$WG_LOG.present" ]
  ! grep -E 'rule del.*priority (98|99)$|rule del.*lookup 51820' "$IP_LOG"
}

@test "interrupted bring-up cleans the interface and releases lifecycle ownership" {
  run env INTERRUPT_UP=1 bash -c 'export TEST_UP_PID=$$; exec bash ./proton-wg-up-safe.sh sonarr'
  [ "$status" -eq 143 ]
  [ ! -f "$WG_LOG.present" ]
  [ ! -f "$STATE_DIR/tunnel-generation" ]
  run flock -n "$STATE_DIR/lifecycle.lock" true
  [ "$status" -eq 0 ]
}

@test "wg up injects PersistentKeepalive into the filtered runtime config" {
  run env \
    PATH="$PATH" \
    STATE_DIR="$STATE_DIR" \
    WG_RUNTIME_DIR="$WG_RUNTIME_DIR" \
    WG_PROFILE="$WG_PROFILE" \
    VPN_INTERFACE="$VPN_INTERFACE" \
    WG_CONFIG="$WG_CONFIG" \
    DOCKER_NETWORK_CIDR="$DOCKER_NETWORK_CIDR" \
    LAN_IF="$LAN_IF" \
    LAN_CIDR="$LAN_CIDR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    MANAGE_RESOLVED_DNS="$MANAGE_RESOLVED_DNS" \
    KILLSWITCH_SCRIPT="$KILLSWITCH_SCRIPT" \
    bash ./proton-wg-up-safe.sh sonarr

  [ "$status" -eq 0 ]
  grep -Fq 'PersistentKeepalive = 25' "$WG_RUNTIME_DIR/$WG_PROFILE.conf"
  grep -Fq 'Table = off' "$WG_RUNTIME_DIR/$WG_PROFILE.conf"
}

@test "wg up does not duplicate an existing PersistentKeepalive" {
  cat > "$WG_CONFIG" <<'EOF'
[Interface]
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
EOF

  run env \
    PATH="$PATH" \
    STATE_DIR="$STATE_DIR" \
    WG_RUNTIME_DIR="$WG_RUNTIME_DIR" \
    WG_PROFILE="$WG_PROFILE" \
    VPN_INTERFACE="$VPN_INTERFACE" \
    WG_CONFIG="$WG_CONFIG" \
    DOCKER_NETWORK_CIDR="$DOCKER_NETWORK_CIDR" \
    LAN_IF="$LAN_IF" \
    LAN_CIDR="$LAN_CIDR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    MANAGE_RESOLVED_DNS="$MANAGE_RESOLVED_DNS" \
    KILLSWITCH_SCRIPT="$KILLSWITCH_SCRIPT" \
    bash ./proton-wg-up-safe.sh sonarr

  [ "$status" -eq 0 ]
  run grep -c 'PersistentKeepalive' "$WG_RUNTIME_DIR/$WG_PROFILE.conf"
  [ "$output" -eq 1 ]
  grep -Fq 'PersistentKeepalive = 15' "$WG_RUNTIME_DIR/$WG_PROFILE.conf"
}

@test "wg up preserves Proton IPv6 fields and prepares the IPv6 route table when enabled" {
  cat > "$WG_CONFIG" <<'EOF'
[Interface]
Address = 10.2.0.2/32, 2a07:b944::2:2/128
DNS = 10.2.0.1, 2a07:b944::2:1

[Peer]
AllowedIPs = 0.0.0.0/0, ::/0
EOF

  run env \
    PATH="$PATH" \
    STATE_DIR="$STATE_DIR" \
    WG_RUNTIME_DIR="$WG_RUNTIME_DIR" \
    WG_PROFILE="$WG_PROFILE" \
    VPN_INTERFACE="$VPN_INTERFACE" \
    WG_CONFIG="$WG_CONFIG" \
    WG_IPV6_ENABLED=on \
    DOCKER_NETWORK_CIDR="$DOCKER_NETWORK_CIDR" \
    DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64 \
    DOCKER_IPV6_FALLBACK_INSTANCE=sonarr \
    LAN_IF="$LAN_IF" \
    LAN_CIDR="$LAN_CIDR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    MANAGE_RESOLVED_DNS="$MANAGE_RESOLVED_DNS" \
    KILLSWITCH_SCRIPT="$KILLSWITCH_SCRIPT" \
    bash ./proton-wg-up-safe.sh sonarr

  [ "$status" -eq 0 ]
  grep -Fq 'Address = 10.4.0.2/32, 2a07:b944::2:2/128' "$WG_RUNTIME_DIR/$WG_PROFILE.conf"
  grep -Fq 'DNS = 10.4.0.1, 2a07:b944::2:1' "$WG_RUNTIME_DIR/$WG_PROFILE.conf"
  grep -Fq -- '-6 route replace default dev wg-test table 51804' "$IP_LOG"
  grep -Fq -- '-6 rule add oif wg-test lookup 51804 priority 114' "$IP_LOG"
  grep -Fq -- '-6 rule add from fdca:6c19:2096::/64 to fdca:6c19:2096::/64 lookup main priority 108' "$IP_LOG"
  grep -Fq -- '-6 rule add from fdca:6c19:2096::44/128 lookup 51804 priority 114' "$IP_LOG"
  grep -Fq -- '-6 rule add from fdca:6c19:2096::/64 lookup 51804 priority 130' "$IP_LOG"
  [[ "$output" == *"qBittorrent IPv6 policy routing: source fdca:6c19:2096::44/128 -> table 51804 via wg-test"* ]]
}

@test "wg up refuses IPv6 mode when the profile has no IPv6 interface address" {
  cat > "$WG_CONFIG" <<'EOF'
[Interface]
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
AllowedIPs = 0.0.0.0/0, ::/0
EOF

  run env \
    PATH="$PATH" \
    STATE_DIR="$STATE_DIR" \
    WG_RUNTIME_DIR="$WG_RUNTIME_DIR" \
    WG_PROFILE="$WG_PROFILE" \
    VPN_INTERFACE="$VPN_INTERFACE" \
    WG_CONFIG="$WG_CONFIG" \
    WG_IPV6_ENABLED=on \
    DOCKER_NETWORK_CIDR="$DOCKER_NETWORK_CIDR" \
    LAN_IF="$LAN_IF" \
    LAN_CIDR="$LAN_CIDR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    MANAGE_RESOLVED_DNS="$MANAGE_RESOLVED_DNS" \
    KILLSWITCH_SCRIPT="$KILLSWITCH_SCRIPT" \
    bash ./proton-wg-up-safe.sh sonarr

  [ "$status" -ne 0 ]
  [[ "$output" == *"IPv6 mode requires a Proton-assigned IPv6 interface address"* ]]
  ! grep -Fq 'route replace default' "$IP_LOG"
}

@test "cold boot never queries Docker before the daemon is active" {
  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected Docker query\n' >> "$IP_LOG"
exit 99
EOF
  run env TEST_DOCKER_INACTIVE=1 bash ./proton-wg-up-safe.sh sonarr
  [ "$status" -eq 0 ]
  ! grep -q 'unexpected Docker query' "$IP_LOG"
}
