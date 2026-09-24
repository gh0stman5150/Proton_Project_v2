# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the authoritative project guide (safety boundaries, fleet contract,
installer/runtime invariants, change workflow, documentation map). It is imported
here; if anything below conflicts with it, follow `AGENTS.md`.

@AGENTS.md

## Checkout Location

`AGENTS.md` names `/usr/local/bin/proton_project` as canonical source. Check
`pwd` before acting:

- In `/usr/local/bin/proton_project` you are on the live Linux host. systemd,
  Docker, WireGuard, and the installed copies under `/usr/local/bin/proton` are
  real. Tests are safe because they stub host commands. Do not run runtime
  scripts, the installer, or `sudo` fleet tools unless you have explicit
  authorization (see Safety Boundaries).
- Anywhere else (e.g. a synced macOS copy) there is no live state, so only
  source-level validation is possible. Never claim installed or live
  verification from it.

## Commands

`bats-core` is a submodule pinned to the `gh0stman5150/bats-core` fork; in a
fresh clone run `git submodule update --init bats-core`. CI uses the apt `bats`
package instead. The suite assumes Linux, GNU
coreutils, and bash 4+; many tests fail under macOS bash 3.2/BSD tools.

```bash
# Full suite (pinned runner; do not modify bats-core/ to make a test pass)
timeout --kill-after=5s 300s env BATS_TEST_TIMEOUT=30 ./bats-core/bin/bats tests

# One file, or one test by name regex
./bats-core/bin/bats tests/proton-qbittorrent-sync-recreate.bats
./bats-core/bin/bats tests/proton-wg-up.bats --filter 'kill switch'

# Static checks (CI runs these on all tracked *.sh files)
shellcheck -x ./*.sh tools/*.sh
shfmt -d ./*.sh tools/*.sh        # CI fails on any shfmt -l output
for script in ./*.sh tools/*.sh; do bash -n "$script" || exit; done
git diff --check                  # CI also checks line-ending normalization
```

Scripts use tab indentation (shfmt default). There is no build step.

## Architecture

Everything is per-instance systemd templates keyed by instance name (`%i` =
`lidarr|prowlarr|radarr|sonarr|whisparr`), all installed by
`install-proton-systemd.sh` into `/usr/local/bin/proton` (scripts in `tools/`
are renamed on install, e.g. `tools/verify-qbittorrent-fleet.sh` →
`proton-qbt-fleet-verify.sh`).

Unit dependency chain:

- `proton-killswitch.service` → `proton-killswitch-dispatch.sh`, which execs the
  nftables (`proton-killswitch-nft.sh`) or iptables (`proton-killswitch-safe.sh`)
  backend per `KILLSWITCH_BACKEND` (default `auto` prefers nft).
- `proton-wg@` (requires kill switch) → `proton-wg-up-safe.sh` / `proton-wg-down-safe.sh`:
  tunnel, policy routes/rules, server selection via `proton-server-manager.sh`.
- `proton-port-forward@` (PartOf wg) → `proton-port-forward-safe.sh`: NAT-PMP lease
  loop, writes `CURRENT_PORT`/`CURRENT_IP` into the instance `STATE_FILE`, then
  calls `proton-qbittorrent-sync-safe.sh`.
- `proton-qbittorrent-sync-safe.sh` is the largest safety-critical path: pushes the
  port to the qBittorrent API, writes the one-key `QBT_PUBLISHED_PORT` artifact, and
  recreates only the owning container via Compose, with zombie/`D`-state gates.
- `proton-qbt-allocate@` (oneshot) → `proton-qbt-allocate-and-sync.sh`, same sync script.
- `proton-healthcheck@` and `proton-docker-watch@` monitor throughput and Docker
  network drift for each tunnel.
- Fleet tools (`tools/`): verify (static/config/runtime), reconcile (sequential
  rolling recreate of all five), recreate (`--bootstrap` after container removal).

Config layering (see `proton_instance_init` in `proton-instance-common.sh`):
`proton-common.env` → optional role env → per-instance `proton.env` →
`qbittorrent.env`. `WG_ADDRESS_SUBNET` is the single source from which addresses
are derived; `qbittorrent-instances.tsv` supplies each instance's identity row.
The `*.env` files at repo root are templates/defaults installed by the installer.

## Test Conventions

Tests exercise real scripts with host commands (`docker`, `curl`, `nft`, `ip`,
`findmnt`, `stat`, …) replaced by stubs written into a temp `bin/` prepended to
`PATH`, and point scripts at fixtures via environment overrides (`STATE_FILE`,
`PROTON_INSTANCE_ROOT`, `PROTON_COMMON_ENV`, `*_SCRIPT`, lock paths). Nearly every
path and dependent script in the runtime scripts is overridable this way; add a
variable override rather than touching real host paths. The qBittorrent sync suite
is split across `proton-qbittorrent-sync-{port,recreate,safety}.bats` sharing
`tests/proton-qbittorrent-sync-helper.bash` (loaded with `load`).
