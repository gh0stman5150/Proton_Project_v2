# Repository structure

Canonical source is `/usr/local/bin/proton_project`. Systemd runs only the installed copies under `/usr/local/bin/proton`.

```
proton_project/
├── AGENTS.md, CLAUDE.md, README.md      authority, Claude entry point, onboarding
├── install-proton-systemd.sh            the only supported way to deploy
├── proton-instance-common.sh            per-instance config loading, route locks
├── proton-qbittorrent-common.sh         protected config + qBittorrent API auth
│
├── proton-killswitch-dispatch.sh        picks backend per KILLSWITCH_BACKEND
├── proton-killswitch-nft.sh             nftables backend (IPv4 + optional Docker IPv6)
├── proton-killswitch-safe.sh            iptables backend (refuses Docker IPv6)
├── proton-killswitch-reset.sh           kill-switch teardown helper
├── proton-wg-up-safe.sh / -down-safe.sh tunnel, policy routes/rules
├── proton-server-manager.sh             pool selection, PF-capability learning
├── proton-port-forward-safe.sh          NAT-PMP lease loop
├── proton-port-forward-healthcheck.sh   ExecStartPre gate for the loop
├── proton-qbittorrent-sync-safe.sh      port → API → artifact → Compose recreate
├── proton-qbt-allocate-and-sync.sh      oneshot allocation + sync
├── proton-healthcheck.sh                throughput watchdog and recovery ladder
├── proton-docker-network-watcher.sh     Docker event/periodic reconciler
├── proton-ipv6-rollout.sh               snapshot / canary / rollback controller
├── nas-network-online.sh                NAS readiness gate
│
├── *.service, *@.service                systemd units (templates keyed by instance)
├── nas-network-online.mount.conf,
│   docker-proton-stop-timeout.conf      systemd drop-ins owned by the installer
├── proton-common.env, proton-port-forward.env,
│   proton-healthcheck.env, proton-qbittorrent-port.env   config templates
├── qbittorrent-compose.common.yml       shared container policy
├── qbittorrent-instances.tsv            per-instance identity manifest
│
├── tools/                               fleet tools, renamed on install
├── tests/                               Bats suite (23 .bats files + helpers)
├── docs/                                architecture, runbooks, incidents, reviews
├── Archive/                             git-ignored legacy helpers (tracked: README only)
├── bats-core/                           pinned upstream submodule
└── .github/                             CI (lint-and-test.yml), prompts, agent config
```

## Source to installed mapping

| Source | Installed as |
|---|---|
| root `proton-*.sh`, `nas-network-online.sh`, `install-proton-systemd.sh` | `/usr/local/bin/proton/<same name>` |
| `tools/verify-qbittorrent-fleet.sh` | `proton-qbt-fleet-verify.sh` |
| `tools/reconcile-qbittorrent-fleet.sh` | `proton-qbt-fleet-reconcile.sh` |
| `tools/recreate-qbittorrent-fleet.sh` | `proton-qbt-fleet-recreate.sh` |
| `tools/proton-fleet-services.sh` | `proton-fleet-services.sh` |
| `*.service` | `/etc/systemd/system/` |
| `qbittorrent-compose.common.yml`, `qbittorrent-instances.tsv` | `/opt/qbittorrent-common/` |
| `proton-*.env` templates | `/etc/proton/`; per-instance examples under `/etc/proton/instances/<instance>/` |

## What belongs where

| Location | Put here | Not here |
|---|---|---|
| root `*.sh` | Runtime entrypoints the installer lists in `SCRIPTS` | Fleet-wide orchestration (use `tools/`) |
| `tools/` | Verify, reconcile, recreate, service-listing tools | Anything a unit's `ExecStart` runs directly from the checkout |
| `docs/architecture/` | Contracts and invariants | Step-by-step procedures |
| `docs/runbooks/` | Operator procedures | Dated evidence |
| `docs/incidents/` | Dated evidence and timelines | Current operating rules |
| `docs/reviews/` | Dated reviews, which are records and not guidance | Instructions |
| `tests/` | Bats tests with stubbed host commands | Tests that touch real host paths or services |

Never store live state files, credentials or WireGuard keys in the repository. Runtime state lives under `/run/proton/<instance>/` and protected config under `/etc/proton/`.
