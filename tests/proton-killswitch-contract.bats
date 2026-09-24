#!/usr/bin/env bats

load common-stubs

@test "both firewall backends refuse to touch the ruleset while the shared lock is held" {
  for backend in nft safe; do
    run bash -c '
      exec 8>"$KILLSWITCH_LOCK_FILE"
      flock -x 8
      PROTON_FIREWALL_LOCK_WAIT_SECONDS=0 DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton \
        bash "./proton-killswitch-$1.sh"
    ' _ "$backend"
    [ "$status" -ne 0 ]
    grep -F "Timed out waiting for kill-switch lock: $KILLSWITCH_LOCK_FILE" "$SYSTEMD_LOG"
  done
  [ ! -e "$NFT_LOG" ]
  [ ! -e "$NFT_STDIN" ]
  [ ! -e "$IPTABLES_LOG" ]
}

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
  export IPTABLES_LOG="$TEST_TMPDIR/iptables.log"
  export NFT_LOG="$TEST_TMPDIR/nft.log"
  export NFT_STDIN="$TEST_TMPDIR/nft.stdin"
  export SYSTEMD_LOG="$TEST_TMPDIR/systemd.log"
  export NFT_APPLY_ENTERED="$TEST_TMPDIR/nft-apply.entered"
  export NFT_APPLY_RELEASE="$TEST_TMPDIR/nft-apply.release"
  export STATE_DIR="$TEST_TMPDIR/state"
  export KILLSWITCH_LOCK_FILE="$TEST_TMPDIR/killswitch.lock"
  mkdir -p "$STATE_DIR"

  stub_systemd_cat '$SYSTEMD_LOG'

  cat > "$TMPBIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "show" && "$2" == "interfaces" ]]; then
  echo 'proton unrelated-wg'
fi
exit 0
EOF
  chmod +x "$TMPBIN/wg"

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  route)
    echo 'default via 192.168.50.1 dev eth0'
    ;;
  '-4 route show dev eth0')
    echo '192.168.50.0/24 proto kernel scope link src 192.168.50.10'
    ;;
  'link show proton')
    echo '3: proton: <POINTOPOINT,UP,LOWER_UP> mtu 1420'
    ;;
  *)
    ;;
esac
exit 0
EOF
  chmod +x "$TMPBIN/ip"

  cat > "$TMPBIN/iptables" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$IPTABLES_LOG"
exit 0
EOF
  chmod +x "$TMPBIN/iptables"

  cat > "$TMPBIN/iptables-save" <<'EOF'
#!/usr/bin/env bash
if [[ "${TEST_IPTABLES_READ_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "${TEST_IPTABLES_EXISTS:-0}" == 1 ]]; then
  if [[ "$*" == '-t filter' ]]; then
    printf '%s\n' ':PROTON_DOCKER_FORWARD - [0:0]' '-A FORWARD -j PROTON_DOCKER_FORWARD' '-A FORWARD -j PROTON_DOCKER_FORWARD'
  else
    printf '%s\n' ':PROTON_POSTROUTING - [0:0]' '-A POSTROUTING -j PROTON_POSTROUTING'
  fi
fi
exit 0
EOF
  cat > "$TMPBIN/iptables-restore" <<'EOF'
#!/usr/bin/env bash
printf 'restore %s\n' "$*" >> "$IPTABLES_LOG"
cat >> "$IPTABLES_LOG"
if [[ "${TEST_IPTABLES_TEST_FAIL:-0}" == 1 && "$*" == *--test* ]]; then exit 1; fi
if [[ "${TEST_IPTABLES_APPLY_FAIL:-0}" == 1 && "$*" != *--test* ]]; then exit 1; fi
EOF
  chmod +x "$TMPBIN/iptables-save" "$TMPBIN/iptables-restore"

  cat > "$TMPBIN/nft" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == '-f' ]]; then
  # A blocking apply signals entry, then holds until the test releases it.
  if [[ "${TEST_NFT_BLOCK_APPLY:-0}" == 1 ]]; then
    : > "$NFT_APPLY_ENTERED"
    for _ in {1..500}; do
      [[ -f "$NFT_APPLY_RELEASE" ]] && break
      /bin/sleep 0.02
    done
  fi
  cat > "$NFT_STDIN"
  exit "${TEST_NFT_APPLY_FAIL:-0}"
