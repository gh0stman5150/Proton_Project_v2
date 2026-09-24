#!/usr/bin/env bats

@test "installer bundle includes instance helper and templated units" {
  grep -Fq 'proton-instance-common.sh' install-proton-systemd.sh
  grep -Fq 'proton-wg@.service' install-proton-systemd.sh
  grep -Fq 'proton-port-forward@.service' install-proton-systemd.sh
  grep -Fq 'proton-healthcheck@.service' install-proton-systemd.sh
  grep -Fq 'proton-docker-watch@.service' install-proton-systemd.sh
  grep -Fq 'proton-qbt-allocate@.service' install-proton-systemd.sh
  grep -Fq 'proton-qbt-allocate-and-sync.sh' install-proton-systemd.sh
  grep -Fq 'qbittorrent-compose.common.yml' install-proton-systemd.sh
  grep -Fq 'qbittorrent-instances.tsv' install-proton-systemd.sh
  grep -Fq 'QBT_COMPOSE_COMMON_DIR="/opt/qbittorrent-common"' install-proton-systemd.sh
  grep -Fq 'proton-qbt-fleet-verify.sh' install-proton-systemd.sh
  grep -Fq 'proton-qbt-fleet-reconcile.sh' install-proton-systemd.sh
  grep -Fq 'proton-qbt-fleet-recreate.sh' install-proton-systemd.sh
  grep -Fq 'tools/recreate-qbittorrent-fleet.sh' install-proton-systemd.sh
  grep -Fq 'nas-network-online.sh' install-proton-systemd.sh
  grep -Fq 'nas-network-online.service' install-proton-systemd.sh
  grep -Fq 'nas-network-online.mount.conf' install-proton-systemd.sh
  grep -Fq 'mnt-data.mount' install-proton-systemd.sh
  grep -Fq 'mnt-plex.mount' install-proton-systemd.sh
  grep -Fq 'docker-proton-tunnels.conf' install-proton-systemd.sh
  grep -Fq 'docker-proton-stop-timeout.conf' install-proton-systemd.sh
  grep -Fq '${SYSTEMD_DIR}/docker.service.d' install-proton-systemd.sh
  grep -Fq 'install_docker_tunnel_ordering' install-proton-systemd.sh
}

@test "installer retires obsolete singleton services" {
  grep -Fq 'LEGACY_SINGLETON_SERVICES=(' install-proton-systemd.sh
  grep -Fq 'proton-wg.service' install-proton-systemd.sh
  grep -Fq 'proton-port-forward.service' install-proton-systemd.sh
  grep -Fq 'proton-healthcheck.service' install-proton-systemd.sh
  grep -Fq 'systemctl disable --now "${LEGACY_SINGLETON_SERVICES[@]}"' install-proton-systemd.sh
  grep -Fq 'systemctl reset-failed "${LEGACY_SINGLETON_SERVICES[@]}"' install-proton-systemd.sh
}

# Runs the installer's instance setup against a temporary /etc/proton with
# chown and root-owned install stubbed out.
run_install_instance_examples() {
  run bash -c '
    set -euo pipefail
    SCRIPT_DIR="$PWD"
    ETC_PROTON_DIR="$1"
    INSTANCE_MANIFEST_SOURCE=qbittorrent-instances.tsv
    for fn in load_instance_manifest instance_manifest_value instance_webui_port instance_vpn_interface \
      instance_address_subnet instance_vpn_table instance_qbt_rule_priority normalize_text_file \
      upsert_instance_env_value normalize_instance_qbittorrent_port_env install_instance_examples; do
      eval "$(sed -n "/^${fn}() {/,/^}/p" install-proton-systemd.sh)"
    done
    chown() { :; }
    install_normalized_file() {
      normalize_text_file "$1" "$2.tmp"
      install -m "$3" "$2.tmp" "$2"
      rm -f "$2.tmp"
    }
    log() { printf "%s\n" "$*"; }
    load_instance_manifest
    install_instance_examples
  ' _ "$ETC_FIXTURE"
}

