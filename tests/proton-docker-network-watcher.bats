#!/usr/bin/env bats

export BATS_TEST_TIMEOUT=15

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export STATE_DIR="$TEST_TMPDIR/state"
  export IP_LOG="$TEST_TMPDIR/ip.log"
  export PROTON_WATCHER_SOURCE_ONLY=1
  export PROTON_ROUTE_LOCK_FILE="$TEST_TMPDIR/policy-routing.lock"
  export KILLSWITCH_LOCK_FILE="$TEST_TMPDIR/killswitch.lock"
  mkdir -p "$TMPBIN" "$STATE_DIR" "$PROTON_INSTANCE_ROOT/sonarr" "$PROTON_INSTANCE_ROOT/radarr"
  : > "$IP_LOG"

  cat > "$PROTON_COMMON_ENV" <<EOF
DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64
DOCKER_FALLBACK_INSTANCE=sonarr
DOCKER_IPV6_FALLBACK_INSTANCE=sonarr
DOCKER_FALLBACK_VPN_ROUTING=on
EOF

  for instance in lidarr prowlarr radarr sonarr whisparr; do
    case "$instance" in
      lidarr) subnet=2; port=8081 ;;
      prowlarr) subnet=6; port=8082 ;;
      radarr) subnet=3; port=8083 ;;
      sonarr) subnet=4; port=8084 ;;
      whisparr) subnet=5; port=8085 ;;
    esac
    mkdir -p "$PROTON_INSTANCE_ROOT/$instance"
    cat > "$PROTON_INSTANCE_ROOT/$instance/proton.env" <<EOF
WG_ADDRESS_SUBNET=$subnet
VPN_INTERFACE=pv$instance
STATE_DIR=$STATE_DIR/$instance
LAST_FILE=$STATE_DIR/$instance/docker-network-watcher.last
DOCKER_NETWORK_CIDR_STATE_FILE=$STATE_DIR/$instance/docker-network-cidr
EOF
    cat > "$PROTON_INSTANCE_ROOT/$instance/qbittorrent.env" <<EOF
QBITTORRENT_URL=http://127.0.0.1:$port
QBT_CONTAINER_NAME=qbittorrent-$instance
QBT_NETWORK_NAME=starr_network
EOF
  done

cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$IP_LOG"
if [[ "$*" == *"route replace default"* && "${FAIL_DEFAULT_ROUTE:-0}" == 1 ]]; then
  exit 1
fi
if [[ "$*" == *"-6 rule add from fdca:6c19:2096::17/128"* && "${FAIL_IPV6_RULE:-0}" == 1 ]]; then exit 1; fi
if [[ "$*" == *"rule del"* || "$*" == *"rule del "* ]]; then
  printf 'RTNETLINK answers: No such file or directory\n' >&2
  exit 2
fi
EOF
  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${DOCKER_INSPECT_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "${WRONG_NETWORK:-0}" == 1 ]]; then printf 'other_network=192.168.96.17\n'; exit 0; fi
if [[ "$*" == *"GlobalIPv6Address"* ]]; then
  if [[ "${NO_IPV6:-0}" == 1 ]]; then exit 0; fi
  [[ "$*" == *"qbittorrent-lidarr"* ]] && printf 'starr_network=fdca:6c19:2096::15\n'
  [[ "$*" == *"qbittorrent-prowlarr"* ]] && printf 'starr_network=fdca:6c19:2096::19\n'
  [[ "$*" == *"qbittorrent-whisparr"* ]] && printf 'starr_network=fdca:6c19:2096::18\n'
  [[ "$*" == *"qbittorrent-sonarr"* ]] && printf 'starr_network=fdca:6c19:2096::17\n'
  [[ "$*" == *"qbittorrent-radarr"* ]] && printf 'starr_network=fdca:6c19:2096::16\n'
elif [[ "$1" == inspect ]]; then
  [[ "$*" == *"qbittorrent-lidarr"* ]] && printf 'starr_network=192.168.96.15\n'
  [[ "$*" == *"qbittorrent-prowlarr"* ]] && printf 'starr_network=192.168.96.19\n'
  [[ "$*" == *"qbittorrent-whisparr"* ]] && printf 'starr_network=192.168.96.18\n'
  [[ "$*" == *"qbittorrent-sonarr"* ]] && printf 'starr_network=192.168.96.17\n'
  [[ "$*" == *"qbittorrent-radarr"* ]] && printf 'starr_network=192.168.96.16\n'
