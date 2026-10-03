# Technical decisions

Each entry names the document that owns the detail. Incident links carry the evidence.

## Host-level routing and kill switch, no VPN container
Docker traffic is forced through per-instance WireGuard tunnels by host policy routing and firewall rules; SSH (`tcp/22`) and RDP (`tcp/3389`) bypass the VPN. A VPN or gateway sidecar is rejected unless the repository already depends on one. The host stays reachable if the VPN or Docker fails, and the kill switch protects Docker traffic only, not host traffic.
Owner: [host routing and tunnels](architecture/host-routing-and-tunnels.md).

## nftables preferred, iptables kept as fallback
`KILLSWITCH_BACKEND=auto` prefers nftables when `nft` exists. The shipped template pins `nftables` because Docker IPv6 enforcement and the IPv6 rollout preflight require it. The iptables backend refuses to apply when `DOCKER_NETWORK_CIDR6` is set rather than silently running IPv4-only. Both stay installed so a host without `nft` still gets a kill switch.

## One failure domain per qBittorrent instance
Each of the five instances has its own WireGuard identity, interface, tunnel subnet, route table, runtime state and NAT-PMP lease, derived from `WG_ADDRESS_SUBNET` and the `qbittorrent-instances.tsv` row. A tunnel or lease problem affects one instance. Shared structure (image, Compose policy, health check, init hooks, sync code) is changed once and rolled through all five sequentially ("change one, change all"). Runtime values are never copied between instances.
Owner: [fleet contract](architecture/qbittorrent-fleet-contract.md), [fleet change runbook](runbooks/qbittorrent-fleet-changes.md).

## A lease change recreates only its owning container
The synchronizer pushes the port to the qBittorrent API, writes a one-key `QBT_PUBLISHED_PORT` artifact atomically, and recreates the owning Compose service. `compose-recreate` is the only supported apply mode (`legacy-dnat` is rejected). Compose requires an injected port and VPN bind IP with no `0.0.0.0` fallback, so a bare `docker compose up` fails safely instead of binding a stale or non-VPN address. `QBT_FORWARDED_PORT` is obsolete.
Owner: [port synchronization runbook](runbooks/qbittorrent-port-sync.md).

## Leases are generation-bound and short-lived
Port state is usable only with a valid port, the expected tunnel address, an unexpired lease, the current boot ID and a matching `tunnel-generation`. The shortest granted lifetime wins, and producers publish only after matching UDP and TCP mappings. Legacy two-field state and persistent artifacts are never treated as fresh leases. The goal is that a stale port can never be applied after a reconnect or reboot.

## Transient failures do not rotate a proven server
A server already in `PF_CAPABLE_PROFILES_FILE` that hits `MAX_FAILURES` is retried in place, so the forwarded port and the container stay stable. A full reconnect follows only after `PROVEN_TRANSIENT_MAX_KEEPS` consecutive windows without a port. Unproven servers accumulate strikes (`PF_INCAPABLE_STRIKE_THRESHOLD`, default 3) before quarantine, and quarantine only records the profile, never deletes its config.
Owner: [server pool runbook](runbooks/server-pool-selection.md).

## Serialized mutation under named locks
Policy-route changes take `/run/proton/policy-routing.lock` and firewall changes take `/run/proton/killswitch.lock`. Ordinary per-instance sync is non-blocking and may skip; forced fleet sync waits and fails on timeout rather than reporting success without recreating. Lock files are never unlinked to force progress, because file existence is not lock ownership.

## Wedge detection samples task IDs
A zombie is an immediate refusal to recreate. A single `D`-state snapshot can be ordinary CIFS I/O, so only the same task persisting across samples is a wedge, which is treated as a host-kernel recovery boundary (coordinated reboot, no signal or Docker-cleanup escalation).
Evidence: [2026-08-14 incident](incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md). `cache=none` on `/mnt/data` is the mitigation, not a demonstrated kernel fix.

## Single owner for Docker fallback routing
IPv4 and IPv6 fallback routes each have one stable owner (`DOCKER_FALLBACK_INSTANCE`, `DOCKER_IPV6_FALLBACK_INSTANCE`, both defaulting to `sonarr`), and each qBittorrent container gets a higher-priority source rule for its own tunnel. This stops ordinary application traffic from switching tunnels mid-connection.
Evidence: [2026-09-13 incident](incidents/2026-09-13-docker-proton-fallback-route-churn.md).

## The installer never restarts the kill switch
`docker.service` requires the kill switch, so restarting it would restart Docker and every container. The installer reloads the unit (or starts it if inactive). It copies files without restarting templated instance chains, so operators roll out sequentially and a pre-existing unhealthy member cannot turn a deploy into a fleet outage. A proposed policy-rule sweep was reverted because it conflicted with rules owned by other services.
Evidence: [2026-09-23 incident](incidents/2026-09-23-installer-docker-restart-and-rule-sweep.md).

## Installed copies run, source never does
Systemd `ExecStart` paths must not target the checkout. Source can be edited, tested and branched without affecting the running kill switch, and source/installed parity is verified by checksum when provenance matters. Drop-ins (NAS mount ordering, Docker stop timeout) are owned by the installer, so fixes go in installer source, not in the installed files.

## IPv6 is staged
Rollout proceeds snapshot → tunnel canary → Docker dual-stack, with automatic rollback if a canary check fails. Docker IPv6 is not enabled by the canary because `starr_network` is external and shared by many Compose projects, so recreating it is a maintenance-window operation.
Owner: [IPv6 rollout runbook](runbooks/ipv6-rollout.md).

## Tests stub the host
Bats tests run the real scripts against stubbed `docker`, `curl`, `nft`, `ip`, `findmnt` and similar commands, with state and lock paths redirected through environment overrides. This keeps the suite safe to run on the live host. Runtime scripts therefore expose an override for nearly every path instead of hardcoding it. The trade-off is that tests prove control flow and never live health.
