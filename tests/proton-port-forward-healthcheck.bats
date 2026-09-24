#!/usr/bin/env bats

load common-stubs

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export PROTON_PORT_FORWARD_ENV="$TEST_TMPDIR/proton-port-forward.env"
  export CURL_LOG="$TEST_TMPDIR/curl.log"

  mkdir -p "$TMPBIN" "$PROTON_INSTANCE_ROOT/sonarr"
  : > "$PROTON_COMMON_ENV"
  append_manifest_routing sonarr "$PROTON_INSTANCE_ROOT/sonarr/proton.env"
  printf 'QBITTORRENT_URL=http://qb.test:8084/\n' > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env"

  cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
printf '%s' "${TEST_HTTP_STATUS:-401}"
EOF
  for cmd in ip natpmpc systemd-cat; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPBIN/$cmd"
  done
  chmod +x "$TMPBIN"/*
}

@test "port-forward preflight accepts an answering Web UI through the shared probe" {
  run bash ./proton-port-forward-healthcheck.sh sonarr

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -F -- '--max-time 5' "$CURL_LOG"
  grep -F 'http://qb.test:8084/api/v2/app/version' "$CURL_LOG"
}

@test "port-forward preflight warns but continues when the Web UI is down" {
  run env TEST_HTTP_STATUS=000 bash ./proton-port-forward-healthcheck.sh sonarr

  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: qBittorrent Web API is not reachable at http://qb.test:8084 (HTTP 000)"* ]]
}

@test "port-forward preflight refuses a missing qBittorrent env or URL before probing" {
  rm "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env"
  run bash ./proton-port-forward-healthcheck.sh sonarr
  [ "$status" -ne 0 ]
  [[ "$output" == *"Instance qBittorrent env not found"* ]]

  : > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env"
  run bash ./proton-port-forward-healthcheck.sh sonarr
  [ "$status" -ne 0 ]
  [[ "$output" == *"QBITTORRENT_URL must be set"* ]]
  [ ! -e "$CURL_LOG" ]
}
