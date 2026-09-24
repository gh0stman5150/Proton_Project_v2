#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  mkdir -p "$PROTON_INSTANCE_ROOT"

  # Legacy global paths and a stale VPN_TABLE that per-instance values override.
  cat > "$PROTON_COMMON_ENV" <<'EOF'
STATE_DIR=/run/proton
STATE_FILE=/run/proton/proton-port.state
CACHE_FILE=/run/proton/qbt-port.cache
RECOVERY_LOCK_FILE=/run/proton/recovery.lock
SERVER_SELECTION_FILE=/run/proton/current-server.env
SERVER_RESELECT_FILE=/run/proton/reselect-server.flag
DOCKER_NETWORK_CIDR_STATE_FILE=/run/proton/docker-network-cidr
DOCKER_CONFIG_DIR=/run/proton/docker-config
QBITTORRENT_ENV_FILE=/etc/proton/qbittorrent.env
VPN_TABLE=51820
EOF

  local instance
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    create_instance "$instance"
  done
}

# manifest_value INSTANCE COLUMN: a qbittorrent-instances.tsv field by header name.
manifest_value() {
  awk -F '\t' -v instance="$1" -v column="$2" '
    NR == 1 { sub(/^# /, ""); for (i = 1; i <= NF; i++) if ($i == column) field = i; next }
    $1 == instance { print $field; exit }
  ' qbittorrent-instances.tsv
}

# Instance configs shaped like the installer's examples, from the manifest row.
create_instance() {
  local instance="$1"
  local instance_dir="$PROTON_INSTANCE_ROOT/$instance"
  local vpn_if
  vpn_if="$(manifest_value "$instance" vpn_interface)"

  mkdir -p "$instance_dir"
  cat > "$instance_dir/proton.env" <<EOF
INSTANCE_NAME=$instance
WG_PROFILE=$vpn_if
VPN_INTERFACE=$vpn_if
WG_CONFIG=/etc/proton/instances/$instance/wireguard.conf
WG_ADDRESS_SUBNET=$(manifest_value "$instance" address_subnet)
EOF

  cat > "$instance_dir/qbittorrent.env" <<EOF
QBT_INSTANCE_NAME=$instance
QBITTORRENT_URL=http://127.0.0.1:$(manifest_value "$instance" webui_port)
QBT_CONTAINER_NAME=qbittorrent-$instance
QBT_PORT_ENV_FILE=/etc/proton/instances/$instance/qbittorrent-port.env
EOF
}

write_wireguard_config() {
  cat > "$PROTON_INSTANCE_ROOT/$1/wireguard.conf" <<EOF
[Interface]
PrivateKey = test-private-key-$1
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = test-public-key
AllowedIPs = 0.0.0.0/0
Endpoint = $2
EOF
}

@test "instance loader accepts the five managed names and rejects everything else" {
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    run bash -c 'source ./proton-instance-common.sh; proton_validate_instance_name "$1"' _ "$instance"
    [ "$status" -eq 0 ]
  done

  run bash -c 'source ./proton-instance-common.sh; proton_instance_init "" 2>&1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Instance name is required"* ]]

  for instance in "../sonarr" "sonarr.prod"; do
    run bash -c 'source ./proton-instance-common.sh; proton_instance_init "$1" 2>&1' _ "$instance"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unsafe instance name"* ]]
  done

  run bash -c 'source ./proton-instance-common.sh; proton_instance_init readarr 2>&1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported instance"* ]]
  [[ "$output" == *"Allowed instances: lidarr,radarr,sonarr,whisparr,prowlarr"* ]]
}

@test "each managed instance loads only its own config" {
  # Anchor the manifest lookup so an empty field cannot pass trivially.
  [ "$(manifest_value prowlarr webui_port)" = 8082 ]
  [ "$(manifest_value sonarr vpn_interface)" = pvsonarr ]
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    run bash -c 'source ./proton-instance-common.sh; proton_instance_init "$1"; printf "%s\n" "$INSTANCE" "$VPN_INTERFACE" "$STATE_DIR" "$QBITTORRENT_URL"' _ "$instance"
    [ "$status" -eq 0 ]
    [ "$output" = "$instance"$'\n'"$(manifest_value "$instance" vpn_interface)"$'\n'"/run/proton/$instance"$'\n'"http://127.0.0.1:$(manifest_value "$instance" webui_port)" ]
  done
}

@test "instance loader rebases legacy global paths to the selected instance" {
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init sonarr; printf "%s\n" "$STATE_DIR" "$STATE_FILE" "$CACHE_FILE" "$RECOVERY_LOCK_FILE" "$SERVER_SELECTION_FILE" "$DOCKER_CONFIG_DIR" "$QBT_SYNC_LOCK_FILE"'

  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' /run/proton/sonarr /run/proton/sonarr/proton-port.state /run/proton/sonarr/qbt-port.cache \
    /run/proton/sonarr/recovery.lock /run/proton/sonarr/current-server.env /run/proton/sonarr/docker-config \
    /run/proton/sonarr/qbt-sync.lock)" ]
}

@test "a shared Proton server endpoint still keeps instance tunnels isolated" {
  for instance in lidarr radarr; do
    write_wireguard_config "$instance" "203.0.113.10:51820"
    run bash -c 'source ./proton-instance-common.sh; proton_instance_init "$1"; printf "%s\n" "$WG_CONFIG" "$VPN_INTERFACE" "$STATE_FILE" "$QBT_PORT_ENV_FILE"' _ "$instance"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' "/etc/proton/instances/$instance/wireguard.conf" "pv$instance" \
      "/run/proton/$instance/proton-port.state" "/etc/proton/instances/$instance/qbittorrent-port.env")" ]
  done
}

@test "missing required instance env files fail safely" {
  rm -f "$PROTON_INSTANCE_ROOT/radarr/proton.env"
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init radarr 2>&1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Instance Proton env not found"* ]]

  rm -f "$PROTON_INSTANCE_ROOT/lidarr/qbittorrent.env"
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init lidarr 2>&1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Instance qBittorrent env not found"* ]]
}

@test "instance loader propagates failed env sourcing even in a conditional caller" {
  for env_file in "$PROTON_COMMON_ENV" "$PROTON_INSTANCE_ROOT/sonarr/proton.env" "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env"; do
    cp "$env_file" "$TEST_TMPDIR/env-before"
    printf '\nreturn 17\n' >> "$env_file"
    run bash -c 'source ./proton-instance-common.sh; if proton_instance_init sonarr; then exit 0; else exit 1; fi'
    [ "$status" -eq 1 ]
    cp "$TEST_TMPDIR/env-before" "$env_file"
  done
}

@test "instance state directory override precedes derived lease and lock defaults" {
  printf '\nSTATE_DIR=%s/custom-state\n' "$TEST_TMPDIR" >> "$PROTON_INSTANCE_ROOT/sonarr/proton.env"
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init sonarr; printf "%s\n" "$STATE_FILE" "$CACHE_FILE" "$QBT_SYNC_LOCK_FILE"'
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_TMPDIR/custom-state/proton-port.state"$'\n'"$TEST_TMPDIR/custom-state/qbt-port.cache"$'\n'"$TEST_TMPDIR/custom-state/qbt-sync.lock" ]
}

@test "instance loader derives a distinct tunnel subnet, DNS, and NAT-PMP gateway" {
  [ "$(manifest_value sonarr address_subnet)" = 4 ]
  [ "$(manifest_value sonarr vpn_table)" = 51804 ]
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    subnet="$(manifest_value "$instance" address_subnet)"
    run bash -c 'source ./proton-instance-common.sh; proton_instance_init "$1"; printf "%s\n" "$WG_TUNNEL_ADDRESS" "$WG_TUNNEL_DNS" "$NATPMP_GATEWAY" "$VPN_TABLE" "$QBT_VPN_RULE_PRIORITY"' _ "$instance"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' "10.$subnet.0.2/32" "10.$subnet.0.1" "10.$subnet.0.1" \
      "$(manifest_value "$instance" vpn_table)" "$(manifest_value "$instance" qbt_rule_priority)")" ]
  done
}

@test "instance loader rejects an out-of-range tunnel subnet" {
  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<'EOF'
WG_PROFILE=pvsonarr
VPN_INTERFACE=pvsonarr
WG_CONFIG=/etc/proton/instances/sonarr/wireguard.conf
WG_ADDRESS_SUBNET=999
EOF

  run bash -c 'source ./proton-instance-common.sh; proton_instance_init sonarr 2>&1'

  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid WG_ADDRESS_SUBNET"* ]]
}

@test "lease reader refuses missing truncated expired and previous-generation state" {
  export STATE_FILE="$TEST_TMPDIR/proton-port.state"
  printf 'generation-a\n' > "$TEST_TMPDIR/tunnel-generation"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -ne 0 ]
  printf 'CURRENT_PORT=45678\n' > "$STATE_FILE"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -ne 0 ]
  cat > "$STATE_FILE" <<EOF
CURRENT_PORT=45678
CURRENT_IP=10.4.0.2
LEASE_EXPIRES_AT=$(( $(date +%s) + 60 ))
LEASE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LEASE_GENERATION=generation-a
EOF
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -eq 0 ]
  [ "$output" = 45678 ]
  sed -i 's/^LEASE_EXPIRES_AT=.*/LEASE_EXPIRES_AT=1/' "$STATE_FILE"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -ne 0 ]
  sed -i "s/^LEASE_EXPIRES_AT=.*/LEASE_EXPIRES_AT=$(( $(date +%s) + 60 ))/" "$STATE_FILE"
  printf 'generation-b\n' > "$TEST_TMPDIR/tunnel-generation"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -ne 0 ]
}

