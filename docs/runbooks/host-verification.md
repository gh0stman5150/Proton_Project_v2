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
sudo nft list chain ip proton_nat prerouting -a | grep qbt-dnat
```
