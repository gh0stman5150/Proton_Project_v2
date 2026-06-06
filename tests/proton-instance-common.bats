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
EOF

  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<'EOF'
WG_PROFILE=pvsonarr
VPN_INTERFACE=pvsonarr
WG_CONFIG=/etc/proton/instances/sonarr/wireguard.conf
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