@test "lease reader validates the address boot and unique fields and returns the validated expiry" {
  export STATE_FILE="$TEST_TMPDIR/proton-port.state"
  printf 'generation-a\n' > "$TEST_TMPDIR/tunnel-generation"
  expiry="$(( $(date +%s) + 60 ))"
  cat > "$TEST_TMPDIR/valid.state" <<EOF
CURRENT_PORT=45678
CURRENT_IP=10.4.0.2
LEASE_EXPIRES_AT=$expiry
LEASE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LEASE_GENERATION=generation-a
EOF
  for invalid in 'CURRENT_IP=999.4.0.2' 'CURRENT_IP=10.04.0.2' 'LEASE_BOOT_ID=other-boot'; do
    cp "$TEST_TMPDIR/valid.state" "$STATE_FILE"
    sed -i "s/^${invalid%%=*}=.*/$invalid/" "$STATE_FILE"
    run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
    [ "$status" -ne 0 ]
  done
  cp "$TEST_TMPDIR/valid.state" "$STATE_FILE"
  printf 'CURRENT_PORT=45678\n' >> "$STATE_FILE"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -ne 0 ]
  cp "$TEST_TMPDIR/valid.state" "$STATE_FILE"
  run env WG_TUNNEL_ADDRESS=10.3.0.2/32 bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -ne 0 ]
  sed -i 's/^LEASE_BOOT_ID=.*/LEASE_BOOT_ID=inherited-boot/' "$STATE_FILE"
  run env PROTON_BOOT_ID=inherited-boot bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -ne 0 ]
  cp "$TEST_TMPDIR/valid.state" "$STATE_FILE"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read; printf "%s\n" "$PROTON_LEASE_EXPIRES_AT"'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "$expiry" ]
}

