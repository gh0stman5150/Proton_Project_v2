#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  COMMAND_LOG="$TEST_TMPDIR/commands.log"
  mkdir -p "$TMPBIN"
  : > "$COMMAND_LOG"
  export PATH="$TMPBIN:$PATH"
  export PROTON_COMMON_ENV="$COMMON_ENV"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_RUNTIME_ROOT="$TEST_TMPDIR/run"
  export PROTON_IPV6_ROLLBACK_DIR="$TEST_TMPDIR/rollbacks"
  export WG_POOL_DIR="$TEST_TMPDIR/pool"
  export PROTON_PROJECT_DIR="$TEST_TMPDIR/project"
  export PROTON_LIVE_DIR="$TEST_TMPDIR/live"
  export COMMAND_LOG

  mkdir -p "$PROTON_INSTANCE_ROOT/sonarr" "$PROTON_RUNTIME_ROOT/sonarr" \
    "$PROTON_IPV6_ROLLBACK_DIR/snapshot/manifest" "$WG_POOL_DIR" \
    "$PROTON_PROJECT_DIR" "$PROTON_LIVE_DIR"
  ln -s "$PROTON_IPV6_ROLLBACK_DIR/snapshot" "$PROTON_IPV6_ROLLBACK_DIR/latest"
  : > "$PROTON_IPV6_ROLLBACK_DIR/snapshot/payload.tar.gz"
  : > "$PROTON_IPV6_ROLLBACK_DIR/snapshot/manifest/active-services.txt"

  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$COMMAND_LOG"
if [[ "$*" == *"--format {{.EnableIPv6}}"* ]]; then
  printf '%s\n' "${TEST_DOCKER_IPV6:-false}"
elif [[ "$*" == "network ls -q" ]]; then
  printf '%s\n' test-network
elif [[ "$*" == *"--format {{range .IPAM.Config}}{{println .Subnet}}{{end}}"* ]]; then
  printf '%s\n' "${TEST_DOCKER_SUBNET:-192.168.96.0/20}"
fi
EOF

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >> "$COMMAND_LOG"
if [[ "$*" == "-6 rule show" ]]; then
  printf '%s\n' '0: from all lookup local' '32766: from all lookup main'
elif [[ "$*" == "-6 route show default" ]]; then
  printf '%s\n' 'default via fe80::1 dev eth0'
elif [[ "$*" == "-6 route show table all" ]]; then
  printf '%s\n' "${TEST_IPV6_ROUTES:-default via fe80::1 dev eth0}"
fi
EOF

  cat > "$TMPBIN/nft" <<'EOF'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >> "$COMMAND_LOG"
EOF

  cat > "$TMPBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$COMMAND_LOG"
if [[ "$1" == "start" && "${2:-}" == "${TEST_SYSTEMCTL_FAIL:-}" ]]; then
  exit 1
fi
EOF

  cat > "$TMPBIN/tar" <<'EOF'
#!/usr/bin/env bash
printf 'tar %s\n' "$*" >> "$COMMAND_LOG"
EOF

  cat > "$TMPBIN/sysctl" <<'EOF'
#!/usr/bin/env bash
printf 'sysctl %s\n' "$*" >> "$COMMAND_LOG"
if [[ "$*" == "-n net.ipv6.conf.all.forwarding" ]]; then
  printf '%s\n' "${TEST_FORWARDING_ALL:-0}"
elif [[ "$*" == "-n net.ipv6.conf.default.forwarding" ]]; then
  printf '%s\n' "${TEST_FORWARDING_DEFAULT:-0}"
fi
EOF

  chmod +x "$TMPBIN/docker" "$TMPBIN/ip" "$TMPBIN/nft" "$TMPBIN/systemctl" "$TMPBIN/tar" "$TMPBIN/sysctl"

  for script in proton-killswitch-nft.sh proton-killswitch-safe.sh proton-killswitch-reset.sh \
    proton-wg-up-safe.sh proton-wg-down-safe.sh proton-docker-network-watcher.sh; do
    printf '#!/usr/bin/env bash\n' > "$PROTON_PROJECT_DIR/$script"
    cp "$PROTON_PROJECT_DIR/$script" "$PROTON_LIVE_DIR/$script"
  done
}

@test "preflight accepts the untouched IPv4-only nftables baseline without mutations" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=auto
WG_IPV6_ENABLED=off
EOF

  run bash ./proton-ipv6-rollout.sh preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: IPv4-only baseline is intact"* ]]
  run grep -Eq '(^| )(add|delete|replace|flush|start|stop|restart|enable|disable)( |$)' "$COMMAND_LOG"
  [ "$status" -eq 1 ]
}

@test "preflight refuses an already enabled WireGuard IPv6 baseline" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=nftables
WG_IPV6_ENABLED=on
EOF

  run bash ./proton-ipv6-rollout.sh preflight

  [ "$status" -ne 0 ]
  [[ "$output" == *"WG_IPV6_ENABLED is already on"* ]]
}

@test "preflight refuses a Docker network that already has IPv6 enabled" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=nftables
WG_IPV6_ENABLED=off
EOF

  run env TEST_DOCKER_IPV6=true bash ./proton-ipv6-rollout.sh preflight

  [ "$status" -ne 0 ]
  [[ "$output" == *"starr_network already has IPv6 enabled"* ]]
}