fi
exit 0
EOF
  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat - >/dev/null
EOF
  cat > "$TMPBIN/iptables" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAIL_FIREWALL_READ:-0}" == 1 ]]; then printf 'Permission denied\n' >&2; exit 1; fi
if [[ "$*" == *' -C '* ]]; then
  printf 'Bad rule (does a matching rule exist in that chain?).\n' >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$TMPBIN/ip" "$TMPBIN/docker" "$TMPBIN/systemd-cat" "$TMPBIN/iptables"
}

@test "firewall read failure prevents routing success cache publication" {
  run env FAIL_FIREWALL_READ=1 bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'
  [ "$status" -ne 0 ]
  [ ! -s "$STATE_DIR/sonarr/docker-network-watcher.last" ]
}

@test "watcher refuses missing or failed kill-switch application" {
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; KILLSWITCH_SCRIPT="$STATE_DIR/missing"; reapply_killswitch'
  [ "$status" -ne 0 ]
  printf '#!/usr/bin/env bash\nexit 42\n' > "$TEST_TMPDIR/failing-firewall"
  chmod +x "$TEST_TMPDIR/failing-firewall"
  run env KILLSWITCH_SCRIPT="$TEST_TMPDIR/failing-firewall" bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_killswitch'
  [ "$status" -ne 0 ]
}

@test "IPv6 fallback owner receives ULA fallback and qBittorrent owner rules" {
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'

  [ "$status" -eq 0 ]
  grep -F -- '-6 rule add from fdca:6c19:2096::/64 to fdca:6c19:2096::/64 lookup main priority 108' "$IP_LOG"
  grep -F -- '-6 rule add from fdca:6c19:2096::17/128 lookup 51804 priority 114' "$IP_LOG"
  grep -F -- '-6 rule add from fdca:6c19:2096::/64 lookup 51804 priority 130' "$IP_LOG"
}

@test "IPv4 fallback owner receives subnet fallback and qBittorrent owner rules" {
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'

  [ "$status" -eq 0 ]
  grep -F -- 'rule add from 192.168.96.17/32 lookup 51804 priority 114' "$IP_LOG"
  grep -F -- 'rule add from 192.168.96.0/20 lookup 51804 priority 130' "$IP_LOG"
}

@test "IPv4 fallback non-owner receives only its qBittorrent owner rule" {
  run bash -c 'source ./proton-docker-network-watcher.sh radarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'

  [ "$status" -eq 0 ]
  grep -F -- 'rule add from 192.168.96.16/32 lookup 51803 priority 113' "$IP_LOG"
  ! grep -F -- 'rule add from 192.168.96.0/20 lookup 51803 priority 130' "$IP_LOG"
}

@test "non-owner receives only its qBittorrent IPv6 rule" {
  run bash -c 'source ./proton-docker-network-watcher.sh radarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'

  [ "$status" -eq 0 ]
  grep -F -- '-6 rule add from fdca:6c19:2096::16/128 lookup 51803 priority 113' "$IP_LOG"
  ! grep -F -- '-6 rule add from fdca:6c19:2096::/64 lookup 51803 priority 130' "$IP_LOG"
}

@test "reconciliation reasserts both defaults before source rules" {
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'
  [ "$status" -eq 0 ]
  grep -Fx -- 'route replace default dev pvsonarr table 51804' "$IP_LOG"
  grep -Fx -- '-6 route replace default dev pvsonarr table 51804' "$IP_LOG"
}

@test "failed default route prevents source mutation and success cache publication" {
  run env FAIL_DEFAULT_ROUTE=1 bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'
  [ "$status" -ne 0 ]
  run grep -F -- 'rule add' "$IP_LOG"
  [ "$status" -eq 1 ]
  [ ! -f "$STATE_DIR/sonarr/qbt-container-ip" ]
}