@test "lease reader rejects unknown duplicate and malformed trailing fields" {
  export STATE_FILE="$TEST_TMPDIR/proton-port.state"
  printf 'generation-a\n' > "$TEST_TMPDIR/tunnel-generation"
  cat > "$TEST_TMPDIR/valid.state" <<EOF
CURRENT_PORT=45678
CURRENT_IP=10.4.0.2
LEASE_EXPIRES_AT=$(( $(date +%s) + 60 ))
LEASE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LEASE_GENERATION=generation-a
PORT_CHANGED_AT=$(date +%s)
EOF
  for trailing in 'UNKNOWN=value' 'CURRENT_PORT=45679' 'PORT_CHANGED_AT=1' 'malformed'; do
    cp "$TEST_TMPDIR/valid.state" "$STATE_FILE"
    printf '%s' "$trailing" >> "$STATE_FILE"
    run bash -c 'source ./proton-instance-common.sh; PROTON_LEASE_EXPIRES_AT=stale; if proton_lease_read; then exit 0; else test -z "$PROTON_LEASE_EXPIRES_AT" || exit 2; exit 1; fi'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
  cp "$TEST_TMPDIR/valid.state" "$STATE_FILE"
  sed -i 's/^PORT_CHANGED_AT=.*/PORT_CHANGED_AT=invalid/' "$STATE_FILE"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -ne 0 ]
  cp "$TEST_TMPDIR/valid.state" "$STATE_FILE"
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read'
  [ "$status" -eq 0 ]
  [ "$output" = 45678 ]
}

