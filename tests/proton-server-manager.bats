#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export STATE_DIR="$TEST_TMPDIR/state"
  export WG_POOL_DIR="$TEST_TMPDIR/pool"
  export SERVER_SELECTION_FILE="$STATE_DIR/current-server.env"
  export BAD_SERVER_FILE="$STATE_DIR/bad-servers.tsv"
  export SERVER_RESELECT_FILE="$STATE_DIR/reselect-server.flag"
  export PF_CAPABLE_PROFILES_FILE="$TEST_TMPDIR/pf-capable.tsv"
  export PF_INCAPABLE_PROFILES_FILE="$TEST_TMPDIR/pf-incapable.tsv"
  export PF_INCAPABLE_STRIKES_FILE="$STATE_DIR/pf-incapable-strikes.tsv"
  export PROTON_COMMON_ENV_FILE="$TEST_TMPDIR/proton-common.env"
  export WG_EXPECTED_DNS=10.2.0.1
  export SERVER_POOL_ENABLED=on
  export SERVER_POOL_STRICT_LINT=on
  export PORT_FORWARD_REQUIRED=on
  export PATH="$TMPBIN:$PATH"

  mkdir -p "$TMPBIN" "$STATE_DIR" "$WG_POOL_DIR"
  : > "$PROTON_COMMON_ENV_FILE"

  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat - >/dev/null
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TMPBIN/getent" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  host-a)
    echo '203.0.113.10 STREAM host-a'
    ;;
  host-b)
    echo '203.0.113.20 STREAM host-b'
    ;;
  host-c)
    echo '203.0.113.30 STREAM host-c'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$TMPBIN/getent"

  cat > "$TMPBIN/ping" <<'EOF'
#!/usr/bin/env bash
target="${@: -1}"
case "$target" in
  203.0.113.10)
    avg=5.000
    ;;
  203.0.113.20)
    avg=20.000
    ;;
  203.0.113.30)
    avg=30.000
    ;;
  *)
    exit 1
    ;;
esac

printf 'PING %s (%s) 56(84) bytes of data.\n' "$target" "$target"
printf 'rtt min/avg/max/mdev = %s/%s/%s/0.000 ms\n' "$avg" "$avg" "$avg"
EOF
  chmod +x "$TMPBIN/ping"
}

write_pool_config() {
  local profile="$1"
  local host="$2"

  cat > "$WG_POOL_DIR/${profile}.conf" <<EOF
[Interface]
PrivateKey = test
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = test
AllowedIPs = 0.0.0.0/0
Endpoint = ${host}:51820
EOF
}

@test "select prefers proven port-forward capable profiles once allowlist exists" {
  write_pool_config wg-a host-a
  write_pool_config wg-b host-b
  write_pool_config wg-c host-c

  printf 'wg-b\t1\t40000\nwg-c\t1\t50000\n' > "$PF_CAPABLE_PROFILES_FILE"
  printf 'wg-c\t1\tnatpmp-timeout\n' > "$PF_INCAPABLE_PROFILES_FILE"

  run env \
    STATE_DIR="$STATE_DIR" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    BAD_SERVER_FILE="$BAD_SERVER_FILE" \
    SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_EXPECTED_DNS="$WG_EXPECTED_DNS" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    SERVER_POOL_STRICT_LINT="$SERVER_POOL_STRICT_LINT" \
    PORT_FORWARD_REQUIRED="$PORT_FORWARD_REQUIRED" \
    bash ./proton-server-manager.sh select

  [ "$status" -eq 0 ]
  grep -F 'SELECTED_WG_PROFILE=wg-b' "$SERVER_SELECTION_FILE"
}

@test "select skips port-forward incapable profiles when no allowlist exists yet" {
  write_pool_config wg-a host-a
  write_pool_config wg-b host-b

  printf 'wg-a\t1\tnatpmp-timeout\n' > "$PF_INCAPABLE_PROFILES_FILE"

  run env \
    STATE_DIR="$STATE_DIR" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    BAD_SERVER_FILE="$BAD_SERVER_FILE" \
    SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_EXPECTED_DNS="$WG_EXPECTED_DNS" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    SERVER_POOL_STRICT_LINT="$SERVER_POOL_STRICT_LINT" \
    PORT_FORWARD_REQUIRED="$PORT_FORWARD_REQUIRED" \
    bash ./proton-server-manager.sh select

  [ "$status" -eq 0 ]
  grep -F 'SELECTED_WG_PROFILE=wg-b' "$SERVER_SELECTION_FILE"
}

