#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  export SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
  export SYSTEMCTL_STATE="$TEST_TMPDIR/active"
  mkdir -p "$SYSTEMCTL_STATE"
  cat > "$TEST_TMPDIR/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
  start)
    if [[ ",${FAIL_START:-}," == *",$2,"* ]]; then exit 1; fi
    touch "$SYSTEMCTL_STATE/$2"
    ;;
  stop) rm -f "$SYSTEMCTL_STATE/$2" ;;
  is-active)
    unit="${*: -1}"
    if [[ -e "$SYSTEMCTL_STATE/$unit" ]]; then
      [[ "$2" == --quiet ]] || echo active
      exit 0
    fi
    [[ "$2" == --quiet ]] || echo inactive
    exit 3
    ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/systemctl"
  export PROTON_SYSTEMCTL="$TEST_TMPDIR/systemctl"
  export PROTON_SERVICES_SETTLE_SECONDS=0
}

run_as_root() {
  run unshare --user --map-root-user env PROTON_SYSTEMCTL="$PROTON_SYSTEMCTL" \
    PROTON_SERVICES_SETTLE_SECONDS=0 SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    SYSTEMCTL_STATE="$SYSTEMCTL_STATE" FAIL_START="${FAIL_START:-}" \
    bash tools/proton-fleet-services.sh "$@"
}

started_units() {
  awk '$1 == "start" { print $2 }' "$SYSTEMCTL_LOG"
}

@test "start raises the kill switch first, then each instance in dependency order" {
  run_as_root start sonarr radarr
  [ "$status" -eq 0 ]
  [ "$(started_units)" = "proton-killswitch.service
proton-wg@sonarr.service
proton-docker-watch@sonarr.service
proton-port-forward@sonarr.service
proton-healthcheck@sonarr.service
proton-wg@radarr.service
proton-docker-watch@radarr.service
proton-port-forward@radarr.service
proton-healthcheck@radarr.service" ]
}

@test "start does not touch an already active kill switch" {
  touch "$SYSTEMCTL_STATE/proton-killswitch.service"
  run_as_root start lidarr
  [ "$status" -eq 0 ]
  ! grep -Eq '^(start|stop|restart) proton-killswitch' "$SYSTEMCTL_LOG"
}

@test "a failed kill switch start prevents every tunnel start" {
  FAIL_START=proton-killswitch.service run_as_root start
  [ "$status" -ne 0 ]
  ! grep -q 'proton-wg@' "$SYSTEMCTL_LOG"
}

@test "a failed unit stops the run before later units and instances" {
  FAIL_START=proton-port-forward@lidarr.service run_as_root start lidarr prowlarr
  [ "$status" -ne 0 ]
  [[ "$output" == *"proton-port-forward@lidarr.service failed to start"* ]]
  ! grep -q 'start proton-healthcheck@lidarr' "$SYSTEMCTL_LOG"
  ! grep -q 'prowlarr' "$SYSTEMCTL_LOG"
}

@test "stop runs in reverse dependency order and never stops the kill switch" {
  run_as_root stop whisparr
  [ "$status" -eq 0 ]
  [ "$(awk '$1 == "stop" { print $2 }' "$SYSTEMCTL_LOG")" = "proton-healthcheck@whisparr.service
proton-port-forward@whisparr.service
proton-docker-watch@whisparr.service
proton-wg@whisparr.service" ]
  ! grep -q 'proton-killswitch' "$SYSTEMCTL_LOG"
}

@test "defaults to all five instances and rejects unknown ones before acting" {
  run_as_root --dry-run stop
  [ "$status" -eq 0 ]
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    [[ "$output" == *"stop proton-wg@${instance}.service"* ]]
  done
  [ ! -e "$SYSTEMCTL_LOG" ]

  run_as_root start lidarr bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown instance 'bogus'"* ]]
  [ ! -e "$SYSTEMCTL_LOG" ]
}

@test "mutating actions require root; status is read-only" {
  run bash tools/proton-fleet-services.sh start lidarr
  [ "$status" -ne 0 ]
  [[ "$output" == *"must run as root"* ]]
  [ ! -e "$SYSTEMCTL_LOG" ]

  run bash tools/proton-fleet-services.sh status lidarr
  [ "$status" -eq 0 ]
  [[ "$output" == *"proton-wg@lidarr.service"*"inactive"* ]]
  ! grep -Eq '^(start|stop|reset-failed)' "$SYSTEMCTL_LOG"
}
