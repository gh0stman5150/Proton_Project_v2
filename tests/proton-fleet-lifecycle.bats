#!/usr/bin/env bats

load common-stubs

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/common.env"
  export SYNC_SCRIPT="$TEST_TMPDIR/sync"
  export FLEET_LOG="$TEST_TMPDIR/fleet.log"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export HEALTH_TRIES=1 HEALTH_DELAY=0 PORT_TRIES=1 PORT_DELAY=0 START_TIMEOUT=5
  mkdir -p "$TEST_TMPDIR/bin"
  : > "$PROTON_COMMON_ENV"
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    mkdir -p "$PROTON_INSTANCE_ROOT/$instance" "$TEST_TMPDIR/state/$instance"
    printf 'STATE_DIR=%s/state/%s\nSTATE_FILE=%s/state/%s/proton-port.state\nWG_ADDRESS_SUBNET=4\n' "$TEST_TMPDIR" "$instance" "$TEST_TMPDIR" "$instance" > "$PROTON_INSTANCE_ROOT/$instance/proton.env"
    append_manifest_routing "$instance" "$PROTON_INSTANCE_ROOT/$instance/proton.env"
    printf 'QBT_CONTAINER_NAME=qbittorrent-%s\n' "$instance" > "$PROTON_INSTANCE_ROOT/$instance/qbittorrent.env"
    printf 'generation-%s\n' "$instance" > "$TEST_TMPDIR/state/$instance/tunnel-generation"
    cat > "$TEST_TMPDIR/state/$instance/proton-port.state" <<EOF
CURRENT_PORT=45678
CURRENT_IP=10.4.0.2
LEASE_EXPIRES_AT=$(( $(date +%s) + 600 ))
LEASE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LEASE_GENERATION=generation-$instance
EOF
  done
  cat > "$SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
source "$QBITTORRENT_ENV_FILE"
printf '%s|%s|%s\n' "$1" "$QBT_CONTAINER_NAME" "$STATE_FILE" >> "$FLEET_LOG"
exit "${TEST_SYNC_FAILURE:-0}"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/systemctl"
  printf '#!/usr/bin/env bash\nprintf "healthy\\n"\n' > "$TEST_TMPDIR/bin/docker"
  chmod +x "$SYNC_SCRIPT" "$TEST_TMPDIR/bin/"*
}

@test "bootstrap loads independent configuration and lease paths for all five instances" {
  run bash -c '
    source ./proton-instance-common.sh
    source <(sed -n "/^recreate_instance()/,/^)/p" tools/recreate-qbittorrent-fleet.sh)
    for instance in lidarr prowlarr radarr sonarr whisparr; do
      recreate_instance "$instance" || exit 1
    done
  '
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$FLEET_LOG")" -eq 5 ]
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    grep -Fx "$instance|qbittorrent-$instance|$TEST_TMPDIR/state/$instance/proton-port.state" "$FLEET_LOG"
  done
}

@test "bootstrap propagates sync failure despite a healthy old container" {
  run env TEST_SYNC_FAILURE=17 bash -c '
    source ./proton-instance-common.sh
    source <(sed -n "/^recreate_instance()/,/^)/p" tools/recreate-qbittorrent-fleet.sh)
    recreate_instance lidarr || exit 1
    recreate_instance radarr
  '
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$FLEET_LOG")" -eq 1 ]
}

@test "bootstrap rejects expired leases before invoking sync" {
  sed -i 's/^LEASE_EXPIRES_AT=.*/LEASE_EXPIRES_AT=1/' "$TEST_TMPDIR/state/lidarr/proton-port.state"
  run bash -c '
    source ./proton-instance-common.sh
    source <(sed -n "/^recreate_instance()/,/^)/p" tools/recreate-qbittorrent-fleet.sh)
    recreate_instance lidarr || exit 1
  '
  [ "$status" -ne 0 ]
  [ ! -f "$FLEET_LOG" ]
}

