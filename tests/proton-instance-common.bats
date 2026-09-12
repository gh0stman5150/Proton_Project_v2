#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  mkdir -p "$PROTON_INSTANCE_ROOT/sonarr" "$PROTON_INSTANCE_ROOT/prowlarr"

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

  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<'EOF'
WG_PROFILE=pvsonarr
VPN_INTERFACE=pvsonarr
WG_CONFIG=/etc/proton/instances/sonarr/wireguard.conf
WG_ADDRESS_SUBNET=4
EOF

  cat > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env" <<'EOF'
QBT_INSTANCE_NAME=sonarr
QBITTORRENT_URL=http://127.0.0.1:8083
QBT_PORT_ENV_FILE=/etc/proton/instances/sonarr/qbittorrent-port.env
EOF

  cat > "$PROTON_INSTANCE_ROOT/prowlarr/proton.env" <<'EOF'
WG_PROFILE=pvprowl
VPN_INTERFACE=pvprowl
WG_CONFIG=/etc/proton/instances/prowlarr/wireguard.conf
WG_ADDRESS_SUBNET=6
EOF

  cat > "$PROTON_INSTANCE_ROOT/prowlarr/qbittorrent.env" <<'EOF'
QBT_INSTANCE_NAME=prowlarr
QBITTORRENT_URL=http://127.0.0.1:8085
QBT_PORT_ENV_FILE=/etc/proton/instances/prowlarr/qbittorrent-port.env
EOF
}

@test "instance loader rejects missing instance name" {
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init "" 2>&1'

  [ "$status" -ne 0 ]
  [[ "$output" == *"Instance name is required"* ]]
}

@test "instance loader rejects unsafe or unsupported instance name" {
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init "../sonarr" 2>&1'

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsafe instance name"* ]]

  run bash -c 'source ./proton-instance-common.sh; proton_instance_init readarr 2>&1'

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported instance"* ]]
}

@test "instance loader rebases legacy global paths to the selected instance" {
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init sonarr; printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n" "$STATE_DIR" "$STATE_FILE" "$CACHE_FILE" "$RECOVERY_LOCK_FILE" "$SERVER_SELECTION_FILE" "$DOCKER_CONFIG_DIR" "$QBITTORRENT_URL"'

  [ "$status" -eq 0 ]
  [[ "$output" == *"/run/proton/sonarr"* ]]
  [[ "$output" == *"/run/proton/sonarr/proton-port.state"* ]]
  [[ "$output" == *"/run/proton/sonarr/qbt-port.cache"* ]]
  [[ "$output" == *"/run/proton/sonarr/recovery.lock"* ]]
  [[ "$output" == *"/run/proton/sonarr/current-server.env"* ]]
  [[ "$output" == *"/run/proton/sonarr/docker-config"* ]]
  [[ "$output" == *"http://127.0.0.1:8083"* ]]
}

@test "instance loader accepts prowlarr manual-download instance" {
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init prowlarr; printf "%s\n%s\n%s\n%s\n" "$INSTANCE" "$VPN_INTERFACE" "$STATE_DIR" "$QBITTORRENT_URL"'

  [ "$status" -eq 0 ]
  [[ "$output" == *"prowlarr"* ]]
  [[ "$output" == *"pvprowl"* ]]
  [[ "$output" == *"/run/proton/prowlarr"* ]]
  [[ "$output" == *"http://127.0.0.1:8085"* ]]
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
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init sonarr; printf "%s\n%s\n%s\n%s\n%s\n" "$WG_TUNNEL_ADDRESS" "$WG_TUNNEL_DNS" "$NATPMP_GATEWAY" "$VPN_TABLE" "$QBT_VPN_RULE_PRIORITY"'

  [ "$status" -eq 0 ]
  [[ "$output" == *"10.4.0.2/32"* ]]
  [[ "$output" == *"10.4.0.1"* ]]
  [[ "$output" == *"51804"* ]]
  [[ "$output" == *"114"* ]]

  run bash -c 'source ./proton-instance-common.sh; proton_instance_init prowlarr; printf "%s\n%s\n%s\n%s\n%s\n" "$WG_TUNNEL_ADDRESS" "$WG_TUNNEL_DNS" "$NATPMP_GATEWAY" "$VPN_TABLE" "$QBT_VPN_RULE_PRIORITY"'

  [ "$status" -eq 0 ]
  [[ "$output" == *"10.6.0.2/32"* ]]
  [[ "$output" == *"10.6.0.1"* ]]
  [[ "$output" == *"51806"* ]]
  [[ "$output" == *"116"* ]]
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
  run bash -c 'source ./proton-instance-common.sh; proton_lease_read; printf "%s\n" "$PROTON_LEASE_EXPIRES_AT"'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "$expiry" ]
}