@test "shared rule-source normalization validates addresses and prefixes" {
  run bash -c '
    source ./proton-instance-common.sh
    normalize_ipv4_rule_source " 192.168.96.4 "
    normalize_ipv4_rule_source 192.168.96.0/20
    normalize_ipv6_rule_source fd00::4/64
    for bad in "" 256.1.1.1 192.168.96.4/33 192.168.96.4/x not-an-ip; do
      if normalize_ipv4_rule_source "$bad"; then echo "accepted $bad"; fi
    done
    if normalize_ipv6_rule_source 192.168.96.4; then echo "accepted IPv4 as IPv6"; fi
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'192.168.96.4/32\n192.168.96.0/20\nfd00::4/128' ]
}

@test "shared container address lookup uses only the named network when one is set" {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${DOCKER_ACTIVE:-1}" == 1 ]]
EOF
  cat > "$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *GlobalIPv6Address* ]]; then
  printf 'other_network=fd00::9\nstarr_network=fd00::4\n'
else
  printf 'other_network=172.18.0.9\nstarr_network=192.168.96.4\n'
fi
EOF
  chmod +x "$TEST_TMPDIR/bin/systemctl" "$TEST_TMPDIR/bin/docker"

  run env PATH="$TEST_TMPDIR/bin:$PATH" bash -c '
    source ./proton-instance-common.sh
    QBT_CONTAINER_NAME=qbittorrent-sonarr
    QBT_NETWORK_NAME=starr_network
    resolve_qbt_container_ip
    resolve_qbt_container_ipv6
    QBT_NETWORK_NAME=missing_network
    if resolve_qbt_container_ip; then echo "fell back to another network"; fi
    QBT_NETWORK_NAME=
    resolve_qbt_container_ip
    QBT_NETWORK_NAME=starr_network
    if DOCKER_ACTIVE=0 resolve_qbt_container_ip; then echo "resolved without Docker"; fi
    QBT_CONTAINER_NAME=
    if resolve_qbt_container_ip; then echo "resolved without a container"; fi
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'192.168.96.4\nfd00::4\n172.18.0.9' ]
}

@test "shared wg-quick runner applies the caller timeout, secures runtime configs, and filters known noise" {
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/runtime"
  touch "$TEST_TMPDIR/runtime/pvsonarr.conf"
  chmod 0644 "$TEST_TMPDIR/runtime/pvsonarr.conf"
  chmod 0755 "$TEST_TMPDIR/runtime"
  cat > "$TEST_TMPDIR/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TIMEOUT_LOG"
shift 2
"$@"
EOF
  cat > "$TEST_TMPDIR/bin/wg-quick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "stat: cannot read table of mounted file systems: Permission denied" >&2
printf '%s\n' "Warning: \`$2' is world accessible" >&2
printf '%s\n' "real error" >&2
exit 3
EOF
  chmod +x "$TEST_TMPDIR/bin/timeout" "$TEST_TMPDIR/bin/wg-quick"

  run env PATH="$TEST_TMPDIR/bin:$PATH" TIMEOUT_LOG="$TEST_TMPDIR/timeout.log" bash -c '
    source ./proton-instance-common.sh
    WG_RUNTIME_DIR="$1"
    WG_QUICK_TIMEOUT_SECONDS=90
    run_wg_quick down "$1/pvsonarr.conf" 2>&1
  ' _ "$TEST_TMPDIR/runtime"

  [ "$status" -eq 3 ]
  [ "$output" = "real error" ]
  [ "$(cat "$TEST_TMPDIR/timeout.log")" = "--kill-after=5s 90s wg-quick down $TEST_TMPDIR/runtime/pvsonarr.conf" ]
  [ "$(stat -c %a "$TEST_TMPDIR/runtime")" = 700 ]
  [ "$(stat -c %a "$TEST_TMPDIR/runtime/pvsonarr.conf")" = 600 ]
}