@test "missing or wrong-network snapshots cause no routing mutation" {
  for failure in DOCKER_INSPECT_FAIL WRONG_NETWORK NO_IPV6; do
    : > "$IP_LOG"
    run env "$failure=1" bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'
    [ "$status" -ne 0 ]
    [ ! -s "$IP_LOG" ]
  done
}

@test "a late IPv6 failure preserves the previous routing caches" {
  mkdir -p "$STATE_DIR/sonarr"
  printf 'previous\n' > "$STATE_DIR/sonarr/qbt-container-ip"
  run env FAIL_IPV6_RULE=1 bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64'
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE_DIR/sonarr/qbt-container-ip")" = previous ]
  [ ! -s "$STATE_DIR/sonarr/docker-network-watcher.last" ]
}

@test "all five instances reconcile isolated routes after out-of-band container address changes" {
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    case "$instance" in
      lidarr) subnet=2; host=15 ;;
      prowlarr) subnet=6; host=19 ;;
      radarr) subnet=3; host=16 ;;
      sonarr) subnet=4; host=17 ;;
      whisparr) subnet=5; host=18 ;;
    esac
    mkdir -p "$STATE_DIR/$instance"
    printf '192.168.96.%s\n' "$((host + 100))" > "$STATE_DIR/$instance/qbt-container-ip"
    printf 'fdca:6c19:2096::%s\n' "$((host + 100))" > "$STATE_DIR/$instance/qbt-container-ip6"
    : > "$IP_LOG"
    run bash -c 'source ./proton-docker-network-watcher.sh "$1"; reapply_routes_serialized 192.168.96.0/20 fdca:6c19:2096::/64' fixture "$instance"
    [ "$status" -eq 0 ]
    grep -Fx "rule del from 192.168.96.$((host + 100))/32 lookup $((51800 + subnet)) priority $((110 + subnet))" "$IP_LOG"
    grep -Fx -- "-6 rule del from fdca:6c19:2096::$((host + 100))/128 lookup $((51800 + subnet)) priority $((110 + subnet))" "$IP_LOG"
    grep -Fx "route replace default dev pv$instance table $((51800 + subnet))" "$IP_LOG"
    grep -Fx "rule add from 192.168.96.$host/32 lookup $((51800 + subnet)) priority $((110 + subnet))" "$IP_LOG"
    [ "$(cat "$STATE_DIR/$instance/qbt-container-ip")" = "192.168.96.$host" ]
    [ "$(cat "$STATE_DIR/$instance/qbt-container-ip6")" = "fdca:6c19:2096::$host" ]
  done
}

@test "watcher only reacts to its own qBittorrent container, not host-wide container churn" {
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "container:start:qbittorrent-sonarr"'
  [ "$status" -eq 0 ]
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "container:destroy:qbittorrent-sonarr"'
  [ "$status" -eq 0 ]
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "container:start:qbittorrent-radarr"'
  [ "$status" -ne 0 ]
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "container:create:some-unrelated-container"'
  [ "$status" -ne 0 ]
}

@test "watcher still reacts to the shared starr network, ignores unrelated networks" {
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "network:connect:starr_network"'
  [ "$status" -eq 0 ]
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "network:disconnect:starr_network"'
  [ "$status" -eq 0 ]
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "network:connect:some-other-network"'
  [ "$status" -ne 0 ]
}

@test "watcher ignores docker event actions outside the reconciliation set" {
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "container:die:qbittorrent-sonarr"'
  [ "$status" -ne 0 ]
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; event_is_relevant "network:remove:starr_network"'
  [ "$status" -ne 0 ]
}

@test "an instance with no QBT_CONTAINER_NAME configured falls back to the old unscoped behavior" {
  cat > "$PROTON_INSTANCE_ROOT/radarr/qbittorrent.env" <<EOF
QBITTORRENT_URL=http://127.0.0.1:8083
EOF
  run bash -c 'source ./proton-docker-network-watcher.sh radarr; event_is_relevant "container:start:anything-at-all"'
  [ "$status" -eq 0 ]
  run bash -c 'source ./proton-docker-network-watcher.sh radarr; event_is_relevant "network:connect:any-network"'
  [ "$status" -eq 0 ]
}