fi
printf '%s\n' "$*" >> "$NFT_LOG"
if [[ "$*" == 'list tables' ]]; then
  [[ "${TEST_NFT_READ_FAIL:-0}" == 0 ]] || exit 1
  if [[ "${TEST_NFT_PROTON_EXISTS:-0}" == 1 ]]; then printf 'table inet proton\n'; fi
  if [[ "${TEST_NFT_NAT_EXISTS:-0}" == 1 ]]; then printf 'table ip proton_nat\n'; fi
  exit 0
fi
if [[ "$*" == 'list table ip proton_nat' ]]; then
  printf 'chain postrouting {\n}\nchain prerouting {\n}\n'
  exit 0
fi
if [[ "$*" == '-a list chain ip proton_nat postrouting' ]]; then
  printf '%s\n' 'oifname "proton" masquerade comment "proton-wg-snat" # handle 10' \
    'oifname "proton" masquerade comment "other-owner" # handle 11'
  exit 0
fi
case "$1" in
  list)
    if [[ "$*" == "list table inet proton" && "${TEST_NFT_PROTON_EXISTS:-0}" == 1 ]]; then
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$TMPBIN/nft"
}

@test "iptables backend blocks Docker WAN bypass and direct LAN DNS" {
  run env DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-safe.sh
  [ "$status" -eq 0 ]
  grep -F 'PROTON_DOCKER_FORWARD -s 172.18.0.0/16 -o eth0 -d 192.168.50.0/24 -p tcp --dport 53 -j DROP' "$IPTABLES_LOG"
  grep -F 'PROTON_DOCKER_FORWARD -s 172.18.0.0/16 -o eth0 -d 192.168.50.0/24 -p udp --dport 53 -j DROP' "$IPTABLES_LOG"
  grep -F 'PROTON_DOCKER_FORWARD -s 172.18.0.0/16 -o proton -j ACCEPT' "$IPTABLES_LOG"
  grep -F 'PROTON_DOCKER_FORWARD -s 172.18.0.0/16 -j DROP' "$IPTABLES_LOG"
  ! grep -F -- '--dport 53 -j ACCEPT' "$IPTABLES_LOG"
}

@test "nft backend admits and masquerades every managed instance tunnel" {
  run env DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh
  [ "$status" -eq 0 ]
  for iface in proton pvlidarr pvprowlarr pvradarr pvsonarr pvwhisparr; do
    grep -F "oifname \"$iface\" ip saddr 172.18.0.0/16 accept" "$NFT_STDIN"
    grep -F "saddr 172.18.0.0/16 oifname \"$iface\" masquerade" "$NFT_STDIN"
  done
}

@test "nft backend emits Docker-only DNS drops and no host mark rules" {
  run env DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh
  [ "$status" -eq 0 ]
  grep -F 'udp dport 53 drop' "$NFT_STDIN"
  grep -F 'tcp dport 53 drop' "$NFT_STDIN"
  grep -F 'oifname "proton" ip saddr 172.18.0.0/16 accept' "$NFT_STDIN"
  run grep -E 'accept        (iifname|oifname)|meta mark set|dport 53 return' "$NFT_STDIN"
  [ "$status" -eq 1 ]
}

@test "nft backend replaces an existing filter table in one atomic batch" {
  run env TEST_NFT_PROTON_EXISTS=1 DOCKER_NETWORK_CIDR=172.18.0.0/16 \
    VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh

  [ "$status" -eq 0 ]
  grep -Fx 'delete table inet proton' "$NFT_STDIN"
  grep -F 'table inet proton {' "$NFT_STDIN"
  run grep -Fx 'delete table inet proton' "$NFT_LOG"
  [ "$status" -eq 1 ]
  [ -f "$KILLSWITCH_LOCK_FILE" ]
}