@test "Docker preflight accepts a deployed nftables ULA baseline without mutations" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=nftables
WG_IPV6_ENABLED=off
DOCKER_NETWORK_CIDR6=
EOF

  run bash ./proton-ipv6-rollout.sh docker-preflight fdca:6c19:2096::/64

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: Docker IPv6 preflight is clean"* ]]
  run grep -Eq '(^| )(add|delete|replace|flush|start|stop|restart|enable|disable|--write|-w)( |$)' "$COMMAND_LOG"
  [ "$status" -eq 1 ]
}

@test "Docker preflight refuses automatic backend selection" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=auto
WG_IPV6_ENABLED=off
EOF

  run bash ./proton-ipv6-rollout.sh docker-preflight fdca:6c19:2096::/64

  [ "$status" -ne 0 ]
  [[ "$output" == *"requires explicit KILLSWITCH_BACKEND=nftables"* ]]
}

@test "Docker preflight refuses forwarding enabled before firewall activation" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=nftables
WG_IPV6_ENABLED=off
EOF

  run env TEST_FORWARDING_ALL=1 bash ./proton-ipv6-rollout.sh docker-preflight fdca:6c19:2096::/64

  [ "$status" -ne 0 ]
  [[ "$output" == *"IPv6 forwarding baseline must remain off"* ]]
}

@test "Docker preflight refuses a firewall source and deployment mismatch" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=nftables
WG_IPV6_ENABLED=off
EOF
  printf '# changed\n' >> "$PROTON_LIVE_DIR/proton-killswitch-nft.sh"

  run bash ./proton-ipv6-rollout.sh docker-preflight fdca:6c19:2096::/64

  [ "$status" -ne 0 ]
  [[ "$output" == *"tested and installed Docker IPv6 scripts differ"* ]]
}

@test "Docker preflight refuses an enclosing existing IPv6 route" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=nftables
WG_IPV6_ENABLED=off
EOF

  run env TEST_IPV6_ROUTES='fdca:6c19::/32 dev eth0' \
    bash ./proton-ipv6-rollout.sh docker-preflight fdca:6c19:2096::/64

  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps an existing host route"* ]]
}

@test "canary preflight accepts one opted-in instance on a dual-stack profile" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=nftables
WG_IPV6_ENABLED=off
EOF
  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<'EOF'
WG_IPV6_ENABLED=on
EOF
  cat > "$PROTON_RUNTIME_ROOT/sonarr/current-server.env" <<EOF
SELECTED_WG_PROFILE=wg-v6
SELECTED_CONFIG=$WG_POOL_DIR/wg-v6.conf
EOF
  cat > "$WG_POOL_DIR/wg-v6.conf" <<'EOF'
[Interface]
Address = 10.2.0.2/32, 2a07:b944::2:2/128
DNS = 10.2.0.1, 2a07:b944::2:1
[Peer]
AllowedIPs = 0.0.0.0/0, ::/0
EOF

  run bash ./proton-ipv6-rollout.sh canary-preflight sonarr

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: sonarr canary is ready on wg-v6"* ]]
}

@test "canary preflight refuses an IPv4-only selected profile" {
  cat > "$COMMON_ENV" <<'EOF'
KILLSWITCH_BACKEND=nftables
WG_IPV6_ENABLED=off
EOF
  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<'EOF'
WG_IPV6_ENABLED=on
EOF
  cat > "$PROTON_RUNTIME_ROOT/sonarr/current-server.env" <<EOF
SELECTED_WG_PROFILE=wg-v4
SELECTED_CONFIG=$WG_POOL_DIR/wg-v4.conf
EOF
  cat > "$WG_POOL_DIR/wg-v4.conf" <<'EOF'
[Interface]
Address = 10.2.0.2/32
DNS = 10.2.0.1
[Peer]
AllowedIPs = 0.0.0.0/0, ::/0
EOF

  run bash ./proton-ipv6-rollout.sh canary-preflight sonarr

  [ "$status" -ne 0 ]
  [[ "$output" == *"not fully IPv6 capable"* ]]
}

@test "rollback service restoration starts instances sequentially by dependency order" {
  : > "$COMMAND_LOG"

  run bash -c 'source ./proton-ipv6-rollout.sh; start_snapshot_services \
    proton-healthcheck@sonarr.service \
    proton-wg@prowlarr.service \
    proton-killswitch.service \
    proton-port-forward@sonarr.service \
    proton-wg@sonarr.service \
    proton-docker-watch@sonarr.service \
    proton-port-forward@prowlarr.service'

  [ "$status" -eq 0 ]
  cat > "$TEST_TMPDIR/expected.log" <<'EOF'
systemctl start proton-killswitch.service
systemctl start proton-wg@prowlarr.service
systemctl start proton-wg@sonarr.service
systemctl start proton-port-forward@sonarr.service
systemctl start proton-port-forward@prowlarr.service
systemctl start proton-healthcheck@sonarr.service
systemctl start proton-docker-watch@sonarr.service
EOF
  diff -u "$TEST_TMPDIR/expected.log" "$COMMAND_LOG"
}

@test "rollback service restoration continues after one instance fails" {
  : > "$COMMAND_LOG"

  run env TEST_SYSTEMCTL_FAIL=proton-wg@prowlarr.service bash -c \
    'source ./proton-ipv6-rollout.sh; start_snapshot_services \
      proton-wg@prowlarr.service proton-wg@sonarr.service proton-port-forward@sonarr.service'

  [ "$status" -ne 0 ]
  grep -Fq 'systemctl start proton-wg@sonarr.service' "$COMMAND_LOG"
  grep -Fq 'systemctl start proton-port-forward@sonarr.service' "$COMMAND_LOG"
  [[ "$output" == *"proton-wg@prowlarr.service"* ]]
}