@test "installer preserves real configs while reconciling contract keys and port artifacts" {
  ETC_FIXTURE="$BATS_TEST_TMPDIR/etc-proton"
  sonarr="$ETC_FIXTURE/instances/sonarr"
  mkdir -p "$sonarr"
  printf 'WG_CONFIG=/fixture/wg.conf\nVPN_TABLE=99\nVPN_TABLE=98\nWG_ADDRESS_SUBNET=4\n' > "$sonarr/proton.env"
  printf 'QBITTORRENT_USER=fixture\nQBITTORRENT_PASS=synthetic\n' > "$sonarr/qbittorrent.env"
  printf '# stale\nQBT_FORWARDED_PORT=1111\nQBT_PUBLISHED_PORT=51413\nQBT_PUBLISHED_PORT=2222\n' \
    > "$sonarr/qbittorrent-port.env"
  chmod 0644 "$sonarr/proton.env" "$sonarr/qbittorrent.env"

  run_install_instance_examples

  [ "$status" -eq 0 ]
  expected_table="$(awk -F '\t' '$1 == "sonarr" { print $6 }' qbittorrent-instances.tsv)"
  expected_priority="$(awk -F '\t' '$1 == "sonarr" { print $7 }' qbittorrent-instances.tsv)"
  [ "$(cat "$sonarr/proton.env")" = "$(printf 'WG_CONFIG=/fixture/wg.conf\nVPN_TABLE=%s\nWG_ADDRESS_SUBNET=4\nQBT_VPN_RULE_PRIORITY=%s' "$expected_table" "$expected_priority")" ]
  [ "$(cat "$sonarr/qbittorrent.env")" = "$(printf 'QBITTORRENT_USER=fixture\nQBITTORRENT_PASS=synthetic\nQBT_INSTANCE_NAME=sonarr')" ]
  [ "$(cat "$sonarr/qbittorrent-port.env")" = "$(printf '# Managed by proton-qbittorrent-sync-safe.sh\nQBT_PUBLISHED_PORT=51413')" ]
  [ "$(stat -c %a "$sonarr/proton.env")" = 600 ]
  [ "$(stat -c %a "$sonarr/qbittorrent.env")" = 600 ]
  [ "$(stat -c %a "$sonarr/qbittorrent-port.env")" = 600 ]
  [[ "$output" == *"Preserved and normalized $sonarr/qbittorrent-port.env to one QBT_PUBLISHED_PORT assignment"* ]]
  [[ "$output" == *"Preserved $sonarr/qbittorrent.env"* ]]

  # Instances without real configs get examples and the port template only.
  prowlarr="$ETC_FIXTURE/instances/prowlarr"
  [ ! -e "$prowlarr/proton.env" ]
  [ ! -e "$prowlarr/qbittorrent.env" ]
  cmp proton-qbittorrent-port.env "$prowlarr/qbittorrent-port.env"
  grep -Fx 'VPN_TABLE=51806' "$prowlarr/proton.env.example"
  grep -Fx 'QBT_VPN_RULE_PRIORITY=116' "$prowlarr/proton.env.example"
  for line in QBT_INSTANCE_NAME=prowlarr QBITTORRENT_URL=http://192.168.237.78:8082 \
    QBT_CONTAINER_NAME=qbittorrent-prowlarr QBT_COMPOSE_PROJECT_DIR=/opt/qbittorrent-prowlarr \
    QBT_COMPOSE_SERVICE=qbittorrent-prowlarr QBT_NETWORK_NAME=starr_network \
    "QBT_PORT_ENV_FILE=$ETC_FIXTURE/instances/prowlarr/qbittorrent-port.env"; do
    grep -Fx "$line" "$prowlarr/qbittorrent.env.example"
  done
  [ "$(stat -c %a "$prowlarr")" = 700 ]
  [ "$(stat -c %a "$prowlarr/qbittorrent.env.example")" = 600 ]
  ! grep -rq 'QBT_FORWARDED_PORT' "$ETC_FIXTURE"
}

@test "the port artifact template holds one published-port assignment" {
  [ "$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' proton-qbittorrent-port.env)" = 'QBT_PUBLISHED_PORT=6881' ]
  ! grep -Fq 'QBT_FORWARDED_PORT=' proton-qbittorrent-sync-safe.sh
}

