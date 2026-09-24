# Runbook: IPv6 safe rollout

Related: [host routing and tunnels](../architecture/host-routing-and-tunnels.md).
Every mutating command here requires explicit runtime authorization.

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

Deploy the complete inert firewall and routing bundle before a maintenance window
by taking a rollout snapshot and then running the installer:

```bash
sudo ./proton-ipv6-rollout.sh snapshot &&
  sudo ./install-proton-systemd.sh
```

The snapshot includes `/usr/local/bin/proton` and logs its path; restore it with
the `rollback` command above. The installer copies the seven firewall and routing
scripts that `docker-preflight` compares (`proton-instance-common.sh`, both
kill-switch backends, `proton-killswitch-reset.sh`, `proton-wg-up-safe.sh`,
`proton-wg-down-safe.sh`, and `proton-docker-network-watcher.sh`) with the rest of
the bundle. It reloads `proton-killswitch.service` (never restarts it, which
would restart Docker) and leaves instance services running, and it does not activate Docker IPv6.
