#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  mkdir -p "$PROTON_INSTANCE_ROOT/sonarr"
  : > "$PROTON_COMMON_ENV"

  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<'EOF'
STATE_DIR=/run/proton/sonarr
EOF

  cat > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env" <<'EOF'
QBITTORRENT_URL=http://127.0.0.1:8083
EOF
}

@test "exits non-zero when required command missing" {
  BASH_BIN="$(command -v bash)"
  OLD_PATH="$PATH"
  # Intentionally override PATH to simulate missing commands
  # shellcheck disable=SC2123
  PATH="/nonexistent"
  run "$BASH_BIN" ./proton-qbt-dnat-cleanup.sh sonarr
  [ "$status" -ne 0 ]
  PATH="$OLD_PATH"
}

@test "exits 0 when nft present but chain absent" {
  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat -
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TMPBIN/nft" <<'EOF'
#!/usr/bin/env bash
# Simulate nft: return non-zero for 'list' to indicate chain missing
if [ "$1" = "list" ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$TMPBIN/nft"

  run bash ./proton-qbt-dnat-cleanup.sh sonarr
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No DNAT chain" ]]
}