@test "nft backend holds the firewall lock across its ruleset apply" {
  TEST_NFT_BLOCK_APPLY=1 DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton \
    bash ./proton-killswitch-nft.sh &
  first=$!
  for _ in {1..500}; do
    [[ -f "$NFT_APPLY_ENTERED" ]] && break
    sleep 0.02
  done
  [ -f "$NFT_APPLY_ENTERED" ]
  rm -f "$NFT_APPLY_ENTERED"

  # A concurrent watcher apply must not reach nft while the first holds the lock.
  run env PROTON_FIREWALL_LOCK_WAIT_SECONDS=0 DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton \
    bash ./proton-killswitch-nft.sh
  [ "$status" -ne 0 ]
  grep -F "Timed out waiting for kill-switch lock: $KILLSWITCH_LOCK_FILE" "$SYSTEMD_LOG"
  [ ! -e "$NFT_STDIN" ]

  : > "$NFT_APPLY_RELEASE"
  wait "$first"

  run env DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh
  [ "$status" -eq 0 ]
}

@test "nft backend allows Docker IPv6 only through Proton and installs scoped NAT66" {
  run env \
    DOCKER_NETWORK_CIDR=172.18.0.0/16 \
    DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64 \
    VPN_INTERFACE=proton \
    bash ./proton-killswitch-nft.sh

  [ "$status" -eq 0 ]
  grep -F 'ip6 saddr fdca:6c19:2096::/64 ip6 daddr fdca:6c19:2096::/64 accept' "$NFT_STDIN"
  grep -F 'oifname "proton" ip6 saddr fdca:6c19:2096::/64 accept' "$NFT_STDIN"
  grep -F 'ip6 saddr fdca:6c19:2096::/64 drop' "$NFT_STDIN"
  grep -F 'ip6 daddr fdca:6c19:2096::/64 drop' "$NFT_STDIN"
  grep -F 'add rule ip6 proton_nat6 postrouting ip6 saddr fdca:6c19:2096::/64 oifname "proton" masquerade comment "proton-wg-snat6"' "$NFT_STDIN"
}

@test "iptables backend refuses Docker IPv6 before creating chains" {
  run env \
    DOCKER_NETWORK_CIDR=172.18.0.0/16 \
    DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64 \
    VPN_INTERFACE=proton \
    bash ./proton-killswitch-safe.sh

  [ "$status" -ne 0 ]
  grep -F 'Docker IPv6 requires KILLSWITCH_BACKEND=nftables' "$SYSTEMD_LOG"
  [ ! -s "$IPTABLES_LOG" ]
}

@test "iptables replacement covers all five interfaces without live chain flushes" {
  run env DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-safe.sh
  [ "$status" -eq 0 ]
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    grep -F -- "-o pv$instance -j ACCEPT" "$IPTABLES_LOG"
    grep -F -- "-o pv$instance -j MASQUERADE" "$IPTABLES_LOG"
  done
  grep -Fx '*filter' "$IPTABLES_LOG"
  grep -Fx '*nat' "$IPTABLES_LOG"
}

@test "both backends refuse an unknown Docker network scope" {
  for backend in safe nft; do
    for scope in '' ' , , '; do
      run env DOCKER_NETWORK_CIDR="$scope" bash "./proton-killswitch-$backend.sh"
      [ "$status" -ne 0 ]
    done
  done
  [ ! -s "$IPTABLES_LOG" ]
  [ ! -s "$NFT_LOG" ]
}

@test "nft NAT replacement preserves foreign rules and shares the filter transaction" {
  run env TEST_NFT_NAT_EXISTS=1 DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh
  [ "$status" -eq 0 ]
  grep -Fx 'delete rule ip proton_nat postrouting handle 10' "$NFT_STDIN"
  grep -F 'table inet proton {' "$NFT_STDIN"
  run grep -E 'handle 11|delete table ip proton_nat|flush table|prerouting' "$NFT_STDIN"
  [ "$status" -eq 1 ]
  run grep -E '^(add|delete) ' "$NFT_LOG"
  [ "$status" -eq 1 ]
}

@test "both backends exclude unrelated WireGuard interfaces" {
  for backend in safe nft; do
    run env DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash "./proton-killswitch-$backend.sh"
    [ "$status" -eq 0 ]
  done
  run grep -F 'unrelated-wg' "$IPTABLES_LOG" "$NFT_STDIN"
  [ "$status" -eq 1 ]
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    grep -F "oifname \"pv$instance\" ip saddr" "$NFT_STDIN"
  done
}

