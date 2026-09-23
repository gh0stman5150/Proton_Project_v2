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

Source follow-up, 2026-09-13: a confirmed multi-owner IPv4 fallback-route defect
caused ordinary Docker applications to change Proton tunnels during active TLS
connections. The canonical source now assigns the subnet fallback to one stable
owner while preserving every qBittorrent-specific tunnel. The change passed the
complete source suite but still requires privileged deployment and live
acceptance. See the [incident record](docs/incidents/2026-09-13-docker-proton-fallback-route-churn.md).

## Detailed Documentation

The qBittorrent fleet has dedicated architecture, operations, and incident documentation:

1. [Fleet architecture and invariants](docs/architecture/qbittorrent-fleet-contract.md) defines the shared five-instance contract and the permitted instance-specific fields.
2. [Port synchronization runbook](docs/runbooks/qbittorrent-port-sync.md) traces a Proton NAT-PMP lease through qBittorrent, the one-key artifact, and Docker TCP/UDP mappings.
3. [Fleet change runbook](docs/runbooks/qbittorrent-fleet-changes.md) enforces “change one, change all” for shared code, Compose policy, init hooks, storage, and qBittorrent preferences.
4. [Wedge recovery runbook](docs/runbooks/qbittorrent-wedge-recovery.md) distinguishes an application failure from a Docker/runtime wedge and an unkillable kernel `D`-state failure.
5. [2026-08-14 Sonarr incident report](docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md) preserves the timeline, evidence, root-cause assessment, and corrective actions.
6. [2026-09-13 Docker Proton fallback-route incident](docs/incidents/2026-09-13-docker-proton-fallback-route-churn.md) documents the cross-container DNS/TLS symptoms, routing evidence, single-owner correction, deployment status, and acceptance gates.

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

## Architecture and Workflow Overview

This host is single homed on one Ethernet interface.

The intended routing model is:

1. SSH and RDP run on bare metal
2. SSH and RDP bypass the VPN for both inbound and outbound traffic
3. Docker hosted application services use the WireGuard path
4. Docker hosted application services must not leak directly to WAN if the VPN drops
5. The kill switch only needs to protect Docker hosted application traffic
6. Host traffic outside Docker does not need to be blocked by the kill switch unless explicitly required elsewhere

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

The installer’s `SCRIPTS` list and the units’ `ExecStart`/`ExecStop` fields define installed entrypoints. Other root scripts include maintenance and deployment helpers; inspect their behavior before running them.

The kill switch dispatcher defaults to `KILLSWITCH_BACKEND=auto`. It prefers `nftables` when `nft` is available and falls back to `iptables` otherwise.

The installer treats `proton-docker-watch@INSTANCE.service` as opt-in. For this
five-instance fleet, enable all five watchers: Docker recreation can change
container addresses outside the synchronizer. See the Docker Network Watcher
section for event and periodic reconciliation behavior.

Do not rename, consolidate, or remove any script listed here without explicit instruction.

## Managed and Routed Services

This repository directly manages Proton routing and port synchronization for
the five qBittorrent instances owned by Lidarr, Prowlarr, Radarr, Sonarr, and
Whisparr. The following applications may use the protected Docker routing path,
but their lifecycle and application configuration are owned elsewhere:

1. NZBget
2. Lidarr
3. Radarr
4. Sonarr
5. Whisparr
6. Bazarr
7. Prowlarr
8. Cross-seed
9. Reaparr
10. Flaresolverr
11. Autobrr
12. Plex
13. Seer
14. Mousehole
15. Profilarr
16. Soularr
17. Upbrr

Prometheus is no longer used and is not in scope for this repository.

## Requirements and Prerequisites

This deployment targets a Debian/Ubuntu Linux host with systemd, root administration, Docker Engine and the Compose plugin, WireGuard tools, iproute2, NAT-PMP (`natpmpc`), curl, flock, and the selected firewall backend. The NAS readiness gate also requires `nc`. ShellCheck, shfmt, Git, and Bats are development tools; there is no application build or PowerShell runtime.

