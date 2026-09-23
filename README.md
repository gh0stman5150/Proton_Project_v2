# Proton WireGuard Routing and qBittorrent Port Forwarding

## Repository Purpose

This repository implements and maintains host-level Proton WireGuard routing,
leak prevention, NAT-PMP port forwarding, and health recovery for five
Docker-hosted qBittorrent instances. Other Docker applications may use the
protected routing path, but this repository does not manage their lifecycle.

## Policy and Authority

`AGENTS.md` is the source of truth for this repository. The canonical source checkout is `/usr/local/bin/proton_project`; `/opt/proton_project_work` is a non-authoritative working copy that may be stale.

This README documents the source implementation, intended runtime behavior, installation flow, and validation steps. If this README and `AGENTS.md` ever differ, follow `AGENTS.md`.

Source status, 2026-09-11: the audit fixes cover bootstrap/recreation safety,
fresh leases and renewal, routing/lifecycle recovery, and selector/firewall
ownership. They have not been deployed or verified on live host traffic during
this work. Fixture and isolated network-namespace tests do not establish installed
provenance, systemd recovery, or a kernel fix. Use the sequential source-version
migration in the [fleet change runbook](docs/runbooks/qbittorrent-fleet-changes.md)
before treating an existing installation as upgraded.

Source follow-up, 2026-09-12: recreation now rechecks lease freshness before
replacement startup and success, retries its own recorded stopped container
after a failed recreation, and bounds complete WireGuard teardown below the
systemd stop timeout. These changes are source-only and are not deployed.

## Documentation Map

| Document | Use it when |
| --- | --- |
| [Fleet architecture and invariants](docs/architecture/qbittorrent-fleet-contract.md) | deciding what is shared across the five clients and which source is authoritative |
| [Host routing, tunnels, and runtime state](docs/architecture/host-routing-and-tunnels.md) | tunnel isolation, WireGuard defaults, runtime state, DNS/egress policy, healthcheck, watcher, installer behavior |
| [Port synchronization runbook](docs/runbooks/qbittorrent-port-sync.md) | tracing a Proton lease through qBittorrent, the one-key artifact, and Docker TCP/UDP mappings |
| [Fleet change runbook](docs/runbooks/qbittorrent-fleet-changes.md) | “change one, change all” for shared code, Compose policy, init hooks, storage, and preferences |
| [Wedge recovery runbook](docs/runbooks/qbittorrent-wedge-recovery.md) | application failure vs. Docker/runtime wedge vs. unkillable kernel `D` state |
| [Server pool runbook](docs/runbooks/server-pool-selection.md) | latency selection, port-forward capability learning, quarantine, and manual selector helpers |
| [IPv6 rollout runbook](docs/runbooks/ipv6-rollout.md) | snapshot, canary, rollback, and Docker dual-stack prerequisites |
| [Host verification runbook](docs/runbooks/host-verification.md) | routing, firewall, DNS, and leak checks; watcher enablement |
| [2026-08-14 Sonarr incident report](docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md) | incident timeline, evidence, and root-cause history only |

Shared configuration changes must be implemented once and reconciled across `lidarr`, `prowlarr`, `radarr`, `sonarr`, and `whisparr`. Dynamic Proton ports remain independent: a lease change recreates only the qBittorrent service that owns that tunnel, using the same synchronizer behavior as the other four.

## Recorded Storage, Boot, And Kernel Baseline

The following summarizes the August 2026 incident evidence and required operating baseline. This documentation review did not revalidate live health or current kernel publication channels; use the runtime gates before an operational change.

- `/mnt/data` is an SMB 3.1.1 CIFS mount with active `cache=none`. It is one shared policy for all five qBittorrent clients and all other consumers of that mount.
- The third oops occurred at 19:05 CDT on 2026-08-17 while the mount still used `cache=strict`; fstab changed at 20:01, and the 20:16 reboot created the first live `cache=none` mount. The recorded post-reboot checks found no recurrence on the fresh mount; that observation does not establish current health or a demonstrated kernel fix.
- `mnt-data.mount` and `mnt-plex.mount` require and follow `nas-network-online.service`, which waits for both a route to the NAS and a successful SMB connection on TCP port 445.
- Docker wants and follows all five Proton WireGuard units. The ordering attempts tunnel activation before Docker; the kill switch and runtime verifier still decide whether application traffic is safe.
- All five qBittorrent clients passed post-boot runtime verification. Torrent queueing remains disabled, and recovery introduced no active-upload or seeding limit. Shared changes remain sequential so four clients stay available while one is reconciled.