@test "installer refuses to normalize a port artifact without a valid published port" {
  ETC_FIXTURE="$BATS_TEST_TMPDIR/etc-proton"
  for artifact in 'QBT_FORWARDED_PORT=51413' 'QBT_PUBLISHED_PORT=0' 'QBT_PUBLISHED_PORT=70000' 'QBT_PUBLISHED_PORT='; do
    rm -rf "$ETC_FIXTURE"
    mkdir -p "$ETC_FIXTURE/instances/lidarr"
    printf '%s\n' "$artifact" > "$ETC_FIXTURE/instances/lidarr/qbittorrent-port.env"

    run_install_instance_examples

    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid or missing QBT_PUBLISHED_PORT"* ]]
    [ "$(cat "$ETC_FIXTURE/instances/lidarr/qbittorrent-port.env")" = "$artifact" ]
  done
}

@test "installer manifest accessors read the columns named in the manifest header" {
  run bash -c '
    set -euo pipefail
    INSTANCE_MANIFEST_SOURCE=qbittorrent-instances.tsv
    for fn in instance_manifest_value instance_webui_port instance_vpn_interface instance_address_subnet instance_vpn_table instance_qbt_rule_priority; do
      eval "$(sed -n "/^${fn}() {/,/^}/p" install-proton-systemd.sh)"
    done
    read -r -a header < <(sed -n "1s/^# //p" qbittorrent-instances.tsv)
    column() {
      local name="$1" instance="$2" index
      for index in "${!header[@]}"; do
        if [[ "${header[index]}" == "$name" ]]; then
          awk -F "	" -v instance="$instance" -v field="$((index + 1))" "\$1 == instance { print \$field }" qbittorrent-instances.tsv
          return 0
        fi
      done
      return 1
    }
    for instance in lidarr prowlarr radarr sonarr whisparr; do
      [[ "$(instance_webui_port "$instance")" == "$(column webui_port "$instance")" ]]
      [[ "$(instance_vpn_interface "$instance")" == "$(column vpn_interface "$instance")" ]]
      [[ "$(instance_address_subnet "$instance")" == "$(column address_subnet "$instance")" ]]
      [[ "$(instance_vpn_table "$instance")" == "$(column vpn_table "$instance")" ]]
      [[ "$(instance_qbt_rule_priority "$instance")" == "$(column qbt_rule_priority "$instance")" ]]
    done
    [[ "$(instance_vpn_interface prowlarr)" == pvprowlarr && "$(instance_qbt_rule_priority prowlarr)" == 116 ]]
  '
  [ "$status" -eq 0 ]
}

@test "fleet reconciler defaults to the installed verifier path" {
  grep -Fq 'QBT_FLEET_VERIFY_SCRIPT:-/usr/local/bin/proton/proton-qbt-fleet-verify.sh' tools/reconcile-qbittorrent-fleet.sh
}

@test "fleet preflight distinguishes transient I/O waits from persistent D-state tasks" {
  grep -Fq 'QBT_FLEET_DSTATE_SAMPLES:-3' tools/reconcile-qbittorrent-fleet.sh
  grep -Fq 'qbt_fleet_preflight "$MANIFEST_FILE"' tools/reconcile-qbittorrent-fleet.sh
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\necho "cifs rw,cache=none"\n' > "$bin/findmnt"
  # Sample counts are per container. sonarr keeps LWPs 22 and 23 in D; lidarr
  # has one D sample that clears; any other container has none.
  cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
inspect) echo running ;;
top)
  count_file="$SAMPLE_DIR/$2"
  count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
  echo "$count" > "$count_file"
  printf 'PID LWP STAT\n1 11 Ssl\n'
  case "$2:$count" in
  qbittorrent-sonarr:*) printf '1 22 Dsl\n1 23 D\n' ;;
  qbittorrent-lidarr:1) printf '1 12 D\n' ;;
  esac
  ;;