@test "verifier help does not load runtime helper files" {
  run env QBT_COMMON_SCRIPT="$TEST_TMPDIR/missing-helper" PROTON_INSTANCE_COMMON_SCRIPT="$TEST_TMPDIR/missing-instance-helper" bash tools/verify-qbittorrent-fleet.sh --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage: verify-qbittorrent-fleet.sh'* ]]
}

@test "verifier requires a Docker executable despite its sourced wrapper function" {
  local bash_bin dirname_bin
  bash_bin="$(command -v bash)"
  dirname_bin="$(command -v dirname)"
  mkdir -p "$TEST_TMPDIR/minimal-bin"
  ln -s "$dirname_bin" "$TEST_TMPDIR/minimal-bin/dirname"
  run env PATH="$TEST_TMPDIR/minimal-bin" "$bash_bin" tools/verify-qbittorrent-fleet.sh --static-only
  [ "$status" -ne 0 ]
  [[ "$output" == *'Docker Compose is required for verification'* ]]
}
@test "verifier reads each wrapper's bind IP and Web UI port from the named manifest columns" {
  local compose_root="$TEST_TMPDIR/compose" instance webui bind_ip
  mkdir -p "$compose_root/qbittorrent-common"
  while IFS=$'\t' read -r instance webui bind_ip; do
    mkdir -p "$compose_root/qbittorrent-$instance"
    printf 'QBT_HOST_BIND_IP=%s\n' "$bind_ip" > "$compose_root/qbittorrent-$instance/.env"
    printf '  WEBUI_PORT: "%s"\n' "$webui" > "$compose_root/qbittorrent-$instance/docker-compose.yml"
  done < <(awk -F '\t' '
    NR == 1 { sub(/^# /, ""); for (i = 1; i <= NF; i++) column[$i] = i; next }
    { print $1 "\t" $column["webui_port"] "\t" $column["bind_ip"] }
  ' qbittorrent-instances.tsv)
  run env QBT_COMPOSE_ROOT="$compose_root" QBT_INSTANCE_MANIFEST="$PWD/qbittorrent-instances.tsv" bash tools/verify-qbittorrent-fleet.sh --static-only
  [[ "$output" == *'FAIL: '* ]]
  [[ "$output" != *'expected QBT_HOST_BIND_IP='* ]]
  [[ "$output" != *'Web UI port must be'* ]]
}

@test "installed verifier compares against the canonical checkout and never skips source parity" {
  local installed="$TEST_TMPDIR/usr-local-bin/proton" common="$TEST_TMPDIR/qbittorrent-common"
  mkdir -p "$installed" "$common" "$TEST_TMPDIR/compose"
  cp tools/verify-qbittorrent-fleet.sh "$installed/proton-qbt-fleet-verify.sh"
  cp proton-qbittorrent-common.sh proton-instance-common.sh "$installed/"
  TMPBIN="$TEST_TMPDIR/bin" stub_command docker 'exit 0'
  cp qbittorrent-instances.tsv "$common/"
  printf 'drifted: true\n' > "$common/docker-compose.common.yml"
  verify() {
    run env QBT_COMMON_DIR="$common" QBT_COMPOSE_ROOT="$TEST_TMPDIR/compose" "$@" \
      bash "$installed/proton-qbt-fleet-verify.sh" --static-only
  }

  # Outside the checkout, the default source is the canonical checkout.
  verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"/usr/local/bin/proton_project/qbittorrent-compose.common.yml"* ]]

  # An unreadable source is a failure, not a skipped check.
  verify PROTON_PROJECT_DIR="$TEST_TMPDIR/no-checkout"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL: repository Compose policy is unreadable: $TEST_TMPDIR/no-checkout/qbittorrent-compose.common.yml"* ]]
  [[ "$output" == *"FAIL: repository instance manifest is unreadable: $TEST_TMPDIR/no-checkout/qbittorrent-instances.tsv"* ]]

  # With a readable checkout, drift is reported and a matching manifest passes.
  verify PROTON_PROJECT_DIR="$PWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL: $common/docker-compose.common.yml differs from $PWD/qbittorrent-compose.common.yml"* ]]
  [[ "$output" == *"PASS: deployed instance manifest matches repository source"* ]]
}