There is no production kernel currently documented as a proven exact fix. In the recorded package review, Ubuntu `7.0.0-30.30` adds no relevant netfs correction, and `7.0.0-31.31` remains proposed-only. Linux 7.1.8 and 7.2 contain related netfs writeback and exclusion repairs, but they have not been demonstrated against this workload. Keep `cache=none` active and follow the [wedge recovery runbook](docs/runbooks/qbittorrent-wedge-recovery.md) for candidate-kernel qualification. These are historical findings, not a new check of package publication channels.

## Key Capabilities

The repository must enforce the following rules:

1. All Docker hosted application traffic must use the Proton WireGuard VPN
2. SSH on `tcp/22` must bypass the VPN and remain reachable through WAN and LAN
3. RDP on `tcp/3389` must bypass the VPN and remain reachable through WAN and LAN
4. qBittorrent must automatically update its listening port whenever Proton's forwarded port changes or the VPN reconnects
5. qBittorrent must never bind or fall back to a non VPN path
6. Docker hosted application traffic must not leak directly to WAN during VPN downtime
7. DNS queries from Docker hosted application services must follow the intended VPN path and must not bypass the kill switch

## Architecture Overview

This host is single homed on one Ethernet interface. SSH and RDP run on bare metal and bypass the VPN in both directions. Docker hosted application services use the WireGuard path and must not leak directly to WAN if the VPN drops. The kill switch only needs to protect Docker hosted application traffic; host traffic outside Docker is not blocked unless explicitly required elsewhere.

Do not replace this design with a VPN container, gateway container, or sidecar unless the repository already depends on that model and the reason is documented.

## Active Service Path

The systemd units are wired to the hardened entrypoints below:

1. `proton-killswitch-dispatch.sh`
2. `proton-killswitch-safe.sh`
3. `proton-killswitch-nft.sh`
4. `proton-wg-up-safe.sh`
5. `proton-wg-down-safe.sh`
6. `proton-port-forward-safe.sh`
7. `proton-qbittorrent-sync-safe.sh`
8. `proton-server-manager.sh`
9. `proton-healthcheck.sh`
10. `install-proton-systemd.sh`
11. `proton-qbt-dnat-cleanup.sh` (`proton-port-forward@.service` `ExecStop`)

The installer’s `SCRIPTS` list and the units’ `ExecStart`/`ExecStop` fields define installed entrypoints. Other root scripts include maintenance and deployment helpers; inspect their behavior before running them.

The kill switch dispatcher defaults to `KILLSWITCH_BACKEND=auto`. It prefers `nftables` when `nft` is available and falls back to `iptables` otherwise.