Before first activation, provide independent port-forward-capable WireGuard identities, the external `starr_network`, writable NAS mounts, and the five Compose projects and qBittorrent config directories. The installer installs common Compose policy and examples; it does not provision the NAS, Docker network, or all five project wrappers. See the [fleet contract](docs/architecture/qbittorrent-fleet-contract.md) for the required shape. If the qBittorrent containers have been removed, use the installed [fleet recreate bootstrap](docs/runbooks/qbittorrent-port-sync.md#recreating-a-fleet-whose-containers-were-removed); do not use `docker run` or bare `docker compose up`.

The installer checks its Proton Debian package list and may download the Proton apt repository package and install `protonvpn`. That package step is not a complete host dependency provisioner. Review host routing and management access before approving installation: it restarts the host kill switch.

## Authentication Requirements

Each protected `qbittorrent.env` supplies `QBITTORRENT_URL`, `QBITTORRENT_USER`, and `QBITTORRENT_PASS` for that instance’s Web API. Use its published host Web UI endpoint and enter credentials through an operator-controlled editor such as `sudoedit`. Keep the file root-owned with mode `0600`; it is sourced as shell code, so quote values correctly and treat write access as privileged. Never put real credentials in command examples, shell history, tickets, or this repository.

The installer retains `/etc/proton/qbittorrent.env` and `--qb-*` options for singleton compatibility. Those options do not configure all five named clients. Use the per-instance files below for fleet configuration; obsolete singleton services are disabled during installation.

## Configuration

### Named qBittorrent Instances

The templated service path supports one Proton/qBittorrent failure domain per workload. Supported instance names are:

1. `lidarr`
2. `radarr`
3. `sonarr`
4. `whisparr`
5. `prowlarr`

Use `prowlarr` for manual downloads. Prowlarr itself can still manage indexers normally; this instance is the dedicated qBittorrent target for one-off/manual releases.

The installer creates example files under `/etc/proton/instances/<instance>/`:

1. `proton.env.example`
2. `qbittorrent.env.example`

Copy those to `proton.env` and `qbittorrent.env`, then keep real config files root owned with mode `600`. The generated defaults are shown below.

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

### Same Server and Multi Tunnel Isolation

The implementation must support five independent Proton connections even when multiple instances use the same Proton VPN server. Sharing a Proton server endpoint is allowed; sharing a tunnel identity, interface, qBittorrent target, runtime state, or forwarded-port artifact is not.

Proton's NAT-PMP forwards exactly one port per client tunnel address, not per server. Connecting five tunnels with the same client address (`10.2.0.2`) therefore returns the same forwarded port to every instance and the published host ports collide. Proton supports multiple simultaneous tunnels on a single account by giving each tunnel config a distinct client address subnet (`10.2.0.x`, `10.3.0.x`, ...), each with its own gateway/DNS (`10.2.0.1`, `10.3.0.1`, ...). Each distinct client address receives an independent forwarded port.

Each instance therefore sets `WG_ADDRESS_SUBNET=<n>` in its `proton.env`. The instance loader derives everything from it so the address, DNS, and NAT-PMP gateway can never drift apart:

1. `WG_TUNNEL_ADDRESS=10.<n>.0.2/32`
2. `WG_TUNNEL_DNS=10.<n>.0.1`
3. `NATPMP_GATEWAY=10.<n>.0.1`

The shared pool configs under `WG_POOL_DIR` keep their original `10.2.0.2/32` address for linting; only the per-instance runtime copy in `WG_RUNTIME_DIR` is rewritten to the instance subnet by `proton-wg-up-safe.sh`.

The local WireGuard interface name and runtime config path are keyed on the instance (`pv<inst>`), never on the selected server. Two instances may select the same Proton server, but they keep independent local interfaces and independent NAT-PMP requests. Server selection is serialized by a global lock so two instances never adopt the same pool config (same WireGuard key) concurrently, which Proton would otherwise collapse into a single session.

Each instance must define its own values:

```bash
INSTANCE_NAME=prowlarr
WG_PROFILE=pvprowlarr
VPN_INTERFACE=pvprowlarr
WG_CONFIG=/etc/proton/instances/prowlarr/wireguard.conf
WG_ADDRESS_SUBNET=6
STATE_DIR=/run/proton/prowlarr
QBT_PORT_ENV_FILE=/etc/proton/instances/prowlarr/qbittorrent-port.env
```

Each instance must use its own WireGuard identity, preferably generated as a separate Proton WireGuard config. Two configs may point at the same Proton server endpoint, but they still must be separate files with separate interface names, separate tunnel subnets, and separate runtime/service state.

Tests cover accepted instance names, isolated configuration and state, derived subnet/gateway values, and templated service relationships. Preserve those contracts when extending the shared loader. For approved activation or recovery, follow the [sequential fleet procedure](docs/runbooks/qbittorrent-wedge-recovery.md); do not treat the deployed five-instance design as an unfinished singleton migration.

## qBittorrent Port Update Behavior

When Proton assigns a new forwarded port, the default compose-recreate path must:

1. Detect the new forwarded port automatically
2. Update the qBittorrent listening port automatically
3. Atomically update the per-instance `QBT_PORT_ENV_FILE`, `/etc/proton/instances/<instance>/qbittorrent-port.env`
4. Recreate the matching Compose service when the applied artifact or Docker TCP/UDP mappings differ from the live port, or an authorized fleet rollout forces recreation
5. Skip ordinary recreation when the artifact and Docker mappings already match; an unreachable Web UI can trigger guarded self-heal
6. Verify that qBittorrent is listening on the expected port after the recreate path completes
7. Keep legacy host-side DNAT support only when `QBT_PORT_APPLY_MODE=legacy-dnat`
8. Confirm that qBittorrent remains bound only to the intended VPN path
9. Refuse ordinary self-heal for a running container with no published ports. Missing metadata is a refusal condition, not proof of a kernel wedge. Forced fleet reconciliation can repair missing mappings only after the other safety gates pass; zombie and persistent `D`-state refusals still apply.

The per-instance artifact contains exactly one assignment:

```dotenv
QBT_PUBLISHED_PORT=<last-applied-port>
```

`QBT_FORWARDED_PORT` is obsolete and must not be present. The Compose project `.env` is a separate static file containing only `QBT_HOST_BIND_IP`; the sync script rejects any attempt to use it as the dynamic artifact. In compose-recreate mode the script injects `QBT_PUBLISHED_PORT` into the matching `docker compose` process, so qBittorrent does not need write access to the project tree.

Every instance wrapper requires both `QBT_HOST_BIND_IP` and an explicitly injected `QBT_PUBLISHED_PORT`. There is no `0.0.0.0` bind fallback and no automatic torrent-port fallback. A bare `docker compose up` therefore fails safely instead of publishing a stale or WAN-wide port; use the Proton allocator/synchronizer.

With `QBT_RESPECT_MANUAL_STOP=1`, the sync script treats an existing qBittorrent container in `created`, `exited`, `dead`, or `removing` state as intentionally stopped and skips compose recreation. The exception is an unchanged `created` or `exited` container recorded as stopped by an unfinished automated recreation; retry still requires a fresh lease and the normal safety gates. A different container ID or stop timestamp invalidates that exception. It also treats recent Docker stop or network-disconnect events as a stop in progress for `QBT_MANUAL_STOP_EVENT_GRACE_SECONDS`, so a graceful qBittorrent shutdown is not mistaken for a wedged Web UI. Set `QBT_RESPECT_MANUAL_STOP=0` only if Proton should bring stopped qBittorrent containers back up automatically.

When the Web UI is unreachable at sync startup, compose-recreate mode attempts one self-heal recreate. Before doing so, it checks the current Docker container state. If the named qBittorrent container is still `running` but Docker reports no published ports, the script logs an error and exits without rewriting the published-port artifact and without running Compose. This protects the host from the qBittorrent/s6 shutdown wedge where the old container still owns the Docker name and each recreate attempt produces a new `<shortid>_qbittorrent-<instance>` orphan.

`QBITTORRENT_URL` should point to the host published qBittorrent Web UI endpoint. Host systemd services cannot assume direct reachability to Docker network names unless that path is explicitly published or proxied.

### qBittorrent Wedged-Container Recovery

The synchronizer now checks three unsafe states before attempting Compose self-heal:

1. the named container is running but has lost its published-port metadata;
2. a container process is a zombie;
3. the same container LWP remains in uninterruptible kernel `D` state across multiple samples.

A single `D` snapshot can be ordinary transient CIFS I/O, so automation samples LWP IDs before refusing recreation. Persistent `D` state is a host-kernel recovery boundary. The 2026-08-14 Sonarr incident included the same qBittorrent thread blocked in `folio_wait_bit_common` after a CIFS/netfs kernel oops. Signals, `cgroup.kill`, Docker removal, Compose recreation, and killing `containerd-shim` cannot make a task return from damaged in-kernel I/O state. Preserve evidence and obtain approval for a host reboot; do not repeat destructive runtime cleanup.

Use the full [wedge recovery runbook](docs/runbooks/qbittorrent-wedge-recovery.md). It provides the evidence commands, `S`/`Z`/`D` decision tree, reboot preparation, CIFS post-boot gate, sequential Proton restart, and five-instance acceptance criteria.

## Installation

Run the installer from the project bundle directory that contains the scripts, service files, and environment templates together.

Example:

```bash
cd /usr/local/bin/proton_project &&
sudo ./install-proton-systemd.sh
```

The installer:

1. Ensures the required Proton VPN Debian packages are installed, bootstrapping the Proton VPN apt repository and installing `protonvpn` if any are missing
2. Leaves active templated instance chains running while files are copied; deployment alone is not a process restart or fleet rollout
3. Copies the active Proton scripts, including the executable allocator and fleet tools, to `/usr/local/bin/proton`
4. Copies systemd units to `/etc/systemd/system`; no unit executes from the source checkout
5. Installs the shared qBittorrent Compose policy and canonical instance manifest under `/opt/qbittorrent-common`
6. Copies environment templates to `/etc/proton`
7. Secures active WireGuard and protected environment files as `root:root` with mode `600`
8. Preserves existing secrets and writes replacement templates to `*.new` files rather than overwriting them
9. Canonicalizes each existing per-instance port artifact to exactly one validated `QBT_PUBLISHED_PORT` assignment while preserving its value
10. Reconciles `VPN_TABLE`, `QBT_VPN_RULE_PRIORITY`, and `QBT_INSTANCE_NAME` into existing protected instance configs without changing credentials or WireGuard secrets
11. Installs units that have systemd recreate `/run/proton` before applying sandboxed writable paths
12. Resets failed unit state without restarting active templated instance chains
13. Runs `systemctl daemon-reload`
14. Disables the obsolete singleton units, enables/restarts the host kill switch, and leaves templated instance startup/reconciliation to the operator

After installation, run the protected fleet preflight and explicitly restart/reconcile the affected instance chains. A shared qBittorrent change is not complete until all five instances pass the runtime verifier.

Configure credentials in each protected instance file as described above. Do not use installer command-line password arguments for normal fleet setup.

After the base install, include all five `proton-docker-watch@INSTANCE.service`
units in the approved sequential fleet activation. File installation alone does
not enable those watchers or upgrade running producer loops.

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

## Runtime State

Per-instance state lives under `/run/proton/<instance>/`, including `proton-port.state`, `qbt-port.cache`, `docker-network-cidr`, `current-server.env`, `reselect-server.flag`, `recovery.lock`, and `qbt-sync.lock`.

Host-wide coordination remains under `/run/proton`, including `policy-routing.lock`, `killswitch.lock`, server selection locking, `bad-servers.tsv`, and `pf-incapable-strikes.tsv`. Shared profile capability lists persist under `/etc/proton`. The loader rebases legacy per-instance paths; do not copy singleton runtime paths into new instance examples.

Do not store live state files in the repository.

State under `/run/proton` must be treated as runtime data only and must be recreated safely across service restart, VPN reconnect, and host reboot events.

Port state is usable only with a valid port, expected tunnel address, unexpired
lease, current boot ID, and matching `tunnel-generation`. The producer publishes
atomically only after matching UDP/TCP mappings and uses the shortest granted
lifetime. Two-field legacy state and persistent port artifacts are not fresh
leases. Slow bounded sync runs separately from renewal; allocator commands share
one overall deadline. See the [lease schema and timing contract](docs/runbooks/qbittorrent-port-sync.md#live-proton-lease).

Keep lifecycle, route, firewall, selector, and NAT-PMP lock paths intact. File
existence is not lock ownership; never unlink a lock to force progress. Selector
state errors abort publication, and failed firewall inspection is not absence.

## Server Pool and Latency Selection

If `/etc/wireguard/proton-pool` contains one or more `*.conf` files, the active path treats that directory as a rotation pool. Reconnect or bad node recovery may select the lowest latency candidate by probing the endpoint IP from each config.

The selector stores the active choice in `/run/proton/<instance>/current-server.env` and tracks cooldowns in `/run/proton/bad-servers.tsv`. It uses hysteresis so the current server is kept unless a replacement is meaningfully better or the current server is degraded.

When `PORT_FORWARD_REQUIRED=on`, the pool also learns which profiles have actually returned a Proton forwarded port. Successful profiles are recorded in `PF_CAPABLE_PROFILES_FILE`, failed profiles can be recorded in `PF_INCAPABLE_PROFILES_FILE`, and the selector effectively treats the pool as three categories:

1. `proven-good` which are in `PF_CAPABLE_PROFILES_FILE`
2. `unproven` which are in neither file yet
3. `port-forward incapable` which are in `PF_INCAPABLE_PROFILES_FILE`

`port-forward incapable` remains a hard exclusion until the profile is proven again or the incapable state is reset. When the proven-good set is non-empty, the selector prefers those proven-good nodes first. If every proven-good node is temporarily cooling down or otherwise unavailable, the selector can temporarily widen to healthy unproven nodes instead of immediately recycling a cooling-down proven-good node.

### Transient failures versus quarantine

The port-forward loop distinguishes a temporary NAT-PMP hiccup from a genuinely port-forward incapable server:

1. When a **proven-good** server (one already in `PF_CAPABLE_PROFILES_FILE`) hits `MAX_FAILURES`, the failure is treated as transient. The tunnel is kept and retried in place so the forwarded port stays stable and qBittorrent's published port -- and therefore its container -- is not recreated. Only after `PROVEN_TRANSIENT_MAX_KEEPS` consecutive transient windows without a successful port does it fall back to a full reconnect.
2. When an **unproven** server hits `MAX_FAILURES`, the port-forward loop records a consecutive incapability strike via `proton-server-manager.sh mark-incapable-attempt` and reconnects to a different server. Strikes accumulate in `/run/proton/pf-incapable-strikes.tsv` and reset the instant the server proves it can forward a port (`mark-capable`).
3. Once an unproven server accumulates `PF_INCAPABLE_STRIKE_THRESHOLD` consecutive strikes (default 3), the server manager quarantines it in `PF_INCAPABLE_PROFILES_FILE`. Its pool config remains in `WG_POOL_DIR` for review. A proven-good server is not quarantined by transient strikes; it is only cooled down.

This avoids unnecessary rotation during transient failures without deleting
operator-managed pool configurations. Claims reserve profiles, not endpoint IPs
or numeric ports. Interrupted selection publication may retain a conservative
claim until retry or expiry; do not bypass it by deleting shared state.

The port-forward service must be able to write both `/etc/proton` for the learned PF-capable/incapable lists and the directory containing `QBT_PORT_ENV_FILE` for Compose port-artifact updates.

By default the selector lints each candidate before selection. It rejects configs that contain `PreUp`, `PostUp`, `PreDown`, `PostDown`, or `SaveConfig`, and it expects `DNS` to match `WG_EXPECTED_DNS` unless `WG_LINT_ALLOW_MISSING_DNS=on`.

Useful knobs:

1. `WG_POOL_DIR=/etc/wireguard/proton-pool`
2. `SERVER_POOL_ENABLED=auto`
3. `BAD_SERVER_COOLDOWN=900`
4. `SERVER_SWITCH_MIN_IMPROVEMENT_MS=10`
5. `SERVER_SWITCH_DEGRADED_LATENCY_MS=75`
6. `PING_TIMEOUT_SECONDS=1`
7. `PING_COUNT=1`
8. `SERVER_POOL_STRICT_LINT=on`
9. `WG_EXPECTED_DNS=10.2.0.1`
10. `WG_LINT_ALLOW_MISSING_DNS=off`
11. `PORT_FORWARD_REQUIRED=on`
12. `PF_CAPABLE_PROFILES_FILE=/etc/proton/pf-capable-profiles.tsv`
13. `PF_INCAPABLE_PROFILES_FILE=/etc/proton/pf-incapable-profiles.tsv`
14. `PF_INCAPABLE_STRIKES_FILE=/run/proton/pf-incapable-strikes.tsv`
15. `PF_INCAPABLE_STRIKE_THRESHOLD=3`
16. `PROVEN_TRANSIENT_MAX_KEEPS=5` (set in `proton-port-forward.env`)

Manual helpers:

1. `proton-server-manager.sh select`
2. `proton-server-manager.sh current`
3. `proton-server-manager.sh mark-bad <profile> <reason>`
4. `proton-server-manager.sh show-bad`
5. `proton-server-manager.sh reset-bad`
6. `proton-server-manager.sh mark-capable <profile> <port>`
7. `proton-server-manager.sh mark-incapable <profile> <reason>`
8. `proton-server-manager.sh mark-incapable-attempt <profile> <reason>`
9. `proton-server-manager.sh show-capable`
10. `proton-server-manager.sh show-incapable`
11. `proton-server-manager.sh show-incapable-strikes`
12. `proton-server-manager.sh reset-capable`
13. `proton-server-manager.sh reset-incapable`
14. `proton-server-manager.sh reset-incapable-strikes`

Any server rotation logic must preserve the repository routing rules, kill switch behavior, qBittorrent port synchronization, and DNS policy after reconnect.

## WireGuard Defaults

Shared compatibility defaults include the following; named services override profile/interface identity through their instance configuration:

1. `WG_PROFILE=proton`
2. `VPN_INTERFACE=proton`
3. `NATPMP_GATEWAY=10.2.0.1`
4. `MANAGEMENT_ALLOWED_CIDRS=<LAN_CIDR>,<YOUR_WAN_IP>/32`
5. `MANAGE_RESOLVED_DNS=auto`
6. `RESOLVED_DNS_ROUTE_DOMAIN=~.`
7. `WG_PERSISTENT_KEEPALIVE=25`

Set real values in environment files, not in committed documentation.

The up script filters each pool config into a runtime config and injects `PersistentKeepalive = <WG_PERSISTENT_KEEPALIVE>` into the `[Peer]` section when the source config omits it (an existing value is preserved, never duplicated). The keepalive stops Proton from dropping an idle tunnel's session and NAT-PMP mapping between port-forward polls, which is the main source of intermittent `natpmpc` timeouts. Set `WG_PERSISTENT_KEEPALIVE=0` to disable injection.

For the templated per-instance services, `NATPMP_GATEWAY` is not taken from this shared default. When an instance sets `WG_ADDRESS_SUBNET=<n>`, the instance loader derives `NATPMP_GATEWAY=10.<n>.0.1` (and the matching tunnel address and DNS) so each instance requests its forwarded port from its own gateway. See "Same Server and Multi Tunnel Isolation".

If your WireGuard profile or interface uses different names, update the environment files consumed by:

1. `proton-killswitch.service`
2. `proton-wg@<instance>.service`
3. `proton-port-forward@<instance>.service`
4. `proton-healthcheck@<instance>.service`

IPv6 support is conditional: the nftables backend supports configured Docker IPv6 policy, while the iptables backend refuses a configured Docker IPv6 subnet. Source capability does not establish live activation status.

### IPv6 Safe Rollout

IPv6 rollout is staged so recovery is proven before Docker networking changes. The current stage supports one tunnel-only canary while Docker remains IPv4-only.

Run the read-only checks from the repository first:

```bash
sudo ./proton-ipv6-rollout.sh status
sudo ./proton-ipv6-rollout.sh preflight
```

`preflight` must confirm all of the following before a snapshot is allowed:

1. `WG_IPV6_ENABLED` is off
2. `starr_network` has IPv6 disabled
3. The nftables kill-switch backend is selected or available through `auto`
4. The commands needed to capture and restore network state are installed

Create the rollback point before deploying any dual-stack implementation:

```bash
sudo ./proton-ipv6-rollout.sh snapshot
```

Snapshots default to `/var/lib/proton/ipv6-rollbacks/<UTC timestamp>` and include:

1. `/etc/proton`, including root-only per-instance configuration
2. `/etc/wireguard`
3. `/etc/docker`
4. `/usr/local/bin/proton`
5. Proton systemd units and the list of active units
6. Every `QBT_COMPOSE_PROJECT_DIR` discovered from the per-instance configuration
7. IPv4 and IPv6 rules and routes, the nftables ruleset, WireGuard state, and Docker network metadata for diagnosis

The snapshot contains WireGuard keys and qBittorrent credentials. It is created with root-only permissions and must not be copied into the repository or logs.

To restore immediately:

```bash
sudo /usr/local/bin/proton/proton-ipv6-rollout.sh rollback \
  /var/lib/proton/ipv6-rollbacks/latest
```

Rollback stops every currently active Proton service, restores paths that existed at snapshot time, removes managed paths that were absent at snapshot time, reloads systemd, and starts exactly the Proton services that were active in the snapshot. Services are restored sequentially by dependency class so WireGuard instances cannot race while replacing shared policy rules. A failed service is reported without preventing the remaining baseline services from being attempted.

The controller can activate one guarded tunnel canary:

```bash
sudo /usr/local/bin/proton/proton-ipv6-rollout.sh activate-canary sonarr
```

Activation verifies that the selected Proton profile has an IPv6 interface address, IPv6 DNS, and `AllowedIPs = ::/0`. It then checks the interface address, per-instance IPv6 route table, bound-interface policy rule, outbound IPv6 connectivity, and all instance services. Any failed check automatically restores the saved instance environment and restarts that instance in IPv4-only mode.

Deactivate the canary without restoring the full snapshot:

```bash
sudo /usr/local/bin/proton/proton-ipv6-rollout.sh deactivate-canary sonarr
```

Tunnel-canary activation does not enable Docker IPv6. Source code includes nftables IPv6 enforcement and Docker IPv6 policy routing, but network recreation and live VPN-drop validation still require an approved maintenance procedure. The IPv4 NAT-PMP and qBittorrent published-port path remains unchanged.

The kill-switch scripts understand an optional `DOCKER_NETWORK_CIDR6`. When it is empty, their behavior remains IPv4-only. When it is set, the nftables backend installs IPv6 Docker-local rules, accepts Docker IPv6 only through the five managed Proton interface names and any explicitly configured legacy interface, drops every other packet sourced from or destined to the Docker IPv6 subnet, and applies NAT66 only to that subnet on those interfaces. Rules may be installed before the interfaces exist; unrelated WireGuard interfaces are not implicitly trusted. The iptables backend refuses to apply when `DOCKER_NETWORK_CIDR6` is set.

Do not populate `DOCKER_NETWORK_CIDR6` until all of these maintenance-window prerequisites are ready:

1. `KILLSWITCH_BACKEND=nftables` is explicit
2. Host IPv6 forwarding is enabled persistently
3. The external `starr_network` can be stopped and recreated with matching IPv6 IPAM
4. Every attached Compose project can be recreated after the network replacement
5. VPN-drop packet captures are ready to prove the ULA cannot leave through the WAN interface

The current external `starr_network` is referenced by many independent Compose projects, so its conversion is not an in-place toggle. Network recreation is intentionally excluded from tunnel-canary activation.

Before preparing a Docker maintenance window, run the read-only dual-stack gate with the proposed ULA:

```bash
sudo /usr/local/bin/proton/proton-ipv6-rollout.sh \
  docker-preflight fdca:6c19:2096::/64
```

This command requires an explicit `KILLSWITCH_BACKEND=nftables`, confirms the tested firewall scripts match their installed copies, validates a canonical ULA `/64`, rejects overlap with host routes or Docker networks, verifies `starr_network` is still IPv4-only, and requires host IPv6 forwarding to remain off. It does not write configuration, enable forwarding, apply nftables, restart services, or modify Docker.

Docker IPv4 and IPv6 fallback routing each have one stable owner so ordinary application traffic cannot change tunnels while a connection is active. `DOCKER_FALLBACK_INSTANCE` names the IPv4 owner and `DOCKER_IPV6_FALLBACK_INSTANCE` names the IPv6-capable owner; both default to `sonarr`. Each qBittorrent container receives a higher-priority per-container source rule for its own instance tunnel. Docker-to-Docker traffic remains in the main table. The network watcher refreshes these rules after container recreation, and WireGuard teardown removes instance-owned rules before flushing the tunnel table.

Deploy the complete inert firewall and routing bundle before a maintenance window:

```bash
sudo /usr/local/bin/proton_project/Archive/deploy-live-ipv6-firewall.sh deploy
```

The helper creates a root-only timestamped snapshot of all six installed scripts and prints its exact rollback path. It does not restart services or activate Docker IPv6.

## DNS Policy

The repository source of truth requires:

1. `1.1.1.1` as the primary upstream DNS resolver
2. `9.9.9.9` as the secondary upstream DNS resolver
3. Docker hosted application DNS queries must follow the intended VPN path
4. Docker hosted application DNS must not bypass the kill switch

When `MANAGE_RESOLVED_DNS=auto` and `resolvectl` is available, the up and down scripts may program and revert interface DNS. Treat that behavior as implementation detail, not policy by itself.

`WG_EXPECTED_DNS=10.2.0.1` is the WireGuard interface DNS provided by Proton inside the tunnel. The `1.1.1.1` and `9.9.9.9` values are external upstream resolvers used for DNS policy verification and are not substitutes for the tunnel DNS.

Do not assume DNS is correct only because WireGuard profile DNS values exist. Verify DNS behavior for:

1. host resolver configuration
2. container `/etc/resolv.conf`
3. Docker embedded DNS behavior
4. WireGuard DNS settings
5. any `systemd-resolved` integration
6. VPN down and reconnect events
7. container restarts

## Docker Egress Policy

Docker hosted application traffic must be constrained by the host level WireGuard and policy routing design defined by this repository.

Do not treat Docker egress control as optional or external to the repository architecture.

VPN bound containers must not be able to reach WAN directly outside the intended WireGuard path.

## Healthcheck

`proton-healthcheck@<instance>.service` watches qBittorrent only when there are active transfers. If combined download and upload throughput stays below the configured threshold for multiple checks, the recovery ladder is:

1. qBittorrent port and DNAT refresh
2. One shot NAT PMP refresh
3. Bad server mark plus Proton service restart

The healthcheck and port forward loop share `RECOVERY_LOCK_FILE` so they do not trigger overlapping reconnect storms.

Shared template thresholds:

1. `CHECK_INTERVAL=60`
2. `MIN_COMBINED_SPEED_BPS=65536` which is 64 KB/s
3. `MAX_LOW_SPEED_CHECKS=3`
4. `PORT_STABILITY_GRACE_SECONDS=180`

The healthcheck also pauses its low-throughput recovery ladder for a short
stabilization window after each forwarded-port update so normal NAT-PMP churn
and qBittorrent port reconfiguration do not immediately trigger another round
of recovery.

A successful one-shot NAT-PMP refresh now resets the staged ladder back to the
first step. That keeps healthy-but-slow swarms from escalating into a full
WireGuard restart just because throughput stayed below the target while the
forwarded port and qBittorrent sync path were already confirmed working.

For a bursty workload, tune shared thresholds in `/etc/proton/proton-healthcheck.env` or document an intentional override in the protected instance configuration.

Any healthcheck driven recovery must preserve:

1. Host level WireGuard routing
2. Docker application kill switch behavior
3. SSH and RDP bypass behavior
4. qBittorrent port correctness
5. DNS routing correctness

## Usage and Verification Examples

If you customized the defaults, source the relevant files under `/etc/proton` first or substitute the resolved values directly in the commands below.

### WireGuard and routing

```bash
wg show
ip rule show
ip route show table 51802
ip route show table 51803
ip route show table 51804
ip route show table 51805
ip route show table 51806
ip route show
```

### Firewall and kill switch

If the active backend is `nftables`:

```bash
sudo nft list table inet proton
sudo nft list table ip proton_nat
```

If the active backend is `iptables`, inspect the dedicated Proton chains and any policy routing related rules explicitly.

### qBittorrent state and mapping

If the active mode is `compose-recreate`:

```bash
cat /run/proton/prowlarr/proton-port.state
cat /run/proton/prowlarr/qbt-port.cache
cat /etc/proton/instances/prowlarr/qbittorrent-port.env
```

If the active mode is `legacy-dnat`:

```bash
cat /run/proton/prowlarr/proton-port.state
cat /run/proton/prowlarr/qbt-port.cache
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' qbittorrent-prowlarr
sudo nft list chain ip proton_nat prerouting -a | grep qbt-dnat
```

### DNS behavior

Verify:

1. host resolver configuration
2. container `/etc/resolv.conf`
3. Docker DNS behavior
4. DNS path during VPN up, VPN down, and reconnect events

### Leak prevention

Confirm all of the following:

1. Docker hosted application traffic uses the VPN path
2. Docker hosted application traffic is blocked from direct WAN egress during VPN downtime
3. SSH and RDP remain reachable through WAN and LAN
4. qBittorrent remains bound only to the intended VPN path

### Disruptive failure test (explicit runtime authorization required)

```bash
sudo ip link set dev pvprowlarr down
# verify Docker hosted application traffic is blocked from leaking
# verify SSH and RDP remain reachable as intended
sudo systemctl restart proton-wg@prowlarr.service proton-port-forward@prowlarr.service proton-healthcheck@prowlarr.service
```

After recovery, recheck:

```bash
wg show
ip rule show
ip route show table 51806
```

## Docker Network Watcher

If qBittorrent or other Docker hosted application services run on a bridged Docker network and routing depends on Docker network CIDR or container IP discovery, enable the per-instance watcher service to keep routing and DNAT in sync with Docker events.

The watcher listens for Docker network and container events and can:

1. Reapply Docker source-routing and raw-table return rules when the Docker network subnet changes
2. Reapply the Docker kill-switch state after Docker restarts or network changes
3. Refresh qBittorrent port state so compose-recreate or legacy-DNAT mode stays in sync

After approved installation and the fleet preflight, enable watchers sequentially
for all five instances as part of the fleet activation:

```bash
for instance in lidarr prowlarr radarr sonarr whisparr; do
  sudo systemctl enable --now "proton-docker-watch@${instance}.service" || exit
done
```

Verify watcher behavior:

```bash
ip rule show | grep 51806
ip route show table 51806
sudo nft list chain ip proton_nat prerouting -a | grep qbt-dnat
```

The watcher also reconciles periodically when no event arrives. Disabling it
removes out-of-band Docker address recovery; do not omit it from this fleet's
steady-state service coverage. A successful start is not a routing acceptance
test: verify all five instances using the fleet change runbook.

## Archive Analysis Requirement

Any significant routing, firewall, reconnect, qBittorrent sync, or Docker networking change must compare the active implementation with `/archive`.

That comparison must explain:

1. What the archived implementation did differently
2. Why it worked initially
3. Why it became unstable over time

Look specifically for:

1. Race conditions
2. Route leaks
3. DNS leaks
4. Firewall state drift
5. Stale policy routing
6. Reconnect edge cases
7. Docker and systemd ordering problems

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
shellcheck -x ./*.sh tools/*.sh Archive/*.sh &&
shfmt -d ./*.sh tools/*.sh Archive/*.sh || exit
for script in ./*.sh tools/*.sh Archive/*.sh; do bash -n "$script" || exit; done
git diff --check
```

CI additionally checks tracked shell formatting with shfmt and runs `shellcheck -x`. Use the pinned `bats-core/bin/bats` checkout for local tests; do not modify the upstream runner to accommodate a Proton failure. Keep tests isolated with temporary fixtures and mocked host commands.

## Contribution Guidance

Follow [AGENTS.md](AGENTS.md) for contribution and safety requirements. A change record should identify the problem, per-instance or shared scope, implementation, validation, documentation impact, and any authorized deployment/rollback steps. Source tests do not establish installed provenance or live fleet health.

## Support and Ownership

No named support owner, on-call contact, or support SLA is declared in this repository. Report defects through the repository’s existing issue/PR process or the host operator’s established channel. Include the affected instance, timestamps, source revision, failing command and exit status, and redacted logs. The maintainer should add ownership details when confirmed; do not invent contacts.