@test "nft read and apply failures propagate without a success report" {
  for failure in TEST_NFT_READ_FAIL TEST_NFT_APPLY_FAIL; do
    run env "$failure=1" DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh
    [ "$status" -ne 0 ]
  done
  run grep -F 'kill switch applied' "$SYSTEMD_LOG"
  [ "$status" -ne 0 ]
}

@test "reset retains shared NAT tables DNAT and unrelated rules" {
  run env TEST_NFT_NAT_EXISTS=1 TEST_NFT_PROTON_EXISTS=1 KILLSWITCH_BACKEND=nft bash ./proton-killswitch-reset.sh
  [ "$status" -eq 0 ]
  grep -Fx 'delete table inet proton' "$NFT_STDIN"
  grep -Fx 'delete rule ip proton_nat postrouting handle 10' "$NFT_STDIN"
  run grep -E 'handle 11|delete table ip|prerouting' "$NFT_STDIN"
  [ "$status" -eq 1 ]
  [ -f "$KILLSWITCH_LOCK_FILE" ]
}

@test "iptables reset removes owned jumps but never changes host policies" {
  run env TEST_IPTABLES_EXISTS=1 KILLSWITCH_BACKEND=iptables bash ./proton-killswitch-reset.sh
  [ "$status" -eq 0 ]
  grep -Fx -- '-X PROTON_DOCKER_FORWARD' "$IPTABLES_LOG"
  grep -Fx -- '-D POSTROUTING -j PROTON_POSTROUTING' "$IPTABLES_LOG"
  run grep -E -- '^-P |^:FORWARD |^:INPUT |^:OUTPUT ' "$IPTABLES_LOG"
  [ "$status" -eq 1 ]
}

@test "iptables refuses read parser and apply failures" {
  for failure in TEST_IPTABLES_READ_FAIL TEST_IPTABLES_TEST_FAIL TEST_IPTABLES_APPLY_FAIL; do
    run env "$failure=1" DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-safe.sh
    [ "$status" -ne 0 ]
  done
  run grep -F 'kill switch applied' "$SYSTEMD_LOG"
  [ "$status" -ne 0 ]
}

@test "iptables parser refusal prevents live apply" {
  run env TEST_IPTABLES_TEST_FAIL=1 DOCKER_NETWORK_CIDR=172.18.0.0/16 VPN_INTERFACE=proton bash ./proton-killswitch-safe.sh
  [ "$status" -ne 0 ]
  [ "$(grep -c '^restore ' "$IPTABLES_LOG")" -eq 1 ]
}