@test "select widens to healthy unproven nodes when every proven-good node is cooling down" {
  write_pool_config wg-a host-a
  write_pool_config wg-b host-b

  printf 'wg-a\t1\t45678\n' > "$PF_CAPABLE_PROFILES_FILE"
  printf 'wg-a\t9999999999\tport-forward-failures\n' > "$BAD_SERVER_FILE"

  run env \
    STATE_DIR="$STATE_DIR" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    BAD_SERVER_FILE="$BAD_SERVER_FILE" \
    SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_EXPECTED_DNS="$WG_EXPECTED_DNS" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    SERVER_POOL_STRICT_LINT="$SERVER_POOL_STRICT_LINT" \
    PORT_FORWARD_REQUIRED="$PORT_FORWARD_REQUIRED" \
    bash ./proton-server-manager.sh select

  [ "$status" -eq 0 ]
  grep -F 'SELECTED_WG_PROFILE=wg-b' "$SERVER_SELECTION_FILE"
}

@test "select still excludes incapable nodes when widening beyond the allowlist" {
  write_pool_config wg-a host-a
  write_pool_config wg-b host-b
  write_pool_config wg-c host-c

  printf 'wg-a\t1\t45678\n' > "$PF_CAPABLE_PROFILES_FILE"
  printf 'wg-c\t1\tnatpmp-timeout\n' > "$PF_INCAPABLE_PROFILES_FILE"
  printf 'wg-a\t9999999999\tport-forward-failures\n' > "$BAD_SERVER_FILE"

  run env \
    STATE_DIR="$STATE_DIR" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    BAD_SERVER_FILE="$BAD_SERVER_FILE" \
    SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_EXPECTED_DNS="$WG_EXPECTED_DNS" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    SERVER_POOL_STRICT_LINT="$SERVER_POOL_STRICT_LINT" \
    PORT_FORWARD_REQUIRED="$PORT_FORWARD_REQUIRED" \
    bash ./proton-server-manager.sh select

  [ "$status" -eq 0 ]
  grep -F 'SELECTED_WG_PROFILE=wg-b' "$SERVER_SELECTION_FILE"
}

@test "select accepts IPv4-only DNS when IPv6 lint is disabled for the tunnel" {
  write_pool_config wg-a host-a

  run env \
    STATE_DIR="$STATE_DIR" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    BAD_SERVER_FILE="$BAD_SERVER_FILE" \
    SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_EXPECTED_DNS="10.2.0.1,2a07:b944::2:1" \
    WG_IPV6_ENABLED=off \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    SERVER_POOL_STRICT_LINT="$SERVER_POOL_STRICT_LINT" \
    PORT_FORWARD_REQUIRED=off \
    bash ./proton-server-manager.sh select

  [ "$status" -eq 0 ]
  grep -F 'SELECTED_WG_PROFILE=wg-a' "$SERVER_SELECTION_FILE"
}

@test "mark-capable removes a profile from incapable state and records its port" {
  printf 'wg-a\t1\tnatpmp-timeout\n' > "$PF_INCAPABLE_PROFILES_FILE"

  run env \
    STATE_DIR="$STATE_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    bash ./proton-server-manager.sh mark-capable wg-a 45678

  [ "$status" -eq 0 ]
  grep -F $'wg-a\t' "$PF_CAPABLE_PROFILES_FILE"
  grep -F '45678' "$PF_CAPABLE_PROFILES_FILE"
  run grep -F 'wg-a' "$PF_INCAPABLE_PROFILES_FILE"
  [ "$status" -ne 0 ]
}

@test "mark-incapable removes a profile from capable state and forces reselection" {
  printf 'wg-b\t1\t45678\n' > "$PF_CAPABLE_PROFILES_FILE"

  run env \
    STATE_DIR="$STATE_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    bash ./proton-server-manager.sh mark-incapable wg-b natpmp-timeout

  [ "$status" -eq 0 ]
  grep -F $'wg-b\t' "$PF_INCAPABLE_PROFILES_FILE"
  grep -F 'natpmp-timeout' "$PF_INCAPABLE_PROFILES_FILE"
  [ -f "$SERVER_RESELECT_FILE" ]
  run grep -F 'wg-b' "$PF_CAPABLE_PROFILES_FILE"
  [ "$status" -ne 0 ]
}