esac
EOF
  chmod +x "$bin/findmnt" "$bin/docker"
  mkdir -p "$BATS_TEST_TMPDIR/samples"

  run env PATH="$bin:$PATH" SAMPLE_DIR="$BATS_TEST_TMPDIR/samples" QBT_DSTATE_DELAY=0 \
    QBT_FLEET_LOCK_FILE="$BATS_TEST_TMPDIR/fleet.lock" bash -c '
      source ./proton-qbittorrent-common.sh
      qbt_fleet_preflight qbittorrent-instances.tsv
    '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsafe or unknown task state for sonarr (persistent uninterruptible D-state task (LWP: 22, 23)); refusing the entire rollout."* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/samples/qbittorrent-lidarr")" = 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/samples/qbittorrent-sonarr")" = 3 ]
}

@test "manifest pins the prowlarr and whisparr identity rows" {
  grep -Fq $'prowlarr\t8082\t10.6.0.2\tpvprowlarr\t6\t51806\t116' qbittorrent-instances.tsv
  grep -Fq $'whisparr\t8085\t10.5.0.2\tpvwhisparr\t5\t51805\t115' qbittorrent-instances.tsv
}

@test "cleanup scripts install at the existing flat runtime paths" {
  run bash -c '
    set -euo pipefail
    SCRIPT_DIR="$PWD"
    BIN_DIR="$1/live"
    mkdir -p "$BIN_DIR"
    eval "$(sed -n "/^install_script_file() {/,/^}/p" install-proton-systemd.sh)"
    ensure_source_file() { test -f "$1"; }
    same_path() { [[ "$1" == "$2" ]]; }
    install_normalized_file() { install -m "$3" "$1" "$2"; }
    log() { :; }
    for source in proton-killswitch-reset.sh; do
      install_script_file "$source"
      target="$BIN_DIR/${source##*/}"
      test -x "$target"
      cmp "$source" "$target"
    done
  ' _ "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

@test "installer reapplies the kill switch without restarting it so Docker is never restarted" {
  for state in active inactive; do
    run bash -c '
      set -euo pipefail
      state="$1"
      log_file="$2"
      : > "$log_file"
      systemctl() {
        printf "%s\n" "$*" >> "$log_file"
        if [[ "$1" == is-active ]]; then [[ "$state" == active ]]; fi
      }
      LEGACY_SINGLETON_SERVICES=(proton-legacy.service)
      OPTIONAL_SERVICES=()
      SERVICES=()
      eval "$(sed -n "/^enable_and_start_services() {/,/^}/p" install-proton-systemd.sh)"
      enable_and_start_services
    ' _ "$state" "$BATS_TEST_TMPDIR/systemctl.log"
    [ "$status" -eq 0 ]
    run grep -E '(^| )(restart|try-restart|reload-or-restart) proton-killswitch' "$BATS_TEST_TMPDIR/systemctl.log"
    [ "$status" -eq 1 ]
    if [[ "$state" == active ]]; then
      grep -Fx 'reload proton-killswitch.service' "$BATS_TEST_TMPDIR/systemctl.log"
    else
      grep -Fx 'start proton-killswitch.service' "$BATS_TEST_TMPDIR/systemctl.log"
    fi
  done
  grep -Fx 'ExecReload=/usr/local/bin/proton/proton-killswitch-dispatch.sh' proton-killswitch.service
}

@test "installer installs Docker's tunnel-ordering and stop-timeout drop-ins" {
  run bash -c '
    set -euo pipefail
    SCRIPT_DIR="$PWD"
    SYSTEMD_DIR="$1/systemd"
    eval "$(sed -n "/^normalize_text_file() {/,/^}/p" install-proton-systemd.sh)"
    eval "$(sed -n "/^install_docker_tunnel_ordering() {/,/^}/p" install-proton-systemd.sh)"
    install_normalized_file() { normalize_text_file "$1" "$2"; chmod "$3" "$2"; }
    install_docker_tunnel_ordering
  ' _ "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  cmp <(awk 1 docker-proton-tunnels.conf) "$BATS_TEST_TMPDIR/systemd/docker.service.d/proton-tunnels.conf"
  cmp <(awk 1 docker-proton-stop-timeout.conf) "$BATS_TEST_TMPDIR/systemd/docker.service.d/proton-stop-timeout.conf"
}
