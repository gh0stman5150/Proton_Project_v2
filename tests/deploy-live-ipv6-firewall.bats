#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  PROJECT="$TEST_TMPDIR/project"
  LIVE="$TEST_TMPDIR/live"
  BACKUPS="$TEST_TMPDIR/backups"
  mkdir -p "$PROJECT" "$LIVE"

  for script in proton-killswitch-nft.sh proton-killswitch-safe.sh proton-killswitch-reset.sh \
    proton-wg-up-safe.sh proton-wg-down-safe.sh proton-docker-network-watcher.sh; do
    printf '#!/usr/bin/env bash\necho new-%s\n' "$script" > "$PROJECT/$script"
    printf '#!/usr/bin/env bash\necho old-%s\n' "$script" > "$LIVE/$script"
    chmod 0755 "$PROJECT/$script" "$LIVE/$script"
  done
}

@test "deployment snapshots and replaces scripts without invoking services" {
  run env \
    PROJECT_DIR="$PROJECT" \
    LIVE_DIR="$LIVE" \
    BACKUP_ROOT="$BACKUPS" \
    DEPLOY_TIMESTAMP=canary \
    DEPLOY_ALLOW_UNPRIVILEGED_TEST=1 \
    bash ./deploy-live-ipv6-firewall.sh deploy

  [ "$status" -eq 0 ]
  [[ "$output" == *"Rollback snapshot: $BACKUPS/canary"* ]]
  grep -F 'echo old-proton-killswitch-nft.sh' "$BACKUPS/canary/proton-killswitch-nft.sh"
  grep -F 'echo new-proton-killswitch-nft.sh' "$LIVE/proton-killswitch-nft.sh"
  grep -F 'echo old-proton-docker-network-watcher.sh' "$BACKUPS/canary/proton-docker-network-watcher.sh"
  grep -F 'echo new-proton-docker-network-watcher.sh' "$LIVE/proton-docker-network-watcher.sh"
  run bash -c 'cd "$1" && sha256sum -c SHA256SUMS' _ "$BACKUPS/canary"
  [ "$status" -eq 0 ]
}

@test "rollback snapshots current scripts before restoring the selected deployment" {
  run env \
    PROJECT_DIR="$PROJECT" \
    LIVE_DIR="$LIVE" \
    BACKUP_ROOT="$BACKUPS" \
    DEPLOY_TIMESTAMP=canary \
    DEPLOY_ALLOW_UNPRIVILEGED_TEST=1 \
    bash ./deploy-live-ipv6-firewall.sh deploy
  [ "$status" -eq 0 ]

  run env \
    PROJECT_DIR="$PROJECT" \
    LIVE_DIR="$LIVE" \
    BACKUP_ROOT="$BACKUPS" \
    DEPLOY_TIMESTAMP=recovery \
    DEPLOY_ALLOW_UNPRIVILEGED_TEST=1 \
    bash ./deploy-live-ipv6-firewall.sh rollback "$BACKUPS/canary"

  [ "$status" -eq 0 ]
  grep -F 'echo old-proton-killswitch-nft.sh' "$LIVE/proton-killswitch-nft.sh"
  grep -F 'echo new-proton-killswitch-nft.sh' "$BACKUPS/pre-rollback-recovery/proton-killswitch-nft.sh"
  grep -F 'echo old-proton-docker-network-watcher.sh' "$LIVE/proton-docker-network-watcher.sh"
  grep -F 'echo new-proton-docker-network-watcher.sh' "$BACKUPS/pre-rollback-recovery/proton-docker-network-watcher.sh"
}