@test "real nft parser applies idempotently and preserves DNAT in an isolated namespace" {
  command -v unshare >/dev/null || skip "unshare unavailable"
  [[ -x /usr/sbin/nft ]] || skip "real nft unavailable"
  unshare --user --map-root-user --net true 2>/dev/null || skip "unprivileged network namespace unavailable"
  run unshare --user --map-root-user --net env PATH=/usr/sbin:/usr/bin:/sbin:/bin bash -c '
    set -euo pipefail
    systemd-cat() { cat >/dev/null; }
    export -f systemd-cat
    export LAN_IF=lo LAN_CIDR=127.0.0.0/8 VPN_INTERFACE=pvsonarr
    export DOCKER_NETWORK_CIDR=172.18.0.0/16 DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64
    nft -f - <<EOF
add table ip proton_nat
add chain ip proton_nat prerouting { type nat hook prerouting priority dstnat; policy accept; }
add chain ip proton_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }
add rule ip proton_nat prerouting tcp dport 40000 dnat to 172.18.0.20:40000 comment "qbt-dnat-radarr"
add rule ip proton_nat postrouting oifname "foreign-wg" masquerade comment "foreign-owner"
EOF
    bash ./proton-killswitch-nft.sh
    bash ./proton-killswitch-nft.sh
    children=()
    for instance in lidarr prowlarr radarr sonarr whisparr; do
      VPN_INTERFACE="pv$instance" bash ./proton-killswitch-nft.sh &
      children+=("$!")
    done
    for child in "${children[@]}"; do wait "$child"; done
    [[ "$(nft list chain ip proton_nat postrouting | grep -c "comment \"proton-wg-snat\"")" == 5 ]]
    [[ "$(nft list chain ip6 proton_nat6 postrouting | grep -c "comment \"proton-wg-snat6\"")" == 5 ]]
    nft list chain ip proton_nat prerouting | grep -F "qbt-dnat-radarr"
    nft list chain ip proton_nat postrouting | grep -F "foreign-owner"
    KILLSWITCH_BACKEND=nft bash ./proton-killswitch-reset.sh
    nft list chain ip proton_nat prerouting | grep -F "qbt-dnat-radarr"
    nft list chain ip proton_nat postrouting | grep -F "foreign-owner"
    [[ "$(nft list chain ip proton_nat postrouting | grep -c "proton-wg-snat" || true)" == 0 ]]
  '
  [ "$status" -eq 0 ]
}

@test "real iptables restore is repeatable and reset preserves host policy in an isolated namespace" {
  command -v unshare >/dev/null || skip "unshare unavailable"
  [[ -x /usr/sbin/iptables-restore ]] || skip "real iptables unavailable"
  unshare --user --map-root-user --net true 2>/dev/null || skip "unprivileged network namespace unavailable"
  run unshare --user --map-root-user --net env PATH=/usr/sbin:/usr/bin:/sbin:/bin bash -c '
    set -euo pipefail
    systemd-cat() { cat >/dev/null; }
    export -f systemd-cat
    export LAN_IF=lo LAN_CIDR=127.0.0.0/8 VPN_INTERFACE=pvsonarr
    export DOCKER_NETWORK_CIDR=172.18.0.0/16 DOCKER_NETWORK_CIDR6=""
    iptables -P FORWARD DROP
    iptables -N FOREIGN_CHAIN
    iptables -A FORWARD -j FOREIGN_CHAIN
    bash ./proton-killswitch-safe.sh
    bash ./proton-killswitch-safe.sh
    children=()
    for instance in lidarr prowlarr radarr sonarr whisparr; do
      VPN_INTERFACE="pv$instance" bash ./proton-killswitch-safe.sh &
      children+=("$!")
    done
    for child in "${children[@]}"; do wait "$child"; done
    [[ "$(iptables-save -t filter | grep -c "^-A FORWARD -j PROTON_DOCKER_FORWARD$")" == 1 ]]
    [[ "$(iptables-save -t nat | grep -c "^-A PROTON_POSTROUTING .* -j MASQUERADE$")" == 5 ]]
    source ./proton-instance-common.sh
    proton_iptables_rule ensure raw PREROUTING -i pvsonarr -d 172.18.0.0/16 -j ACCEPT
    proton_iptables_rule ensure raw PREROUTING -i pvsonarr -d 172.18.0.0/16 -j ACCEPT
    [[ "$(iptables-save -t raw | grep -c "^-A PREROUTING ")" == 1 ]]
    iptables -t raw -I PREROUTING 1 -d 172.18.0.20 -j DROP
    proton_iptables_rule ensure raw PREROUTING -i pvsonarr -d 172.18.0.0/16 -j ACCEPT
    iptables -t raw -S PREROUTING | grep "^-A " | head -n 1 | grep -F -- "-j ACCEPT"
    proton_iptables_rule remove raw PREROUTING -i pvsonarr -d 172.18.0.0/16 -j ACCEPT
    proton_iptables_rule remove raw PREROUTING -i pvsonarr -d 172.18.0.0/16 -j ACCEPT
    KILLSWITCH_BACKEND=iptables bash ./proton-killswitch-reset.sh
    iptables -S FORWARD | grep -Fx -- "-P FORWARD DROP"
    iptables -S FORWARD | grep -Fx -- "-A FORWARD -j FOREIGN_CHAIN"
  '
  [ "$status" -eq 0 ]
}

@test "firewall lock contention refuses reset before any nft inspection" {
  run bash -c '
    exec 8>"$KILLSWITCH_LOCK_FILE"
    flock -x 8
    PROTON_FIREWALL_LOCK_WAIT_SECONDS=0 KILLSWITCH_BACKEND=nft bash ./proton-killswitch-reset.sh
  '
  [ "$status" -ne 0 ]
  [ ! -s "$NFT_LOG" ]
  [ ! -e "$NFT_STDIN" ]
  run flock -n "$KILLSWITCH_LOCK_FILE" true
  [ "$status" -eq 0 ]
}
