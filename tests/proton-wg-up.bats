#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export STATE_DIR="$TEST_TMPDIR/state"
  export WG_RUNTIME_DIR="$TEST_TMPDIR/runtime"
  export WG_PROFILE="wg-test"
  export VPN_INTERFACE="$WG_PROFILE"
  export WG_CONFIG="$TEST_TMPDIR/$WG_PROFILE.conf"
  export DOCKER_NETWORK_CIDR="192.168.96.0/20"
  export LAN_IF="enp86s0"
  export LAN_CIDR="192.168.1.0/24"
  export SERVER_POOL_ENABLED="off"
  export MANAGE_RESOLVED_DNS="off"
  export KILLSWITCH_SCRIPT="$TEST_TMPDIR/missing-killswitch.sh"

  mkdir -p "$TMPBIN" "$STATE_DIR" "$WG_RUNTIME_DIR"

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
if [[ "$1" == "up" ]]; then
  printf '%s\n' 'stat: cannot read table of mounted file systems: Permission denied' >&2
  printf '%s\n' '/usr/bin/wg-quick: line 47: ((: ( &  & 0007) == 0: syntax error: operand expected (error token is "&  & 0007) == 0")' >&2
  printf "Warning: \`%s' is world accessible\n" "$2" >&2
  printf '[#] ip link add %s type wireguard\n' "${WG_PROFILE:-wg-test}" >&2
fi
exit 0
EOF
  chmod +x "$TMPBIN/wg-quick"

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-4" && "$2" == "addr" && "$3" == "show" ]]; then
  printf '3: %s: <POINTOPOINT,UP,LOWER_UP> mtu 1420\n' "$4"
  printf '    inet 10.2.0.2/32 scope global %s\n' "$4"
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPBIN/ip"

  cat > "$TMPBIN/iptables" <<'EOF'
#!/usr/bin/env bash
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
    bash ./proton-wg-up-safe.sh

  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot read table of mounted file systems"* ]]
  [[ "$output" != *"world accessible"* ]]
  [[ "$output" != *"syntax error: operand expected"* ]]
  [[ "$output" == *"[#] ip link add wg-test type wireguard"* ]]
  [[ "$output" == *"WireGuard up on wg-test with IP: 10.2.0.2"* ]]
}