The installer treats `proton-docker-watch@INSTANCE.service` as opt-in. For this five-instance fleet, enable all five watchers; see the [Docker network watcher](docs/architecture/host-routing-and-tunnels.md#docker-network-watcher).

Do not rename, consolidate, or remove any script listed here without explicit instruction.

## Managed and Routed Services

This repository directly manages Proton routing and port synchronization for the five qBittorrent instances owned by Lidarr, Prowlarr, Radarr, Sonarr, and Whisparr. Other applications on the protected Docker routing path (NZBget, Bazarr, Cross-seed, Reaparr, Flaresolverr, Autobrr, Plex, Seer, Mousehole, Profilarr, Soularr, Upbrr, and the *arr apps themselves) are owned elsewhere. Prometheus is no longer used and is not in scope.

## Requirements and Prerequisites

This deployment targets a Debian/Ubuntu Linux host with systemd, root administration, Docker Engine and the Compose plugin, WireGuard tools, iproute2, NAT-PMP (`natpmpc`), curl, flock, and the selected firewall backend. The NAS readiness gate also requires `nc`. ShellCheck, shfmt, Git, and Bats are development tools; there is no application build or PowerShell runtime.

Before first activation, provide independent port-forward-capable WireGuard identities, the external `starr_network`, writable NAS mounts, and the five Compose projects and qBittorrent config directories. The installer installs common Compose policy and examples; it does not provision the NAS, Docker network, or all five project wrappers. See the [fleet contract](docs/architecture/qbittorrent-fleet-contract.md) for the required shape. If the qBittorrent containers have been removed, use the installed [fleet recreate bootstrap](docs/runbooks/qbittorrent-port-sync.md#recreating-a-fleet-whose-containers-were-removed); do not use `docker run` or bare `docker compose up`.

The installer checks its Proton Debian package list and may download the Proton apt repository package and install `protonvpn`. That package step is not a complete host dependency provisioner. Review host routing and management access before approving installation: it restarts the host kill switch.

## Authentication Requirements

Each protected `qbittorrent.env` supplies `QBITTORRENT_URL`, `QBITTORRENT_USER`, and `QBITTORRENT_PASS` for that instance’s Web API. Use its published host Web UI endpoint and enter credentials through an operator-controlled editor such as `sudoedit`. Keep the file root-owned with mode `0600`; it is sourced as shell code, so quote values correctly and treat write access as privileged. Never put real credentials in command examples, shell history, tickets, or this repository.

The installer retains `/etc/proton/qbittorrent.env` and `--qb-*` options for singleton compatibility. Those options do not configure all five named clients. Use the per-instance files below for fleet configuration; obsolete singleton services are disabled during installation.

## Named qBittorrent Instances

The templated service path supports one Proton/qBittorrent failure domain per workload: `lidarr`, `prowlarr`, `radarr`, `sonarr`, and `whisparr`. Use `prowlarr` for manual downloads; Prowlarr itself still manages indexers normally. The installer creates `proton.env.example` and `qbittorrent.env.example` under `/etc/proton/instances/<instance>/`; copy them to `proton.env` and `qbittorrent.env` and keep real files root owned with mode `600`.

Each instance uses the same unique `qbittorrent-<instance>` value for both
`QBT_CONTAINER_NAME` and `QBT_COMPOSE_SERVICE`. This prevents Docker DNS alias
collisions on a shared network while allowing the port-forward synchronizer to
recreate the correct Compose service.

| Instance | qBittorrent | Web UI | Interface | Tunnel subnet |
| --- | --- | --- | --- | --- |
| `lidarr` | `qbittorrent-lidarr` | `8081` | `pvlidarr` | `10.2.0.2/32` |
| `prowlarr` | `qbittorrent-prowlarr` | `8082` | `pvprowlarr` | `10.6.0.2/32` |
| `radarr` | `qbittorrent-radarr` | `8083` | `pvradarr` | `10.3.0.2/32` |
| `sonarr` | `qbittorrent-sonarr` | `8084` | `pvsonarr` | `10.4.0.2/32` |
| `whisparr` | `qbittorrent-whisparr` | `8085` | `pvwhisparr` | `10.5.0.2/32` |

Each instance has its own WireGuard identity, interface, tunnel subnet (`WG_ADDRESS_SUBNET`), runtime state, and forwarded-port artifact, even when two instances select the same Proton server. See [same-server and multi-tunnel isolation](docs/architecture/host-routing-and-tunnels.md#same-server-and-multi-tunnel-isolation).

## qBittorrent Port Update Behavior

When Proton assigns a new forwarded port, the synchronizer updates qBittorrent, atomically writes the per-instance one-key artifact (`QBT_PUBLISHED_PORT`), and recreates only the owning Compose service. `QBT_FORWARDED_PORT` is obsolete. Every instance wrapper requires both `QBT_HOST_BIND_IP` and an explicitly injected `QBT_PUBLISHED_PORT`; there is no `0.0.0.0` bind fallback, so a bare `docker compose up` fails safely. The step-by-step flow, manual-stop handling, and failure cases are in the [port synchronization runbook](docs/runbooks/qbittorrent-port-sync.md).

A single `D` snapshot can be ordinary transient CIFS I/O; persistent `D` state or a zombie is a host-recovery boundary. Use the [wedge recovery runbook](docs/runbooks/qbittorrent-wedge-recovery.md) before issuing further Docker commands.

## Installation

Run the installer from the project bundle directory that contains the scripts, service files, and environment templates together.

Example:

```bash
cd /usr/local/bin/proton_project &&
sudo ./install-proton-systemd.sh
```

The installer copies files and secures secrets but does not restart templated instance chains; see [installer behavior](docs/architecture/host-routing-and-tunnels.md#installer-behavior). After installation, run the protected fleet preflight and explicitly restart/reconcile the affected instance chains. A shared qBittorrent change is not complete until all five instances pass the runtime verifier.

## Upgrade and Redeploy

Re-running `install-proton-systemd.sh` is the preferred way to copy and secure the canonical scripts, units, shared Compose policy, manifest, examples, and verification tools. It intentionally does not stop and restart every active templated instance chain during the file-copy phase. An operator must perform a controlled, sequential rollout after installation so a pre-existing unhealthy member cannot turn a deployment into an uncontrolled partial outage.

For a shared qBittorrent Compose/image/init change:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --preflight &&
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The recreate command performs the final runtime verification itself. Keep dependent commands joined with `&&`; newline-separated commands can hide a failed rollout behind a later successful verifier exit status.

For shared Proton/systemd code, reload units if needed and restart the affected templated chains sequentially, stopping on the first failure. Then run:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

Do not use a Prowlarr-only redeploy sequence as a fleet upgrade. Follow the [fleet change runbook](docs/runbooks/qbittorrent-fleet-changes.md), which defines preflight, health-gated rollout, rollback, and final all-instance acceptance.

## Archive Analysis Requirement

Any significant routing, firewall, reconnect, qBittorrent sync, or Docker networking change must compare the active implementation with `/archive`, explaining what the archived implementation did differently, why it worked initially, and why it became unstable (race conditions, route or DNS leaks, firewall drift, stale policy routing, reconnect edge cases, Docker/systemd ordering).

If `/archive` is absent or empty, note that explicitly and proceed without archive comparison.

## Security Considerations

1. Keep WireGuard and qBittorrent credential files root owned and mode `600`
2. Do not overwrite existing secrets during reinstall or upgrade
3. Avoid storing Proton credentials or other sensitive values in plaintext unless the risk is documented and accepted
4. Keep service privileges, mounts, and capabilities to the minimum required
5. Do not expose Docker hosted application services to WAN outside the intended design
6. Log enough information to debug reconnect, routing, firewall, and port forwarding failures without logging secrets

## Evidence and Change Standard

When evaluating or changing this repository:

1. Do not speculate without workspace evidence
2. Separate confirmed findings from hypotheses
3. Do not claim root cause without file evidence, command output, or reproducible behavior
4. Be explicit about whether the active firewall control plane is `iptables` or `nftables`
5. Do not mix `iptables` and `nftables` in recommendations unless the existing repository already depends on both and the interaction is explained clearly

## Troubleshooting

- For stale ports, lease expiry, API failures, or Docker mapping drift, use the
  [port synchronization runbook](docs/runbooks/qbittorrent-port-sync.md).
- For shared rollout failures or source-to-installed version mismatches, use the
  [fleet change runbook](docs/runbooks/qbittorrent-fleet-changes.md).
- For unhealthy containers, failed shutdown, zombies, or persistent kernel
  `D` state, stop mutation and use the
  [wedge recovery runbook](docs/runbooks/qbittorrent-wedge-recovery.md).

Collect the affected instance, timestamps, source revision, failed command and
exit status, and redacted logs. Do not include credentials, WireGuard private
keys, protected environment files, or unredacted API responses.

## Testing Procedures

Run from `/usr/local/bin/proton_project`:

```bash
timeout --kill-after=5s 300s env BATS_TEST_TIMEOUT=30 ./bats-core/bin/bats tests &&
shellcheck -x ./*.sh tools/*.sh &&
shfmt -d ./*.sh tools/*.sh || exit
for script in ./*.sh tools/*.sh; do bash -n "$script" || exit; done
git diff --check
```

CI additionally checks tracked shell formatting with shfmt and runs `shellcheck -x`. Use the pinned `bats-core/bin/bats` checkout for local tests; do not modify the upstream runner to accommodate a Proton failure. Keep tests isolated with temporary fixtures and mocked host commands.

## Contribution and Support

Follow [AGENTS.md](AGENTS.md) for contribution and safety requirements. A change record should identify the problem, per-instance or shared scope, implementation, validation, documentation impact, and any authorized deployment/rollback steps. Source tests do not establish installed provenance or live fleet health. No named support owner, on-call contact, or SLA is declared; report defects through the repository’s issue/PR process or the host operator’s channel with redacted evidence.