@test "mark-incapable-attempt records a strike and cools down without evicting below threshold" {
  printf '[Interface]\n' > "$WG_POOL_DIR/wg-c.conf"

  run env \
    STATE_DIR="$STATE_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
    BAD_SERVER_FILE="$BAD_SERVER_FILE" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_STRIKES_FILE="$PF_INCAPABLE_STRIKES_FILE" \
    PF_INCAPABLE_STRIKE_THRESHOLD=3 \
    bash ./proton-server-manager.sh mark-incapable-attempt wg-c natpmp-timeout

  [ "$status" -eq 0 ]
  grep -F $'wg-c\t1\t' "$PF_INCAPABLE_STRIKES_FILE"
  [ -f "$WG_POOL_DIR/wg-c.conf" ]
  grep -F 'wg-c' "$BAD_SERVER_FILE"
  run grep -F 'wg-c' "$PF_INCAPABLE_PROFILES_FILE"
  [ "$status" -ne 0 ]
}

@test "mark-incapable-attempt evicts a profile and deletes its pool config after threshold strikes" {
  printf '[Interface]\n' > "$WG_POOL_DIR/wg-c.conf"

  for _ in 1 2 3; do
    run env \
      STATE_DIR="$STATE_DIR" \
      SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
      SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
      BAD_SERVER_FILE="$BAD_SERVER_FILE" \
      WG_POOL_DIR="$WG_POOL_DIR" \
      PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
      PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
      PF_INCAPABLE_STRIKES_FILE="$PF_INCAPABLE_STRIKES_FILE" \
      PF_INCAPABLE_STRIKE_THRESHOLD=3 \
      bash ./proton-server-manager.sh mark-incapable-attempt wg-c natpmp-timeout
    [ "$status" -eq 0 ]
  done

  grep -F $'wg-c\t' "$PF_INCAPABLE_PROFILES_FILE"
  [ ! -f "$WG_POOL_DIR/wg-c.conf" ]
  [ -f "$SERVER_RESELECT_FILE" ]
  run grep -F 'wg-c' "$PF_INCAPABLE_STRIKES_FILE"
  [ "$status" -ne 0 ]
}

@test "mark-incapable-attempt never evicts a proven-good server; it clears strikes and cools it down" {
  printf 'wg-d\t1\t45678\n' > "$PF_CAPABLE_PROFILES_FILE"
  printf 'wg-d\t2\t1\n' > "$PF_INCAPABLE_STRIKES_FILE"
  printf '[Interface]\n' > "$WG_POOL_DIR/wg-d.conf"

  run env \
    STATE_DIR="$STATE_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    SERVER_RESELECT_FILE="$SERVER_RESELECT_FILE" \
    BAD_SERVER_FILE="$BAD_SERVER_FILE" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_STRIKES_FILE="$PF_INCAPABLE_STRIKES_FILE" \
    PF_INCAPABLE_STRIKE_THRESHOLD=3 \
    bash ./proton-server-manager.sh mark-incapable-attempt wg-d natpmp-timeout

  [ "$status" -eq 0 ]
  grep -F $'wg-d\t' "$PF_CAPABLE_PROFILES_FILE"
  [ -f "$WG_POOL_DIR/wg-d.conf" ]
  grep -F 'wg-d' "$BAD_SERVER_FILE"
  run grep -F 'wg-d' "$PF_INCAPABLE_PROFILES_FILE"
  [ "$status" -ne 0 ]
  run grep -F 'wg-d' "$PF_INCAPABLE_STRIKES_FILE"
  [ "$status" -ne 0 ]
}

@test "mark-capable clears any recorded incapability strikes" {
  printf 'wg-e\t2\t1\n' > "$PF_INCAPABLE_STRIKES_FILE"

  run env \
    STATE_DIR="$STATE_DIR" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_STRIKES_FILE="$PF_INCAPABLE_STRIKES_FILE" \
    bash ./proton-server-manager.sh mark-capable wg-e 45678

  [ "$status" -eq 0 ]
  grep -F $'wg-e\t' "$PF_CAPABLE_PROFILES_FILE"
  run grep -F 'wg-e' "$PF_INCAPABLE_STRIKES_FILE"
  [ "$status" -ne 0 ]
}
