# qBittorrent/Proton operations documentation

This directory documents the five-instance qBittorrent fleet, its Proton port-forwarding control plane, and recorded storage and routing incidents.

The canonical source is `/usr/local/bin/proton_project`. Do not use `/opt/proton_project_work` as current source unless it has been explicitly synchronized and verified.

## Recorded recovered baseline

`cache=none` on `/mnt/data` is the active fleet-wide mitigation and remains required operating policy; it is not a demonstrated kernel fix. The [fleet contract](architecture/qbittorrent-fleet-contract.md) owns the storage and boot baseline and the oops timeline; the [wedge recovery runbook](runbooks/qbittorrent-wedge-recovery.md#kernel-upgrade-qualification) owns kernel qualification. Uploading and seeding stay enabled; do not add torrent queueing, active-upload or seeding limits, or a one-instance storage policy.

## Deployment status

This is the one dated record of what is installed; other documents link here
instead of carrying their own "not deployed" notes. Add a dated entry after each
authorized install.

- 2026-09-24: the canonical source through commit `4675079` is not yet
  installed; everything through `7956a87` is. That covers the 2026-09-11 audit
  (generation-bound leases, lifecycle and firewall serialization, selector
  publication, recreation safety), the 2026-09-12 follow-ups, the 2026-09-13
  single fallback owner, and code audit sections 1–6 and 4.4–4.6. Evidence: the
  installed copies under `/usr/local/bin/proton` matched source byte for byte;
  `proton-qbt-fleet-verify.sh --config` passed for all five instances; all 22
  Proton units were active, and Docker and the kill switch were not restarted;
  `ip rule` showed one qBittorrent rule per instance at 112–116 and a single
  fallback rule (sonarr, 130). The runtime verifier (`--recreate`) was not run.
  Source-only (not installed): `4675079` (Docker stop timeout and
  restoring containers a Docker restart took down) and later commits.

## Start here

Dated documentation reviews live in [reviews/](reviews/); they are records,
not operating guidance.

| Document | Use it when |
| --- | --- |
| [Fleet architecture and invariants](architecture/qbittorrent-fleet-contract.md) | deciding what is shared, what is instance-specific, and which source is authoritative |
| [Port synchronization runbook](runbooks/qbittorrent-port-sync.md) | diagnosing or validating a Proton lease, qBittorrent listen port, or Docker TCP/UDP mapping |
| [Fleet change runbook](runbooks/qbittorrent-fleet-changes.md) | changing Compose, image, init hooks, orchestration code, routing, storage policy, or common qBittorrent settings |
| [Wedge recovery runbook](runbooks/qbittorrent-wedge-recovery.md) | a qBittorrent container is unhealthy, cannot stop, contains a zombie, or has a task in kernel `D` state |
| [Host routing, tunnels, and runtime state](architecture/host-routing-and-tunnels.md) | tunnel isolation, WireGuard defaults, runtime state, DNS/egress policy, healthcheck, watcher, installer behavior |
| [Server pool runbook](runbooks/server-pool-selection.md) | latency selection, port-forward capability learning, quarantine, selector helpers |
| [IPv6 rollout runbook](runbooks/ipv6-rollout.md) | IPv6 snapshot, canary, rollback, and Docker dual-stack prerequisites |
| [Host verification runbook](runbooks/host-verification.md) | routing, firewall, DNS, and leak checks; watcher enablement |
| [2026-08-14 Sonarr incident report](incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md) | reviewing the evidence, timeline, root-cause assessment, impact, and corrective actions for this incident |
| [2026-09-13 Docker Proton fallback-route incident](incidents/2026-09-13-docker-proton-fallback-route-churn.md) | diagnosing cross-container DNS/TLS failures, reviewing the single-owner route fix, or completing its deployment and acceptance checks |
| [2026-09-23 installer Docker-restart incident](incidents/2026-09-23-installer-docker-restart-and-rule-sweep.md) | reviewing why installs restarted Docker, the reverted policy-rule sweep, externally owned rules in instance tables, or the remaining follow-ups |

## Core operational rule

**Change one, change all** applies to shared service policy and behavior. A change to the qBittorrent image, common Compose policy, health check, init hook, storage strategy, port synchronizer, route logic, kill switch, allocator, or fleet-controlled qBittorrent preference must be implemented once and rolled through all five instances.

It does not mean copying runtime values. Lidarr, Prowlarr, Radarr, Sonarr, and Whisparr have independent WireGuard identities and independent Proton NAT-PMP leases. A new lease recreates only the qBittorrent container that owns it.

## Verification commands

```bash
# Safe, non-secret static contract
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only

# Static plus protected per-instance configuration
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config

# Complete lease/artifact/container/API port and health parity
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

For a shared container/configuration rollout:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --preflight &&
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

This assumes the approved bundle is already installed and its instance chains
have completed any required source-version migration. The installer also changes
the host kill switch; do not treat installation as a read-only prerequisite.

The reconciler performs final runtime verification itself. Keep dependent commands joined with `&&` so a later verifier cannot mask an earlier failure. The tool refuses unhealthy or zombie members immediately and rejects a persistent same-LWP `D` state after multiple samples; a one-snapshot CIFS wait is allowed to clear.
