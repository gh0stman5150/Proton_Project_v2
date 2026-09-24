# Host routing, tunnels, and runtime state

This document owns the host-side Proton design that is not specific to the
qBittorrent fleet contract: per-instance tunnel isolation, WireGuard defaults,
runtime state, DNS and egress policy, healthcheck recovery, the Docker network
watcher, and installer behavior. Fleet invariants live in the
[fleet contract](qbittorrent-fleet-contract.md); operator commands live in the
[host verification runbook](../runbooks/host-verification.md).

## Same Server and Multi Tunnel Isolation

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

Tests cover accepted instance names, isolated configuration and state, derived subnet/gateway values, and templated service relationships. Preserve those contracts when extending the shared loader. For approved activation or recovery, follow the [sequential fleet procedure](../runbooks/qbittorrent-wedge-recovery.md); do not treat the deployed five-instance design as an unfinished singleton migration.

## WireGuard Defaults

Shared compatibility defaults include the following; named services override profile/interface identity through their instance configuration:

1. `WG_PROFILE=proton`
2. `VPN_INTERFACE=proton`
3. `NATPMP_GATEWAY=10.2.0.1`
4. `MANAGE_RESOLVED_DNS=auto`
5. `RESOLVED_DNS_ROUTE_DOMAIN=~.`
6. `WG_PERSISTENT_KEEPALIVE=25`

Set real values in environment files, not in committed documentation.

The up script filters each pool config into a runtime config and injects `PersistentKeepalive = <WG_PERSISTENT_KEEPALIVE>` into the `[Peer]` section when the source config omits it (an existing value is preserved, never duplicated). The keepalive stops Proton from dropping an idle tunnel's session and NAT-PMP mapping between port-forward polls, which is the main source of intermittent `natpmpc` timeouts. Set `WG_PERSISTENT_KEEPALIVE=0` to disable injection.

For the templated per-instance services, `NATPMP_GATEWAY` is not taken from this shared default. When an instance sets `WG_ADDRESS_SUBNET=<n>`, the instance loader derives `NATPMP_GATEWAY=10.<n>.0.1` (and the matching tunnel address and DNS) so each instance requests its forwarded port from its own gateway. See [tunnel isolation](#same-server-and-multi-tunnel-isolation).

If your WireGuard profile or interface uses different names, update the environment files consumed by:

1. `proton-killswitch.service`
2. `proton-wg@<instance>.service`
3. `proton-port-forward@<instance>.service`
4. `proton-healthcheck@<instance>.service`

IPv6 support is conditional: the nftables backend supports configured Docker IPv6 policy, while the iptables backend refuses a configured Docker IPv6 subnet. Source capability does not establish live activation status.

IPv6 activation is staged; see the [IPv6 rollout runbook](../runbooks/ipv6-rollout.md).
Server selection is described in the [server pool runbook](../runbooks/server-pool-selection.md).

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
one overall deadline. See the [lease schema and timing contract](../runbooks/qbittorrent-port-sync.md#live-proton-lease).

Keep lifecycle, route, firewall, selector, and NAT-PMP lock paths intact. File
existence is not lock ownership; never unlink a lock to force progress. Selector
state errors abort publication, and failed firewall inspection is not absence.

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

1. qBittorrent port sync refresh
2. One shot NAT PMP refresh
3. Bad server mark plus Proton service restart

The healthcheck and port forward loop share `RECOVERY_LOCK_FILE` so they do not trigger overlapping reconnect storms.

The healthcheck keeps one qBittorrent Web API session across checks and logs in
again only when a request is rejected, such as after a container recreate.

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

## Docker Network Watcher

If qBittorrent or other Docker hosted application services run on a bridged Docker network and routing depends on Docker network CIDR or container IP discovery, enable the per-instance watcher service to keep routing in sync with Docker events.

The watcher listens for Docker network and container events and can:

1. Reapply Docker source-routing and raw-table return rules when the Docker network subnet changes
2. Reapply the Docker kill-switch state after Docker restarts or network changes
3. Refresh qBittorrent port state so the Compose-published port stays in sync

Each instance owns two priorities in its route table: its qBittorrent host
rule at `QBT_VPN_RULE_PRIORITY` and, for the fallback owner, the Docker subnet
rule at `DOCKER_FALLBACK_VPN_RULE_PRIORITY` (130). WireGuard bring-up and every
watcher pass remove any other rule that routes into the instance's table,
whatever its source or selector, and log each one. This clears rules left at
retired priorities, such as the old 110 default, the priority-100 fwmark rules,
or a source nothing recognizes, which the exact per-rule deletes never match.

The watcher also reconciles periodically when no event arrives. Every pass
reasserts policy routes and the kill switch; a periodic pass queues
allocation and sync only when the Docker CIDRs or qBittorrent addresses changed
or the previous queue attempt failed, because the port-forward loop runs its
own drift sync. Events that queue up during the debounce (one container
recreate emits several) are coalesced into one reconciliation. Disabling it
removes out-of-band Docker address recovery; do not omit it from this fleet's
steady-state service coverage. A successful start is not a routing acceptance
test: verify all five instances using the fleet change runbook.

Enable and verification commands are in the
[host verification runbook](../runbooks/host-verification.md#docker-network-watcher).

## Installer Behavior

The installer:

1. Ensures the required Proton VPN Debian packages are installed, bootstrapping the Proton VPN apt repository and installing `protonvpn` if any are missing
2. Leaves active templated instance chains running while files are copied; deployment alone is not a process restart or fleet rollout
3. Copies the active Proton scripts, including the executable allocator and fleet tools, to `/usr/local/bin/proton`
4. Copies systemd units to `/etc/systemd/system`; no unit executes from the source checkout
5. Installs the shared qBittorrent Compose policy and canonical instance manifest under `/opt/qbittorrent-common`
6. Copies environment templates to `/etc/proton`
7. Secures each instance's `wireguard.conf`, `proton.env`, and `qbittorrent.env` as `root:root` with mode `600`, and keeps the shared pool directory `/etc/wireguard/proton-pool` `root:root` with mode `700`; it does not change the modes of individual pool configs
8. Preserves existing secrets and writes replacement templates to `*.new` files rather than overwriting them
9. Canonicalizes each existing per-instance port artifact to exactly one validated `QBT_PUBLISHED_PORT` assignment while preserving its value
10. Reconciles `VPN_TABLE`, `QBT_VPN_RULE_PRIORITY`, and `QBT_INSTANCE_NAME` into existing protected instance configs without changing credentials or WireGuard secrets
11. Installs units that have systemd recreate `/run/proton` before applying sandboxed writable paths
12. Resets failed unit state without restarting active templated instance chains
13. Runs `systemctl daemon-reload`
14. Disables the obsolete singleton units, enables/restarts the host kill switch, and leaves templated instance startup/reconciliation to the operator

After installation, run the protected fleet preflight and explicitly restart/reconcile the affected instance chains. A shared qBittorrent change is not complete until all five instances pass the runtime verifier.

Configure credentials in each protected instance file as described in the [README authentication requirements](../../README.md#authentication-requirements). Do not use installer command-line password arguments for normal fleet setup.

After the base install, include all five `proton-docker-watch@INSTANCE.service`
units in the approved sequential fleet activation. File installation alone does
not enable those watchers or upgrade running producer loops.
