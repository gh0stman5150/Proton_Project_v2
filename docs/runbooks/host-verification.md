# Runbook: host routing and leak verification

Read-only checks unless a section says otherwise. For qBittorrent port parity
use the [port synchronization runbook](qbittorrent-port-sync.md); for fleet
acceptance use `proton-qbt-fleet-verify.sh --runtime`.

If you customized the defaults, source the relevant files under `/etc/proton` first or substitute the resolved values directly in the commands below.

## WireGuard and routing

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

## Firewall and kill switch

If the active backend is `nftables`:

```bash
sudo nft list table inet proton
sudo nft list table ip proton_nat
```

If the active backend is `iptables`, inspect the dedicated Proton chains and any policy routing related rules explicitly.

## qBittorrent state and mapping

`compose-recreate` is the only supported port apply mode; the sync script
rejects `legacy-dnat`.

```bash
cat /run/proton/prowlarr/proton-port.state
cat /run/proton/prowlarr/qbt-port.cache
cat /etc/proton/instances/prowlarr/qbittorrent-port.env
```

## DNS behavior

Verify each item in the [DNS policy](../architecture/host-routing-and-tunnels.md#dns-policy)
checklist, including the DNS path during VPN up, VPN down, and reconnect events.

## Leak prevention

Confirm all of the following:

1. Docker hosted application traffic uses the VPN path
2. Docker hosted application traffic is blocked from direct WAN egress during VPN downtime
3. SSH and RDP remain reachable through WAN and LAN
4. qBittorrent remains bound only to the intended VPN path

## Starting and stopping instance services

`proton-fleet-services.sh` (installed from `tools/proton-fleet-services.sh`)
starts, stops, or restarts the per-instance chain. Pass one or more instance
names, or none to act on all five. Starting or stopping an instance changes its
live tunnel and port lease, so it needs explicit runtime authorization.

```bash
sudo /usr/local/bin/proton/proton-fleet-services.sh status
sudo /usr/local/bin/proton/proton-fleet-services.sh --dry-run start
sudo /usr/local/bin/proton/proton-fleet-services.sh start sonarr radarr
sudo /usr/local/bin/proton/proton-fleet-services.sh stop whisparr
sudo /usr/local/bin/proton/proton-fleet-services.sh restart
```

`start` first makes sure `proton-killswitch.service` is active. It then starts
`proton-wg@`, `proton-docker-watch@`, `proton-port-forward@`, and
`proton-healthcheck@` for each instance. Every unit must be active before the
next instance starts. `stop` runs in reverse order and never stops the kill
switch, so containers stay blocked from the WAN while their tunnel is down.
Instances are handled one at a time, and the first failure ends the run without
touching the instances after it.

## Disruptive failure test (explicit runtime authorization required)

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

Watcher behavior is described in
[host routing and tunnels](../architecture/host-routing-and-tunnels.md#docker-network-watcher).

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
```
