#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export DISPATCH_LOG="$TEST_TMPDIR/dispatch.log"
  export NFTABLES_SCRIPT="$TEST_TMPDIR/nft-backend.sh"
  export IPTABLES_SCRIPT="$TEST_TMPDIR/iptables-backend.sh"

  # PATH is reduced to the stub directory, so the backends need absolute
  # shebangs and the dispatcher runs under an absolute bash.
  for backend in nft iptables; do
    printf '#!/bin/bash\nprintf "%s\\n" >> "$DISPATCH_LOG"\n' "$backend" \
      > "$TEST_TMPDIR/$backend-backend.sh"
    chmod +x "$TEST_TMPDIR/$backend-backend.sh"
  done
}

dispatch() {
  run env PATH="$TMPBIN" KILLSWITCH_BACKEND="$1" /bin/bash ./proton-killswitch-dispatch.sh
}

install_nft_stub() {
  printf '#!/bin/bash\nexit 0\n' > "$TMPBIN/nft"
  chmod +x "$TMPBIN/nft"
}

@test "auto selects nftables when nft is installed" {
  install_nft_stub
  dispatch auto
  [ "$status" -eq 0 ]
  [ "$(cat "$DISPATCH_LOG")" = "nft" ]
}

@test "auto falls back to iptables when nft is not installed" {
  dispatch auto
  [ "$status" -eq 0 ]
  [ "$(cat "$DISPATCH_LOG")" = "iptables" ]
}

@test "explicit backends are honoured regardless of installed tools" {
  install_nft_stub
  for backend in nft nftables; do
    : > "$DISPATCH_LOG"
    dispatch "$backend"
    [ "$status" -eq 0 ]
    [ "$(cat "$DISPATCH_LOG")" = "nft" ]
  done

  : > "$DISPATCH_LOG"
  dispatch iptables
  [ "$status" -eq 0 ]
  [ "$(cat "$DISPATCH_LOG")" = "iptables" ]
}

@test "an unsupported backend fails without running either backend" {
  install_nft_stub
  dispatch pf
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported KILLSWITCH_BACKEND: pf"* ]]
  [ ! -e "$DISPATCH_LOG" ]
}
